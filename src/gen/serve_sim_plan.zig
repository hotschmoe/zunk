const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const http = @import("serve_http.zig");
const types = @import("serve_sim_types.zig");
const files = @import("serve_sim_files.zig");
const rx_mod = @import("serve_sim_rx.zig");
const state = @import("serve_sim_state.zig");
const client = @import("serve_sim_client.zig");

const never_ms = types.never_ms;
const Client = client.Client;
const Shared = state.Shared;

const weights = [_]struct { kind: types.Kind, weight: u32 }{
    .{ .kind = .static_file, .weight = 18 },
    .{ .kind = .index_root, .weight = 6 },
    .{ .kind = .spa_fallback, .weight = 6 },
    .{ .kind = .favicon, .weight = 3 },
    .{ .kind = .missing_file, .weight = 5 },
    .{ .kind = .path_edge, .weight = 3 },
    .{ .kind = .big_file, .weight = 3 },
    .{ .kind = .traversal, .weight = 3 },
    .{ .kind = .bad_request, .weight = 4 },
    .{ .kind = .long_path, .weight = 3 },
    .{ .kind = .long_path_open, .weight = 2 },
    .{ .kind = .header_flood, .weight = 3 },
    .{ .kind = .header_edge, .weight = 3 },
    .{ .kind = .stalled_request, .weight = 7 },
    .{ .kind = .proxy, .weight = 8 },
    .{ .kind = .ws_reload, .weight = 12 },
    .{ .kind = .ws_bad_handshake, .weight = 3 },
};

pub fn choose_kind(sh: *Shared) types.Kind {
    var total: u32 = 0;
    for (weights) |entry| total += allowed_weight(sh, entry.kind, entry.weight);
    assert(total > 0 and total <= 200);
    var roll = sh.rng.below(total);
    for (weights) |entry| {
        const weight = allowed_weight(sh, entry.kind, entry.weight);
        if (roll < weight) return entry.kind;
        roll -= weight;
    }
    unreachable;
}

fn allowed_weight(sh: *const Shared, kind: types.Kind, weight: u32) u32 {
    assert(weight > 0);
    const needs_reload = kind == .ws_reload or kind == .ws_bad_handshake;
    if (needs_reload and !sh.config.autoreload) return 0;
    if (kind == .proxy and !sh.config.proxy) return 0;
    assert(weight <= 20);
    return weight;
}

fn put(c: *Client, comptime format: []const u8, args: anytype) void {
    assert(c.req_len < c.req.len);
    const text = std.fmt.bufPrint(c.req[c.req_len..], format, args) catch @panic("request bound");
    c.req_len += @intCast(text.len);
    assert(c.req_len <= c.req.len);
}

fn put_fill(c: *Client, byte: u8, count: u32) void {
    assert(c.req_len + count <= c.req.len);
    @memset(c.req[c.req_len..][0..count], byte);
    c.req_len += @intCast(count);
    assert(c.req_len <= c.req.len);
}

fn finish_get(c: *Client) void {
    put(c, " HTTP/1.1\r\nHost: sim\r\nAccept: */*\r\nX-Sim: {d}\r\n\r\n", .{c.number});
}

pub fn spawn(c: *Client, sh: *Shared, kind: types.Kind, forced: ?client.ReadMode) void {
    assert(c.phase == .free);
    c.* = .{};
    c.phase = .backlog;
    c.kind = kind;
    c.number = sh.serial;
    sh.serial += 1;
    c.spawn_ms = sh.now_ms;
    const script: []const u8 = if (sh.config.autoreload) sh.script() else &.{};
    c.check = .{ .tree = &sh.tree, .script = script };
    plan_request(c, sh);
    plan_behavior(c, sh, forced);
    c.send_at = sh.now_ms + sh.rng.below(3);
    assert(c.req_len > 0 or c.kind == .stalled_request);
    assert(c.phase == .backlog);
}

fn plan_request(c: *Client, sh: *Shared) void {
    switch (c.kind) {
        .static_file, .index_root, .spa_fallback, .favicon, .header_edge => plan_file(c, sh),
        .missing_file, .path_edge, .big_file, .traversal, .bad_request => plan_error(c, sh),
        .long_path, .long_path_open, .header_flood, .stalled_request => plan_limit(c, sh),
        .proxy => {
            put(c, "GET {s}/n{d}", .{ state.proxy_prefix, c.number });
            finish_get(c);
        },
        .ws_reload, .ws_bad_handshake => plan_websocket(c, sh),
    }
}

