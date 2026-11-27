const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");
const files = @import("serve_sim_files.zig");
const rx_mod = @import("serve_sim_rx.zig");
const ws = @import("serve_sim_ws.zig");
const proxy = @import("serve_sim_proxy.zig");
const state = @import("serve_sim_state.zig");

const never_ms = types.never_ms;
const Shared = state.Shared;

pub const frames_max: u32 = 12;
pub const pings_max: u32 = 8;

pub const Phase = enum(u8) { free, backlog, open };
pub const ReadMode = enum(u8) { prompt, slow, stalled };
pub const Disconnect = enum(u8) { never, half_close, fin_at, rst_at, fin_after_rx };
pub const Gone = enum(u8) { no, fin, rst };
pub const Status = enum(u8) { none, clear, failure };

pub const Frame = struct {
    start: u16 = 0,
    len: u16 = 0,
    kind: ws.FrameKind = .text,
    marked: bool = false,
};

pub fn ping_byte(number: u32, index: u32, offset: u32) u8 {
    return @truncate(types.splitmix((@as(u64, number) << 24) | (@as(u64, index) << 12) | offset));
}

fn pick_frame(rng: *types.Rng, pings_left: bool) ws.FrameKind {
    const roll = rng.below(100);
    const kind: ws.FrameKind = if (roll < 35)
        .ping
    else if (roll < 55)
        .text
    else if (roll < 65)
        .binary
    else if (roll < 72)
        .pong
    else if (roll < 80)
        .close
    else if (roll < 86)
        .unmasked
    else if (roll < 93)
        .fragment
    else
        .extended;
    const result: ws.FrameKind = if (kind == .ping and !pings_left) .text else kind;
    assert(roll < 100);
    assert(pings_left or result != .ping);
    return result;
}

