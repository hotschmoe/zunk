const std = @import("std");

extern "env" fn zunk_ime_set_active(active: u32) void;
extern "env" fn zunk_ime_set_spot(x: f32, y: f32, h: f32) void;
extern "env" fn zunk_ime_poll(ptr: [*]u8, cap: u32) u32;

pub const Kind = enum(u32) {
    start = 1,
    update = 2,
    commit = 3,
};

pub const Event = struct {
    kind: Kind,
    cursor: usize,
    text: []const u8,
};

pub fn setActive(active: bool) void {
    zunk_ime_set_active(@intFromBool(active));
}

pub fn setSpot(x: f32, y: f32, line_h: f32) void {
    zunk_ime_set_spot(x, y, line_h);
}

pub fn poll(out: []Event, scratch: []u8) usize {
    const written = zunk_ime_poll(scratch.ptr, @intCast(scratch.len));
    return decode(scratch[0..written], out);
}

// Record format: src/gen/js/ime.js.
pub fn decode(raw: []const u8, out: []Event) usize {
    var off: usize = 0;
    var n: usize = 0;
    while (off + 12 <= raw.len and n < out.len) {
        const kind = std.mem.readInt(u32, raw[off..][0..4], .little);
        const cursor = std.mem.readInt(u32, raw[off + 4 ..][0..4], .little);
        const len = std.mem.readInt(u32, raw[off + 8 ..][0..4], .little);
        const padded = (len + 3) & ~@as(u32, 3);
        if (off + 12 + padded > raw.len) break;
        const k = std.enums.fromInt(Kind, kind) orelse {
            off += 12 + padded;
            continue;
        };
        out[n] = .{ .kind = k, .cursor = cursor, .text = raw[off + 12 ..][0..len] };
        n += 1;
        off += 12 + padded;
    }
    return n;
}
