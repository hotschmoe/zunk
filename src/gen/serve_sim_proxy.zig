const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");

const never_ms = types.never_ms;

pub const Behavior = enum(u8) { accept, refuse, stall };
pub const End = enum(u8) { eof, reset, hang };
pub const State = enum(u8) { none, connecting, refused, live, closed };

pub fn stream_byte(key: u64, index: u32) u8 {
    return @truncate(types.splitmix(key ^ (index >> 3)) >> @intCast(8 * (index & 7)));
}

pub const Upstream = struct {
    state: State = .none,
    behavior: Behavior = .accept,
    end: End = .eof,
    handle: u32 = 0,
    due_ms: u64 = never_ms,
    next_ms: u64 = never_ms,
    fwd: [api.request_bytes_max]u8 = undefined,
    fwd_len: u16 = 0,
    key: u64 = 0,
    total: u32 = 0,
    produced: u32 = 0,
    delivered: u32 = 0,
    started: bool = false,
    connected_called: bool = false,
    eof_seen: bool = false,
    refused_seen: bool = false,

    pub fn begin(
        up: *Upstream,
        rng: *types.Rng,
        now_ms: u64,
        behavior: Behavior,
        handle: u32,
    ) void {
        assert(up.state == .none);
        up.behavior = behavior;
        up.handle = handle;
        up.state = .connecting;
        up.key = rng.word();
        up.total = if (rng.chance(1, 5)) 0 else rng.between(1, 12000);
        up.end = switch (rng.below(10)) {
            0 => .reset,
            1 => .hang,
            else => .eof,
        };
        up.due_ms = if (behavior == .stall) never_ms else now_ms + rng.below(60);
        assert(up.state == .connecting);
    }

    pub fn goal(up: *const Upstream) u32 {
        return if (up.end == .hang) up.total / 2 else up.total;
    }

    pub fn poll(up: *Upstream, now_ms: u64) void {
        assert(up.state != .none);
        if (up.state == .connecting and up.due_ms != never_ms and now_ms >= up.due_ms) {
            up.state = if (up.behavior == .refuse) .refused else .live;
            up.due_ms = never_ms;
        }
        assert(up.state != .connecting or up.due_ms == never_ms or now_ms < up.due_ms);
    }

    pub fn accept_write(
        up: *Upstream,
        rng: *types.Rng,
        now_ms: u64,
        bytes: []const u8,
        request: []const u8,
    ) ?u32 {
        assert(up.state == .live and bytes.len > 0);
        const cap: u32 = if (rng.chance(1, 3)) rng.between(1, 64) else @intCast(bytes.len);
        const count: u32 = @min(cap, @as(u32, @intCast(bytes.len)));
        const end = up.fwd_len + count;
        if (end > request.len) return null;
        if (!std.mem.eql(u8, bytes[0..count], request[up.fwd_len..end])) return null;
        @memcpy(up.fwd[up.fwd_len..end], bytes[0..count]);
        up.fwd_len = @intCast(end);
        if (!up.started and std.mem.find(u8, up.fwd[0..up.fwd_len], "\r\n\r\n") != null) {
            up.started = true;
            up.next_ms = now_ms + rng.below(200);
        }
        assert(up.fwd_len <= request.len);
        return count;
    }

    pub fn produce(up: *Upstream, rng: *types.Rng, now_ms: u64) void {
        assert(up.state == .live);
        if (!up.started or up.next_ms == never_ms or now_ms < up.next_ms) return;
        const goal_bytes = up.goal();
        if (up.produced < goal_bytes) {
            const piece = rng.between(1, 3000);
            up.produced = @min(goal_bytes, up.produced + piece);
        }
        up.next_ms = if (up.produced < goal_bytes) now_ms + rng.below(80) else never_ms;
        assert(up.produced <= goal_bytes);
    }

    pub fn available(up: *const Upstream) u32 {
        assert(up.produced >= up.delivered);
        assert(up.produced <= up.total);
        return up.produced - up.delivered;
    }

    pub fn finished(up: *const Upstream) bool {
        return up.started and up.end != .hang and up.produced == up.total and
            up.delivered == up.produced and up.next_ms == never_ms;
    }

    pub fn read(up: *Upstream, buffer: []u8, cap: u32) u32 {
        assert(buffer.len > 0 and cap > 0);
        const count: u32 = @min(up.available(), @as(u32, @intCast(buffer.len)), cap);
        for (buffer[0..count], 0..) |*byte, offset| {
            byte.* = stream_byte(up.key, up.delivered + @as(u32, @intCast(offset)));
        }
        up.delivered += count;
        assert(up.delivered <= up.produced);
        return count;
    }

    pub fn next_time(up: *const Upstream) u64 {
        return switch (up.state) {
            .connecting => up.due_ms,
            .live => if (up.started) up.next_ms else never_ms,
            else => never_ms,
        };
    }
};