pub const Client = struct {
    phase: Phase = .free,
    kind: types.Kind = .static_file,
    number: u32 = 0,
    handle: u32 = 0,
    sock_open: bool = false,
    up_open: bool = false,
    spawn_ms: u64 = 0,
    accept_ms: u64 = 0,
    accept_seq: u64 = 0,
    reset_ms: u64 = 0,
    open_before: u32 = 0,
    refused: bool = false,
    pubs_at_accept: u32 = 0,
    pubs_at_join: u32 = 0,
    joined: bool = false,
    req: [types.request_buffer_max]u8 = undefined,
    req_len: u16 = 0,
    req_vis: u16 = 0,
    req_read: u16 = 0,
    hs_len: u16 = 0,
    piece_max: u16 = 0,
    gap_max_ms: u32 = 0,
    send_at: u64 = never_ms,
    req_done_ms: u64 = never_ms,
    read_mode: ReadMode = .prompt,
    window_cap: u32 = 0,
    window_used: u32 = 0,
    drain_at: u64 = never_ms,
    drain_max: u32 = 0,
    drain_gap_ms: u32 = 0,
    stall_after: u32 = 0,
    received: u32 = 0,
    raw_count: u32 = 0,
    disconnect: Disconnect = .never,
    disc_delay_ms: u32 = 0,
    disc_at: u64 = never_ms,
    disc_after: u32 = 0,
    gone: Gone = .no,
    half_closed: bool = false,
    check: rx_mod.Check = undefined,
    rx: rx_mod.Rx = .{},
    up: proxy.Upstream = .{},
    up_error: bool = false,
    w_prev: bool = false,
    w_seen: bool = false,
    close_due: bool = false,
    judged: bool = false,
    counted: bool = false,
    fault_reported: bool = false,
    frames: [frames_max]Frame = undefined,
    frame_count: u8 = 0,
    frame_next: u8 = 0,
    frame_at: u64 = never_ms,
    terminal_planned: bool = false,
    ping_count: u8 = 0,
    ping_len: [pings_max]u8 = undefined,
    pong_queue: [pings_max]u8 = undefined,
    pongs_expected: u8 = 0,
    pongs_seen: u8 = 0,
    wsx: ws.Rx = .{},
    reloads: u32 = 0,
    statuses: u32 = 0,
    last_status: Status = .none,

    pub fn is_ws(c: *const Client) bool {
        return c.kind == .ws_reload;
    }

    pub fn available(c: *const Client) u32 {
        assert(c.req_vis >= c.req_read);
        assert(c.req_vis <= c.req_len);
        return c.req_vis - c.req_read;
    }

    pub fn fin_visible(c: *const Client) bool {
        return c.gone == .fin or (c.half_closed and c.req_vis == c.req_len);
    }

    pub fn window_free(c: *const Client) u32 {
        assert(c.window_used <= c.window_cap);
        assert(c.window_cap > 0);
        return c.window_cap - c.window_used;
    }

    pub fn timed_now(c: *const Client) bool {
        return !c.is_ws() or !c.joined or c.w_prev;
    }

    fn can_drain(c: *const Client) bool {
        return c.gone == .no and c.window_used > 0 and
            (c.read_mode != .stalled or c.received < c.stall_after);
    }

    pub fn go_quiet(c: *Client) void {
        assert(c.phase != .free);
        c.frame_at = never_ms;
        if (c.kind == .stalled_request) return;
        c.gap_max_ms = 0;
        c.piece_max = 65535;
        if (c.read_mode == .slow) {
            c.drain_gap_ms = 0;
            c.drain_max = 1 << 20;
            c.window_cap = @max(c.window_cap, 8192);
        }
        assert(c.frame_at == never_ms);
    }

    pub fn next_ms(c: *const Client) u64 {
        if (c.phase == .free) return never_ms;
        assert(c.req_vis <= c.req_len);
        var next: u64 = never_ms;
        if (c.gone == .no and c.req_vis < c.req_len) next = c.send_at;
        if (c.can_drain()) next = @min(next, c.drain_at);
        if (c.gone == .no and c.frame_at != never_ms) next = @min(next, c.frame_at);
        const timed = c.disconnect == .fin_at or c.disconnect == .rst_at;
        if (c.gone == .no and timed and c.disc_at != never_ms) next = @min(next, c.disc_at);
        assert(c.disc_at == never_ms or timed or c.gone != .no);
        return next;
    }

    pub fn act(c: *Client, sh: *Shared) void {
        const now = sh.now_ms;
        assert(c.phase != .free);
        if (c.gone == .no) c.act_disconnect(sh);
        if (c.gone == .no and c.req_vis < c.req_len and c.send_at <= now) {
            const piece: u32 = @min(c.piece_max, c.req_len - c.req_vis);
            c.req_vis += @intCast(piece);
            c.send_at = now + (if (c.gap_max_ms > 0) sh.rng.below(c.gap_max_ms + 1) else 0);
            if (c.req_vis == c.req_len) c.req_done_ms = now;
            if (c.req_vis == c.req_len and c.disconnect == .half_close) c.half_closed = true;
        }
        if (c.can_drain() and c.drain_at <= now) {
            const count = @min(c.window_used, c.drain_max);
            c.window_used -= count;
            c.drain_at = if (c.window_used > 0) now + c.drain_gap_ms else never_ms;
        }
        if (c.gone == .no and c.frame_at != never_ms and c.frame_at <= now) c.plan_frame(sh);
        assert(c.window_used <= c.window_cap);
    }

    fn act_disconnect(c: *Client, sh: *Shared) void {
        assert(c.gone == .no);
        const now = sh.now_ms;
        const timed = c.disc_at != never_ms and c.disc_at <= now;
        const after = c.disconnect == .fin_after_rx and c.received >= c.disc_after;
        if (!timed and !after) return;
        const kind = c.disconnect;
        if (kind != .fin_at and kind != .rst_at and kind != .fin_after_rx) return;
        c.gone = if (c.disconnect == .rst_at) .rst else .fin;
        c.disc_at = never_ms;
        c.frame_at = never_ms;
        c.window_used = 0;
        sh.note(.spawn, c.number, @backingInt(c.gone), 2);
        assert(c.gone != .no);
    }

    pub fn plan_frame(c: *Client, sh: *Shared) void {
        assert(c.joined and c.frame_count < frames_max);
        const rng = &sh.rng;
        var kind = pick_frame(rng, c.ping_count < pings_max);
        if (c.read_mode == .stalled and c.frame_count == 0) kind = .ping;
        var payload: [130]u8 = undefined;
        var length: u32 = rng.between(0, 40);
        if (kind == .ping) length = rng.between(0, 125);
        if (kind == .extended) length = 130;
        if (kind == .close) length = 2;
        for (payload[0..length], 0..) |*byte, index| {
            byte.* = if (kind == .ping)
                ping_byte(c.number, c.ping_count, @intCast(index))
            else
                'a' + @as(u8, @intCast(rng.below(26)));
        }
        if (kind == .close) payload[0..2].* = .{ 0x03, 0xe8 };
        var mask: [4]u8 = undefined;
        std.mem.writeInt(u32, &mask, @truncate(rng.word()), .little);
        const written = ws.encode(c.req[c.req_len..], kind, payload[0..length], mask);
        c.frames[c.frame_count] = .{ .start = c.req_len, .len = written, .kind = kind };
        c.frame_count += 1;
        if (kind == .ping) {
            c.ping_len[c.ping_count] = @intCast(length);
            c.ping_count += 1;
        }
        if (c.req_vis == c.req_len) c.send_at = sh.now_ms;
        c.req_len += written;
        const terminal = kind == .close or ws.header_terminal(kind);
        c.terminal_planned = c.terminal_planned or terminal;
        const more = !terminal and c.frame_count < frames_max and c.req_len + 160 < c.req.len;
        c.frame_at = if (more) sh.now_ms + rng.between(1, 4000) else never_ms;
        assert(c.req_len <= c.req.len);
    }

    pub fn update_interest(c: *Client, sh: *Shared, interest: api.Interest) void {
        assert(c.phase == .open);
        if (interest.write and !c.w_prev) {
            const resets = if (c.is_ws())
                c.joined or c.refused
            else if (c.kind == .proxy and !c.refused)
                c.up_error or c.up.refused_seen
            else
                true;
            if (resets) c.reset_ms = sh.now_ms;
        }
        c.w_prev = interest.write;
        if (interest.write) c.w_seen = true;
        assert(c.reset_ms <= sh.now_ms);
        assert(c.w_prev == interest.write);
    }

    pub fn readiness(c: *Client, sh: *Shared, interest: api.Interest) ?api.Ready {
        assert(c.phase == .open and c.sock_open);
        assert(interest.handle == c.handle);
        var read = interest.read and (c.available() > 0 or c.fin_visible() or c.gone == .rst);
        var write = interest.write and (c.window_free() > 0 or c.gone != .no);
        if (interest.read and !read and sh.rng.chance(1, 24)) read = true;
        if (interest.write and !write and sh.rng.chance(1, 24)) write = true;
        const closed = c.gone != .no and sh.rng.chance(1, 6);
        if (!read and !write and !closed) return null;
        return .{ .token = interest.token, .read = read, .write = write, .closed = closed };
    }

    pub fn read_bytes(c: *Client, sh: *Shared, buffer: []u8) api.Transfer {
        assert(buffer.len > 0 and buffer.len <= 65536);
        if (c.gone == .rst) {
            c.close_due = true;
            sh.counters.error_hit(.read_failed);
            return .failed;
        }
        const queued = c.available();
        if (queued == 0) {
            if (!c.fin_visible()) return .pending;
            c.close_due = true;
            sh.counters.error_hit(.read_closed);
            return .closed;
        }
        const count: u32 = @min(queued, @as(u32, @intCast(buffer.len)), sh.cap());
        @memcpy(buffer[0..count], c.req[c.req_read..][0..count]);
        c.consume(sh, count);
        assert(count > 0);
        return .{ .count = count };
    }

    fn consume(c: *Client, sh: *Shared, count: u32) void {
        assert(count > 0 and count <= c.available());
        c.req_read += @intCast(count);
        assert(c.req_read <= c.req_vis);
        if (!c.is_ws() or !c.joined) return;
        for (0..frames_max) |_| {
            if (c.frame_next >= c.frame_count) break;
            const frame = &c.frames[c.frame_next];
            if (frame.start >= c.req_read) break;
            const header_done = c.req_read >= frame.start + 2;
            if (!frame.marked and ws.header_terminal(frame.kind) and header_done) {
                frame.marked = true;
                c.close_due = true;
                sh.counters.limit(.ws_frame);
            }
            if (c.req_read < frame.start + frame.len) break;
            c.frame_complete(sh, frame);
            c.frame_next += 1;
        }
    }

    fn frame_complete(c: *Client, sh: *Shared, frame: *const Frame) void {
        assert(c.frame_next < c.frame_count);
        if (frame.kind == .close) c.close_due = true;
        if (frame.kind != .ping) return;
        if (c.w_prev) {
            c.close_due = true;
            sh.counters.limit(.pong_queue);
            return;
        }
        const index = c.frame_next_ping();
        c.pong_queue[c.pongs_expected] = index;
        c.pongs_expected += 1;
        assert(c.pongs_expected <= pings_max);
    }

    fn frame_next_ping(c: *const Client) u8 {
        assert(c.frame_next < c.frame_count);
        var pings: u8 = 0;
        for (c.frames[0..c.frame_next]) |frame| {
            if (frame.kind == .ping) pings += 1;
        }
        assert(pings < c.ping_count);
        return pings;
    }

    pub fn write_bytes(c: *Client, sh: *Shared, bytes: []const u8) api.Transfer {
        assert(bytes.len > 0 and bytes.len <= 65536);
        if (c.gone != .no) {
            c.close_due = true;
            if (sh.rng.chance(1, 2)) {
                sh.counters.error_hit(.write_failed);
                return .failed;
            }
            sh.counters.error_hit(.write_closed);
            return .closed;
        }
        const free = c.window_free();
        if (free == 0) return .pending;
        const count: u32 = @min(@as(u32, @intCast(bytes.len)), free, sh.cap());
        c.window_used += count;
        c.received += count;
        c.reset_ms = sh.now_ms;
        if (c.drain_at == never_ms) c.drain_at = sh.now_ms + c.drain_gap_ms;
        c.on_server_bytes(sh, bytes[0..count]);
        assert(count > 0);
        return .{ .count = count };
    }

    fn raw_proxy(c: *const Client) bool {
        return c.kind == .proxy and c.up.connected_called and c.up.state == .live;
    }

    fn on_server_bytes(c: *Client, sh: *Shared, bytes: []const u8) void {
        assert(bytes.len > 0 and c.phase == .open);
        if (c.raw_proxy()) {
            for (bytes) |byte| {
                const delivered = c.up.delivered;
                if (c.raw_count >= delivered or byte != proxy.stream_byte(c.up.key, c.raw_count)) {
                    sh.verdict.fail(.proxy_wrong, "relay byte {d} differs (delivered {d})", .{
                        c.raw_count, delivered,
                    });
                }
                c.raw_count += 1;
            }
            return;
        }
        var rest = bytes;
        if (!c.joined) {
            const used = c.rx.feed(rest, &c.check);
            rest = rest[used..];
            if (c.rx.fault != .none) c.report_fault(sh);
            if (c.rx.stage == .upgraded) c.on_join(sh);
            if (c.rx.stage == .done and !c.judged and c.rx.fault == .none) {
                c.judge(sh);
                c.close_due = true;
            }
        }
        if (c.joined and rest.len > 0) c.ws_feed(sh, rest);
        assert(!c.fault_reported or c.rx.fault != .none);
    }

    fn report_fault(c: *Client, sh: *Shared) void {
        assert(c.rx.fault != .none);
        if (c.fault_reported) return;
        c.fault_reported = true;
        const fault = c.rx.fault;
        const wrong = fault == .wrong_file or fault == .unclean or fault == .body;
        const kind: types.Failed = if (wrong) .file_bytes_wrong else .response_malformed;
        const size: u32 = if (c.rx.stamp) |stamp| stamp.size else 0;
        sh.verdict.fail(kind, "{s} client {d}: {s} (status {d}, length {d}, got {d}, stamp {d})", .{
            @tagName(c.kind), c.number,      @tagName(fault), c.rx.status,
            c.rx.length,      c.rx.body_len, size,
        });
        assert(c.fault_reported and sh.verdict.failed != .none);
    }

    fn on_join(c: *Client, sh: *Shared) void {
        assert(c.rx.stage == .upgraded);
        if (c.joined) return;
        if (!c.is_ws()) {
            sh.verdict.fail(.websocket_wrong, "{s} client {d} got a 101", .{
                @tagName(c.kind), c.number,
            });
        }
        c.joined = true;
        c.pubs_at_join = sh.oracle.pubs;
        c.reset_ms = sh.now_ms;
        const first_gap = sh.rng.between(1, if (c.read_mode == .stalled) 100 else 2000);
        c.frame_at = if (c.frame_count == 0 and c.disconnect != .half_close)
            sh.now_ms + first_gap
        else
            never_ms;
        sh.counters.kind(.ws_reload);
        assert(c.joined);
    }

    fn ws_feed(c: *Client, sh: *Shared, bytes: []const u8) void {
        assert(bytes.len > 0 and c.joined);
        var rest = bytes;
        for (0..bytes.len) |_| {
            if (rest.len == 0) break;
            const step = c.wsx.step(rest);
            rest = rest[step.used..];
            if (step.fault) {
                sh.verdict.fail(.websocket_wrong, "client {d}: bad frame header", .{c.number});
                return;
            }
            if (step.done) c.on_frame(sh, &c.wsx.frame);
        }
        assert(rest.len == 0);
    }

    fn on_frame(c: *Client, sh: *Shared, frame: *const ws.Frame) void {
        assert(c.joined and frame.length <= 65535);
        const v = &sh.verdict;
        const first = frame.first[0..@min(frame.length, ws.first_max)];
        if (frame.opcode == 10) return c.on_pong(sh, frame);
        if (frame.opcode != 1) {
            return v.fail(.websocket_wrong, "client {d}: opcode {d}", .{ c.number, frame.opcode });
        }
        if (std.mem.eql(u8, first, "reload") or std.mem.eql(u8, first, "hmr:/app.wasm")) {
            if (first.len == 13 and !sh.config.hmr) v.fail(.websocket_wrong, "hmr frame", .{});
            c.reloads += 1;
            sh.counters.reloads += 1;
            if (c.reloads > sh.oracle.pubs - c.pubs_at_accept) {
                v.fail(.reload_extra, "client {d}: reload {d} of {d} publications", .{
                    c.number, c.reloads, sh.oracle.pubs - c.pubs_at_accept,
                });
            }
        } else if (std.mem.eql(u8, first, "clear")) {
            c.statuses += 1;
            c.last_status = .clear;
        } else if (std.mem.startsWith(u8, first, "error:") and frame.length >= 6) {
            c.statuses += 1;
            c.last_status = .failure;
        } else v.fail(.websocket_wrong, "client {d}: unknown text frame", .{c.number});
        assert(c.reloads <= sh.counters.reloads);
    }

    fn on_pong(c: *Client, sh: *Shared, frame: *const ws.Frame) void {
        assert(c.pongs_expected <= pings_max and frame.opcode == 10);
        if (c.pongs_seen >= c.pongs_expected) {
            return sh.verdict.fail(.pong_wrong, "client {d}: unexpected pong", .{c.number});
        }
        const index = c.pong_queue[c.pongs_seen];
        c.pongs_seen += 1;
        const want = c.ping_len[index];
        var same = frame.length == want;
        if (same) {
            for (frame.first[0..want], 0..) |byte, offset| {
                if (byte != ping_byte(c.number, index, @intCast(offset))) same = false;
            }
        }
        if (!same) {
            sh.verdict.fail(.pong_wrong, "client {d}: pong {d} differs", .{ c.number, index });
        }
        sh.counters.pongs += 1;
        assert(c.pongs_seen <= c.pongs_expected);
    }

    fn verified(c: *Client, sh: *Shared) void {
        assert(c.judged or c.kind == .stalled_request);
        if (c.counted) return;
        c.counted = true;
        sh.counters.kind(c.kind);
        assert(c.counted);
    }

    fn judge(c: *Client, sh: *Shared) void {
        assert(c.rx.stage == .done and !c.judged);
        assert(c.rx.fault == .none);
        c.judged = true;
        const status = c.rx.status;
        const body = c.rx.text_slice();
        if (c.refused) {
            const ok = status == 503 and std.mem.eql(u8, body, "Connection limit");
            if (!ok) sh.verdict.fail(.refusal_wrong, "refused client {d}: {d} '{s}'", .{
                c.number, status, body,
            });
            sh.counters.limit(.connection);
            return;
        }
        if (std.mem.eql(u8, body, "Connection limit")) {
            return sh.verdict.fail(.refusal_wrong, "client {d} refused with {d} open", .{
                c.number, c.open_before,
            });
        }
        if (c.kind_ok(sh, status, body)) return c.verified(sh);
        sh.verdict.fail(.response_wrong, "{s} client {d}: status {d} body '{s}'", .{
            @tagName(c.kind), c.number, status, body,
        });
    }

    fn kind_ok(c: *Client, sh: *Shared, status: u16, body: []const u8) bool {
        assert(c.rx.stage == .done and c.judged);
        assert(status >= 100 and status < 600);
        const is = std.mem.eql;
        const plain = std.mem.eql(u8, c.rx.mime_slice(), "text/plain");
        const missing = status == 404 and is(u8, body, "NotFound") and plain;
        return switch (c.kind) {
            .static_file, .index_root, .spa_fallback, .header_edge => c.file_ok(sh, status, body),
            .favicon => (status == 200 and is(u8, c.rx.mime_slice(), "image/x-icon")) or
                c.transient(sh, status, body),
            .missing_file => missing or c.transient(sh, status, body),
            .path_edge => c.limited(sh, missing, .path_edge_ok) or c.transient(sh, status, body),
            .big_file => c.limited(sh, status == 413 and is(u8, body, "FileLimit"), .file) or
                c.transient(sh, status, body),
            .traversal => status == 403 and is(u8, body, "403 Forbidden"),
            .bad_request => status == 400 and is(u8, body, "400 Bad Request"),
            .long_path => c.limited(sh, status == 414 and
                (is(u8, body, "414 URI Too Long") or is(u8, body, "URI limit")), .uri),
            .long_path_open => c.limited(sh, status == 414 and is(u8, body, "URI limit"), .uri),
            .header_flood => c.limited(sh, status == 431 and is(u8, body, "Header limit"), .header),
            .proxy => status == 502 and is(u8, body, "Bad Gateway") and
                (c.up_error or c.up.refused_seen),
            .ws_bad_handshake => status == 400 and is(u8, body, "Invalid WebSocket handshake"),
            .stalled_request, .ws_reload => false,
        };
    }

    fn limited(c: *Client, sh: *Shared, ok: bool, limit: types.Limit) bool {
        assert(c.rx.stage == .done);
        assert(c.judged);
        if (ok) sh.counters.limit(limit);
        return ok;
    }

    fn file_ok(c: *Client, sh: *Shared, status: u16, body: []const u8) bool {
        assert(c.check.file and c.check.id_a < files.files_max);
        assert(c.rx.stage == .done);
        if (status == 200) {
            const want = if (c.kind == .static_file)
                files.mime_for(sh.tree.entries[c.check.id_a].name)
            else
                "text/html";
            sh.counters.served += 1;
            if (c.kind == .header_edge) sh.counters.limit(.header_edge_ok);
            return std.mem.eql(u8, c.rx.mime_slice(), want);
        }
        if (status == 404 and std.mem.eql(u8, body, "NotFound")) {
            return c.kind == .static_file and sh.tree.missing_since(c.check.id_a, c.accept_ms);
        }
        return c.transient(sh, status, body);
    }

    fn transient(c: *Client, sh: *Shared, status: u16, body: []const u8) bool {
        assert(body.len <= rx_mod.text_max);
        if (status < 500) return false;
        const is = std.mem.eql;
        const o = &sh.oracle;
        if (status == 503 and is(u8, body, "Build in progress; retry")) {
            sh.counters.limit(.build_busy);
            return o.build_busy_since(c.accept_ms);
        }
        if (status == 503 and is(u8, body, "File snapshot limit; retry")) {
            sh.counters.limit(.snapshot);
            return o.full_since(c.accept_ms);
        }
        if (status == 503 and is(u8, body, "Changed")) return c.changed_possible(sh);
        if (status == 500 and is(u8, body, "System")) {
            return o.system_inject_ms != never_ms and o.system_inject_ms >= c.accept_ms;
        }
        assert(status >= 500);
        return false;
    }

    fn changed_possible(c: *const Client, sh: *const Shared) bool {
        assert(c.accept_ms <= sh.now_ms);
        assert(c.kind != .static_file or c.check.id_a < files.files_max);
        const o = &sh.oracle;
        if (o.changed_inject_ms != never_ms and o.changed_inject_ms >= c.accept_ms) return true;
        const index = sh.tree.mutated_since(files.index_id, c.accept_ms);
        if (c.check.id_a >= files.files_max) return index and c.kind == .spa_fallback;
        return sh.tree.mutated_since(c.check.id_a, c.accept_ms) or
            (index and c.kind != .static_file);
    }

    pub fn on_close(c: *Client, sh: *Shared) void {
        assert(c.phase == .open and c.sock_open);
        if (c.close_due) {
            if (c.kind == .proxy and c.up.eof_seen and c.raw_count != c.up.delivered) {
                sh.verdict.fail(.proxy_wrong, "relay delivered {d} of {d} bytes", .{
                    c.raw_count, c.up.delivered,
                });
            }
        } else c.unexplained_close(sh);
        c.sock_open = false;
        c.close_due = false;
        assert(sh.open_clients > 0);
        sh.open_clients -= 1;
        const unanswered = !c.w_seen and c.req_read == c.req_len;
        if (c.gone != .no and unanswered) sh.counters.timeout(.owner_gone);
        if (!c.up_open) c.phase = .free;
        assert(!c.sock_open and !c.close_due);
    }

    fn unexplained_close(c: *Client, sh: *Shared) void {
        assert(c.sock_open and !c.close_due);
        assert(c.reset_ms <= sh.now_ms);
        const now = sh.now_ms;
        const due = c.reset_ms + api.connection_timeout_ms;
        if (!c.timed_now()) {
            return sh.verdict.fail(.timeout_early, "idle {s} client {d} closed at {d}", .{
                @tagName(c.kind), c.number, now,
            });
        }
        if (now != due) {
            const kind: types.Failed = if (now < due) .timeout_early else .timeout_late;
            return sh.verdict.fail(kind, "{s} client {d} closed at {d}, deadline {d}", .{
                @tagName(c.kind), c.number, now, due,
            });
        }
        const counters = &sh.counters;
        if (c.is_ws() and c.joined) {
            counters.timeout(.ws_frame_30s);
        } else if (c.kind == .proxy) {
            counters.timeout(.proxy_30s);
        } else if (c.w_seen) {
            counters.timeout(.response_30s);
        } else counters.timeout(.request_30s);
        if (c.kind == .stalled_request) c.verified(sh);
        if (c.owes_response(sh)) {
            sh.verdict.fail(.response_incomplete, "{s} client {d} got no response in 30 s", .{
                @tagName(c.kind), c.number,
            });
        }
    }

    fn owes_response(c: *const Client, sh: *const Shared) bool {
        assert(c.phase == .open and c.accept_ms <= sh.now_ms);
        if (c.gone != .no or c.w_seen or c.req_done_ms == never_ms) return false;
        if (c.kind == .stalled_request) return false;
        const stalled = sh.oracle.stall_inject_ms;
        if (stalled != never_ms and stalled >= c.accept_ms) return false;
        if (sh.now_ms - @max(c.req_done_ms, c.accept_ms) < 8000) return false;
        if (c.kind == .proxy) return c.up_error or c.up.refused_seen;
        assert(c.req_done_ms <= sh.now_ms);
        return true;
    }

    pub fn check_deadline(c: *Client, sh: *Shared) void {
        assert(c.phase == .open);
        if (c.sock_open and c.close_due) {
            sh.verdict.fail(.left_open, "{s} client {d} stays open after its close cause", .{
                @tagName(c.kind), c.number,
            });
        }
        const due = c.reset_ms + api.connection_timeout_ms;
        if (c.sock_open and c.timed_now() and sh.now_ms >= due) {
            sh.verdict.fail(.timeout_late, "{s} client {d} open at {d}, deadline {d}", .{
                @tagName(c.kind), c.number, sh.now_ms, due,
            });
        }
        assert(c.reset_ms <= sh.now_ms);
    }

    pub fn final_check(c: *Client, sh: *Shared) void {
        assert(c.phase == .open);
        if (!c.is_ws() or !c.joined or c.gone != .no or !c.sock_open) return;
        const v = &sh.verdict;
        const pubs = sh.oracle.pubs;
        const possible = pubs - c.pubs_at_accept;
        const late: u32 = if (c.pubs_at_join > c.pubs_at_accept) 1 else 0;
        const exact = pubs - c.pubs_at_join + late;
        const prompt = c.read_mode == .prompt;
        if (c.reloads > possible) {
            v.fail(.reload_extra, "client {d}: {d} reloads, {d} publications", .{
                c.number, c.reloads, possible,
            });
        } else if (prompt and c.reloads != exact) {
            v.fail(.reload_missing, "client {d}: {d} reloads, expected {d} ({d}/{d}/{d})", .{
                c.number, c.reloads, exact, pubs, c.pubs_at_accept, c.pubs_at_join,
            });
        } else if (!prompt and possible > 0 and c.reloads == 0) {
            v.fail(.reload_missing, "client {d}: no reload, {d} publications", .{
                c.number, possible,
            });
        }
        assert(c.pongs_seen <= c.pongs_expected);
        if (prompt) c.final_status(sh);
        if (c.pongs_seen != c.pongs_expected and prompt) {
            v.fail(.pong_wrong, "client {d}: {d} of {d} pongs", .{
                c.number, c.pongs_seen, c.pongs_expected,
            });
        }
    }

    fn final_status(c: *Client, sh: *Shared) void {
        assert(c.is_ws() and c.joined);
        assert(c.last_status != .none or c.statuses == 0);
        const failed = sh.oracle.last_failed;
        const want: Status = if (sh.oracle.builds == 0) .none else if (failed) .failure else .clear;
        if (c.last_status != want) {
            sh.verdict.fail(.status_wrong, "client {d}: last status {s}, expected {s}", .{
                c.number, @tagName(c.last_status), @tagName(want),
            });
        }
    }
};