fn plan_file(c: *Client, sh: *Shared) void {
    assert(c.phase == .backlog and c.req_len == 0);
    c.check.file = true;
    c.check.id_a = files.index_id;
    switch (c.kind) {
        .static_file => {
            const pick = sh.rng.below(9);
            const id: u8 = if (pick == 8) files.gone_id else @intCast(pick);
            c.check.id_a = id;
            put(c, "GET /{s}", .{sh.tree.entries[id].name});
            if (sh.rng.chance(1, 3)) put(c, "?v={d}", .{c.number});
            finish_get(c);
        },
        .index_root => {
            put(c, "GET /", .{});
            if (sh.rng.chance(1, 3)) put(c, "?x={d}", .{c.number});
            finish_get(c);
        },
        .spa_fallback => {
            put(c, "GET /app/route-{d}", .{c.number});
            finish_get(c);
        },
        .favicon => {
            c.check.file = false;
            c.check.id_a = rx_mod.id_none;
            c.check.exact = http.favicon;
            put(c, "GET /favicon.ico", .{});
            finish_get(c);
        },
        .header_edge => {
            put(c, "GET /index.html HTTP/1.1\r\nHost: sim\r\nX-Pad: ", .{});
            const total = sh.rng.between(3900, api.request_bytes_max);
            put_fill(c, 'p', total - c.req_len - 4);
            put(c, "\r\n\r\n", .{});
            assert(c.req_len == total);
        },
        else => unreachable,
    }
    assert(c.req_len > 0);
}

fn plan_error(c: *Client, sh: *Shared) void {
    switch (c.kind) {
        .missing_file => {
            put(c, "GET /missing-{d}.dat", .{c.number});
            finish_get(c);
        },
        .path_edge => {
            const length = sh.rng.between(1000, api.path_bytes_max);
            put(c, "GET /", .{});
            put_fill(c, 'a', length - 5);
            put(c, ".bin", .{});
            assert(c.req_len == 4 + length);
            finish_get(c);
        },
        .big_file => {
            put(c, "GET /big.bin", .{});
            finish_get(c);
        },
        .traversal => {
            if (sh.rng.chance(1, 2)) {
                put(c, "GET /a/../index.html", .{});
            } else put(c, "GET /dir\\file.js", .{});
            finish_get(c);
        },
        .bad_request => plan_bad_request(c, sh),
        else => unreachable,
    }
}

fn plan_bad_request(c: *Client, sh: *Shared) void {
    assert(c.kind == .bad_request);
    switch (sh.rng.below(5)) {
        0 => put(c, "POST /index.html HTTP/1.1\r\nHost: sim\r\n\r\n", .{}),
        1 => put(c, "GET index.html HTTP/1.1\r\nHost: sim\r\n\r\n", .{}),
        2 => put(c, "GET /a\x00b.js HTTP/1.1\r\nHost: sim\r\n\r\n", .{}),
        3 => put(c, "GET  / HTTP/1.1\r\nHost: sim\r\n\r\n", .{}),
        else => put(c, "GET /index.html\r\n\r\n", .{}),
    }
    assert(c.req_len > 8);
}

fn plan_limit(c: *Client, sh: *Shared) void {
    switch (c.kind) {
        .long_path => {
            const length = sh.rng.between(api.path_bytes_max + 1, 1400);
            put(c, "GET /", .{});
            put_fill(c, 'a', length - 1);
            finish_get(c);
        },
        .long_path_open => {
            put(c, "GET /", .{});
            put_fill(c, 'a', sh.rng.between(1100, 1300));
        },
        .header_flood => {
            put(c, "GET /index.html HTTP/1.1\r\nHost: sim\r\n", .{});
            for (0..200) |index| {
                if (c.req_len + 80 >= 4300) break;
                put(c, "X-Fill-{d}: ", .{index});
                put_fill(c, 'b', 60);
                put(c, "\r\n", .{});
            }
            put_fill(c, 'c', 4300 - c.req_len);
        },
        .stalled_request => {
            put(c, "GET /index.html HTTP/1.1\r\nHost: sim\r\n\r\n", .{});
            c.req_len = @intCast(sh.rng.between(0, c.req_len - 5));
        },
        else => unreachable,
    }
}

