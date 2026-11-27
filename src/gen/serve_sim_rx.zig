const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const files = @import("serve_sim_files.zig");

pub const head_max: u32 = 1024;
pub const text_max: u32 = 160;
pub const id_none: u8 = 255;

pub const Fault = enum(u8) {
    none,
    status_line,
    header_line,
    header_missing,
    header_value,
    length,
    overrun,
    wrong_file,
    unclean,
    body,
    accept_key,
};

pub const Stage = enum(u8) { head, body, done, upgraded };

pub const Check = struct {
    tree: *const files.Tree,
    script: []const u8,
    id_a: u8 = id_none,
    id_b: u8 = id_none,
    exact: ?[]const u8 = null,
    file: bool = false,
    upgrade: bool = false,
    key: [24]u8 = undefined,
};

const Seen = packed struct {
    type: bool = false,
    length: bool = false,
    cache: bool = false,
    opener: bool = false,
    embedder: bool = false,
    connection: bool = false,
    upgrade: bool = false,
    accept: bool = false,
};

pub fn reason_for(status: u16) ?[]const u8 {
    return switch (status) {
        101 => "Switching Protocols",
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Content Too Large",
        414 => "URI Too Long",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => null,
    };
}

pub fn expected_accept(key: []const u8) [28]u8 {
    assert(key.len == 24);
    var digest: [20]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    hasher.final(&digest);
    var encoded: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    assert(encoded[27] == '=');
    return encoded;
}

