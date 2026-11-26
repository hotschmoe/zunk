const std = @import("std");
const assert = @import("../assert.zig").assert;

pub const Error = error{
    UnexpectedEnd,
    InvalidLeb128,
    InvalidUtf8,
    InvalidSection,
    InvalidValueType,
    InvalidImportKind,
    InvalidLimits,
    StepLimit,
};

pub const Reader = struct {
    bytes: []const u8,
    position: u32 = 0,
    steps: *u64,

    pub fn charge(self: *Reader, count: u64) Error!void {
        assert(self.position <= self.bytes.len);
        if (count > self.steps.*) return error.StepLimit;
        self.steps.* -= count;
        assert(self.position <= self.bytes.len);
    }

    pub fn byte(self: *Reader) Error!u8 {
        assert(self.position <= self.bytes.len);
        try self.charge(1);
        if (self.position == self.bytes.len) return error.UnexpectedEnd;
        const value = self.bytes[self.position];
        self.position += 1;
        assert(self.position <= self.bytes.len);
        return value;
    }

    pub fn take(self: *Reader, count: u32) Error![]const u8 {
        assert(self.position <= self.bytes.len);
        if (count > self.bytes.len - self.position) return error.UnexpectedEnd;
        try self.charge(count);
        const result = self.bytes[self.position..][0..count];
        self.position += count;
        assert(result.len == count);
        return result;
    }

    pub fn integer(self: *Reader) Error!u32 {
        assert(self.position <= self.bytes.len);
        var result: u32 = 0;
        for (0..5) |index| {
            const value = try self.byte();
            if (index == 4 and value > 15) return error.InvalidLeb128;
            result |= @as(u32, value & 127) << @as(u5, @intCast(index * 7));
            if (value < 128) {
                assert(self.position <= self.bytes.len);
                return result;
            }
        }
        return error.InvalidLeb128;
    }

    pub fn name(self: *Reader) Error![]const u8 {
        assert(self.position <= self.bytes.len);
        const result = try self.take(try self.integer());
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
        assert(self.position <= self.bytes.len);
        return result;
    }

    pub fn value_type(self: *Reader) Error!u8 {
        assert(self.position <= self.bytes.len);
        const value = try self.byte();
        switch (value) {
            0x7f, 0x7e, 0x7d, 0x7c, 0x70, 0x6f => {},
            else => return error.InvalidValueType,
        }
        assert(value != 0);
        return value;
    }

    pub fn limits(self: *Reader) Error!void {
        assert(self.position <= self.bytes.len);
        const flags = try self.byte();
        if (flags > 1) return error.InvalidLimits;
        const minimum = try self.integer();
        if (flags == 1 and try self.integer() < minimum) return error.InvalidLimits;
        assert(self.position <= self.bytes.len);
    }

    pub fn finished(self: *Reader) Error!void {
        assert(self.position <= self.bytes.len);
        if (self.position != self.bytes.len) return error.InvalidSection;
        assert(self.position == self.bytes.len);
    }
};
