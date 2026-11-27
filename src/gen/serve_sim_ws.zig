const std = @import("std");
const assert = @import("../assert.zig").assert;

pub const first_max: u32 = 128;

pub const FrameKind = enum(u8) {
    text,
    binary,
    ping,
    pong,
    close,
    unmasked,
    fragment,
    extended,
};

pub fn header_terminal(kind: FrameKind) bool {
    return kind == .unmasked or kind == .fragment or kind == .extended;
}

pub fn opcode_for(kind: FrameKind) u8 {
    return switch (kind) {
        .text, .unmasked, .fragment, .extended => 1,
        .binary => 2,
        .ping => 9,
        .pong => 10,
        .close => 8,
    };
}

pub fn encode(out: []u8, kind: FrameKind, payload: []const u8, mask: [4]u8) u16 {
    assert(payload.len <= 130);
    assert(kind != .extended or payload.len >= 126);
    assert(kind == .extended or payload.len <= 125);
    const fin: u8 = if (kind == .fragment) 0 else 0x80;
    out[0] = fin | opcode_for(kind);
    var position: u16 = 2;
    const mask_bit: u8 = if (kind == .unmasked) 0 else 0x80;
    if (kind == .extended) {
        out[1] = mask_bit | 126;
        out[2] = @intCast(payload.len >> 8);
        out[3] = @intCast(payload.len & 255);
        position = 4;
    } else out[1] = mask_bit | @as(u8, @intCast(payload.len));
    if (kind != .unmasked) {
        @memcpy(out[position..][0..4], &mask);
        position += 4;
    }
    for (payload, 0..) |byte, index| {
        out[position + index] = if (kind == .unmasked) byte else byte ^ mask[index % 4];
    }
    position += @intCast(payload.len);
    assert(position >= 2 + payload.len);
    return position;
}

pub const Frame = struct {
    opcode: u8 = 0,
    length: u32 = 0,
    first: [first_max]u8 = undefined,
};

pub const Step = struct { used: u32, done: bool, fault: bool };

pub const Rx = struct {
    head: [4]u8 = undefined,
    head_len: u8 = 0,
    head_need: u8 = 2,
    left: u32 = 0,
    in_payload: bool = false,
    frame: Frame = .{},

    pub fn step(rx: *Rx, bytes: []const u8) Step {
        assert(bytes.len > 0);
        var used: u32 = 0;
        while (used < bytes.len) {
            const byte = bytes[used];
            used += 1;
            if (!rx.in_payload) {
                rx.head[rx.head_len] = byte;
                rx.head_len += 1;
                if (rx.head_len == 2 and !rx.header_start()) {
                    return .{ .used = used, .done = false, .fault = true };
                }
                if (rx.head_len < rx.head_need) continue;
                rx.begin_payload();
                if (rx.left > 0) continue;
                return rx.finish(used);
            }
            const position = rx.frame.length - rx.left;
            if (position < first_max) rx.frame.first[position] = byte;
            rx.left -= 1;
            if (rx.left == 0) return rx.finish(used);
        }
        assert(used == bytes.len);
        return .{ .used = used, .done = false, .fault = false };
    }

    fn header_start(rx: *Rx) bool {
        assert(rx.head_len == 2);
        assert(rx.head_need == 2 and !rx.in_payload);
        const first = rx.head[0];
        const second = rx.head[1];
        if (first != 0x81 and first != 0x8A) return false;
        if (second & 0x80 != 0 or second & 127 == 127) return false;
        rx.head_need = if (second & 127 == 126) 4 else 2;
        return true;
    }

    fn begin_payload(rx: *Rx) void {
        assert(rx.head_len == rx.head_need);
        rx.frame.opcode = rx.head[0] & 15;
        const short: u32 = rx.head[1] & 127;
        rx.frame.length = if (short == 126)
            (@as(u32, rx.head[2]) << 8) | rx.head[3]
        else
            short;
        rx.left = rx.frame.length;
        rx.in_payload = true;
        assert(rx.left == rx.frame.length and rx.left <= 65535);
    }

    fn finish(rx: *Rx, used: u32) Step {
        assert(rx.in_payload and rx.left == 0);
        assert(rx.frame.opcode == 1 or rx.frame.opcode == 10);
        rx.head_len = 0;
        rx.head_need = 2;
        rx.in_payload = false;
        return .{ .used = used, .done = true, .fault = false };
    }
};