pub const Rx = struct {
    stage: Stage = .head,
    fault: Fault = .none,
    head: [head_max]u8 = undefined,
    head_len: u16 = 0,
    status: u16 = 0,
    length: u32 = 0,
    body_len: u32 = 0,
    mime: [48]u8 = undefined,
    mime_len: u8 = 0,
    text: [text_max]u8 = undefined,
    prefix: [files.header_bytes]u8 = undefined,
    stamp: ?files.Stamp = null,
    class: files.Class = .binary,

    pub fn text_slice(rx: *const Rx) []const u8 {
        return rx.text[0..@min(rx.body_len, text_max)];
    }

    pub fn mime_slice(rx: *const Rx) []const u8 {
        return rx.mime[0..rx.mime_len];
    }

    fn set_fault(rx: *Rx, fault: Fault) void {
        assert(fault != .none);
        if (rx.fault == .none) rx.fault = fault;
        assert(rx.fault != .none);
    }

    pub fn feed(rx: *Rx, bytes: []const u8, check: *const Check) u32 {
        assert(bytes.len <= 65536);
        for (bytes, 0..) |byte, index| {
            switch (rx.stage) {
                .head => {
                    if (rx.head_len == head_max) {
                        rx.set_fault(.header_line);
                        return @intCast(bytes.len);
                    }
                    rx.head[rx.head_len] = byte;
                    rx.head_len += 1;
                    const tail = rx.head[rx.head_len -| 4..rx.head_len];
                    if (rx.head_len >= 4 and std.mem.eql(u8, tail, "\r\n\r\n")) {
                        rx.parse_head(check);
                    }
                    if (rx.stage == .upgraded) return @intCast(index + 1);
                },
                .body => rx.body_byte(byte, check),
                .done => rx.set_fault(.overrun),
                .upgraded => unreachable,
            }
        }
        assert(rx.stage != .upgraded);
        return @intCast(bytes.len);
    }

    fn parse_head(rx: *Rx, check: *const Check) void {
        assert(rx.stage == .head and rx.head_len >= 4);
        const head = rx.head[0 .. rx.head_len - 4];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const first = lines.next() orelse "";
        if (first.len < 14 or !std.mem.startsWith(u8, first, "HTTP/1.1 ") or first[12] != ' ') {
            return rx.set_fault(.status_line);
        }
        rx.status = std.fmt.parseInt(u16, first[9..12], 10) catch return rx.set_fault(.status_line);
        const reason = reason_for(rx.status) orelse return rx.set_fault(.status_line);
        if (!std.mem.eql(u8, first[13..], reason)) return rx.set_fault(.status_line);
        var seen: Seen = .{};
        for (0..64) |_| {
            const line = lines.next() orelse break;
            rx.header_line(line, check, &seen);
        }
        rx.finish_head(check, seen);
        assert(rx.stage != .head or rx.fault != .none);
    }

    fn header_line(rx: *Rx, line: []const u8, check: *const Check, seen: *Seen) void {
        assert(line.len > 0 and rx.stage == .head);
        const colon = std.mem.findScalar(u8, line, ':') orelse return rx.set_fault(.header_line);
        if (line.len < colon + 2 or line[colon + 1] != ' ') return rx.set_fault(.header_line);
        const name = line[0..colon];
        const value = line[colon + 2 ..];
        if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (value.len == 0 or value.len > rx.mime.len) return rx.set_fault(.header_value);
            @memcpy(rx.mime[0..value.len], value);
            rx.mime_len = @intCast(value.len);
            seen.type = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            rx.length = std.fmt.parseInt(u32, value, 10) catch return rx.set_fault(.header_value);
            seen.length = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Cache-Control")) {
            if (!std.mem.eql(u8, value, "no-store")) rx.set_fault(.header_value);
            seen.cache = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Cross-Origin-Opener-Policy")) {
            if (!std.mem.eql(u8, value, "same-origin")) rx.set_fault(.header_value);
            seen.opener = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Cross-Origin-Embedder-Policy")) {
            if (!std.mem.eql(u8, value, "require-corp")) rx.set_fault(.header_value);
            seen.embedder = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            const expected = if (rx.status == 101) "upgrade" else "close";
            if (!std.ascii.eqlIgnoreCase(value, expected)) rx.set_fault(.header_value);
            seen.connection = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
            if (!std.ascii.eqlIgnoreCase(value, "websocket")) rx.set_fault(.header_value);
            seen.upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
            const expected = expected_accept(&check.key);
            if (!std.mem.eql(u8, value, &expected)) rx.set_fault(.accept_key);
            seen.accept = true;
        } else rx.set_fault(.header_line);
        assert(rx.fault != .none or @as(u8, @bitCast(seen.*)) != 0);
    }

    fn finish_head(rx: *Rx, check: *const Check, seen: Seen) void {
        assert(rx.stage == .head);
        if (rx.fault != .none) return;
        if (rx.status == 101) {
            if (!check.upgrade or !seen.upgrade or !seen.accept or !seen.connection) {
                return rx.set_fault(.header_missing);
            }
            rx.stage = .upgraded;
            return;
        }
        const complete = seen.type and seen.length and seen.cache and seen.opener and
            seen.embedder and seen.connection and !seen.upgrade and !seen.accept;
        if (!complete) return rx.set_fault(.header_missing);
        if (rx.status == 200 and check.file and rx.length == 0) {
            if (check.id_a != files.empty_id) rx.set_fault(.body);
        } else if (rx.status == 200 and check.file and rx.length < files.header_bytes) {
            rx.set_fault(.length);
        }
        rx.stage = if (rx.length == 0) .done else .body;
        assert(rx.stage == .done or rx.stage == .body);
    }

    fn body_byte(rx: *Rx, byte: u8, check: *const Check) void {
        const position = rx.body_len;
        assert(position < rx.length);
        if (position < text_max) rx.text[position] = byte;
        if (position < files.header_bytes) rx.prefix[position] = byte;
        if (check.exact) |exact| {
            const bad = position >= exact.len or exact[position] != byte;
            if (rx.status == 200 and bad) rx.set_fault(.body);
        }
        if (rx.status == 200 and check.file and rx.fault == .none) {
            if (position == files.header_bytes - 1) {
                rx.decode_stamp(check);
            } else if (position >= files.header_bytes) {
                const stamp = rx.stamp orelse return;
                const want = files.expected_byte(stamp, rx.class, check.script, position);
                if (want != byte) rx.set_fault(.body);
            }
        }
        rx.body_len += 1;
        if (rx.body_len == rx.length) rx.stage = .done;
        assert(rx.body_len <= rx.length);
    }

    fn decode_stamp(rx: *Rx, check: *const Check) void {
        assert(rx.body_len == files.header_bytes - 1);
        const id = std.mem.readInt(u32, rx.prefix[0..4], .little);
        if (id >= files.files_max or (id != check.id_a and id != check.id_b)) {
            return rx.set_fault(.wrong_file);
        }
        const stamp: files.Stamp = .{
            .id = @intCast(id),
            .inode = std.mem.readInt(u32, rx.prefix[4..8], .little),
            .version = std.mem.readInt(u32, rx.prefix[8..12], .little),
            .size = std.mem.readInt(u32, rx.prefix[12..16], .little),
        };
        rx.class = check.tree.entries[stamp.id].class;
        const extra: u32 = if (files.injects(rx.class)) @intCast(check.script.len) else 0;
        if (rx.class == .huge or rx.class == .empty or stamp.size + extra != rx.length) {
            return rx.set_fault(.length);
        }
        if (!check.tree.recent_clean(stamp)) return rx.set_fault(.unclean);
        rx.stamp = stamp;
        assert(rx.stamp != null and rx.fault == .none);
    }
};