fn plan_websocket(c: *Client, sh: *Shared) void {
    assert(c.kind == .ws_reload or c.kind == .ws_bad_handshake);
    var raw: [16]u8 = undefined;
    std.mem.writeInt(u64, raw[0..8], sh.rng.word(), .little);
    std.mem.writeInt(u64, raw[8..16], sh.rng.word(), .little);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &raw);
    c.check.upgrade = true;
    c.check.key = key;
    put(c, "GET /__zunk_ws HTTP/1.1\r\nHost: sim\r\n", .{});
    if (c.kind == .ws_reload) {
        put(c, "Upgrade: websocket\r\nConnection: Upgrade\r\n", .{});
        put(c, "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{key});
        c.hs_len = c.req_len;
        return;
    }
    const bad = sh.rng.below(5);
    put(c, "Upgrade: {s}\r\nConnection: Upgrade\r\n", .{if (bad == 3) "h2" else "websocket"});
    const odd_key: []const u8 = if (bad == 2) "short" else "!!!!!!!!!!!!!!!!!!!!!!!!";
    if (bad == 2 or bad == 4) put(c, "Sec-WebSocket-Key: {s}\r\n", .{odd_key});
    if (bad != 1 and bad != 2 and bad != 4) put(c, "Sec-WebSocket-Key: {s}\r\n", .{key});
    put(c, "Sec-WebSocket-Version: {s}\r\n\r\n", .{if (bad == 0) "12" else "13"});
    c.hs_len = c.req_len;
}

fn plan_behavior(c: *Client, sh: *Shared, forced: ?client.ReadMode) void {
    assert(c.req_len <= c.req.len);
    const rng = &sh.rng;
    c.piece_max = 65535;
    switch (rng.below(5)) {
        2 => {
            c.piece_max = @intCast(rng.between(1, 64));
            c.gap_max_ms = rng.between(0, 50);
        },
        3 => {
            c.piece_max = @intCast(rng.between(1, 8));
            c.gap_max_ms = rng.between(0, 3000);
        },
        else => {},
    }
    if (c.kind == .stalled_request) {
        c.piece_max = @intCast(rng.between(1, 4));
        c.gap_max_ms = if (rng.chance(1, 2)) 0 else rng.between(1000, 6000);
    }
    plan_reading(c, sh, forced);
    plan_disconnect(c, sh);
    assert(c.piece_max > 0 and c.window_cap > 0);
}

fn plan_reading(c: *Client, sh: *Shared, forced: ?client.ReadMode) void {
    assert(c.window_cap == 0);
    const rng = &sh.rng;
    const roll = rng.below(10);
    c.read_mode = if (roll < 7) .prompt else if (roll < 9) .slow else .stalled;
    if (c.is_ws() and roll < 3) c.read_mode = .stalled;
    if (forced) |mode| c.read_mode = mode;
    switch (c.read_mode) {
        .prompt => {
            c.window_cap = 8192;
            c.drain_max = 1 << 20;
        },
        .slow => {
            c.window_cap = rng.between(16, 600);
            c.drain_max = rng.between(1, 64);
            c.drain_gap_ms = rng.between(1, 200);
        },
        .stalled => {
            c.window_cap = rng.between(1, 300);
            c.drain_max = rng.between(1, 64);
            c.drain_gap_ms = rng.between(1, 100);
            c.stall_after = rng.between(0, 2000);
        },
    }
    if (c.is_ws() and c.read_mode == .stalled) {
        c.window_cap = rng.between(7, 20);
        c.stall_after = rng.between(129, 136);
    }
    assert(c.window_cap > 0 and c.drain_max > 0);
}

fn plan_disconnect(c: *Client, sh: *Shared) void {
    assert(c.disconnect == .never);
    const rng = &sh.rng;
    const roll = rng.below(100);
    c.disconnect = .never;
    if (c.kind == .stalled_request or (c.is_ws() and c.read_mode == .stalled)) return;
    if (c.is_ws()) {
        if (roll < 65) {
            c.disconnect = if (rng.chance(1, 3)) .rst_at else .fin_at;
            c.disc_delay_ms = rng.between(500, 200000);
        }
        return;
    }
    if (roll < 7) {
        c.disconnect = .half_close;
    } else if (roll < 17) {
        c.disconnect = if (rng.chance(1, 2)) .fin_at else .rst_at;
        c.disc_delay_ms = rng.between(0, 3000);
    } else if (roll < 22) {
        c.disconnect = .fin_after_rx;
        c.disc_after = rng.between(0, 4000);
    }
    assert(c.disconnect != .fin_at or c.disc_delay_ms <= 3000);
}
