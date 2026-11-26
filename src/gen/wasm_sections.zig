const reader = @import("wasm_reader.zig");
const assert = @import("../assert.zig").assert;

pub const Sections = struct {
    functions: u32 = 0,
    code: u32 = 0,
    data: u32 = 0,
    data_count: ?u32 = null,

    pub fn parse(self: *Sections, input: *reader.Reader, id: u8, types: u32) !void {
        assert(input.position == 0);
        assert(id >= 3 and id <= 12 and id != 7);
        if (id == 8) {
            _ = try input.integer();
            return;
        }
        if (id == 12) {
            self.data_count = try input.integer();
            return;
        }
        const count = try vector_count(input);
        switch (id) {
            3 => self.functions = count,
            10 => self.code = count,
            11 => self.data = count,
            else => {},
        }
        for (0..count) |_| switch (id) {
            3 => if (try input.integer() >= types) return error.InvalidTypeIndex,
            4 => {
                try reference_type(input);
                try input.limits();
            },
            5 => try input.limits(),
            6 => {
                _ = try input.value_type();
                if (try input.byte() > 1) return error.InvalidMutability;
                try constant_expression(input);
            },
            9 => try element(input),
            10 => try code_body(input),
            11 => try data_segment(input),
            else => unreachable,
        };
    }

    pub fn finish(self: *const Sections) !void {
        if (self.functions != self.code) return error.FunctionCodeMismatch;
        if (self.data_count) |count| {
            if (count != self.data) return error.DataCountMismatch;
        }
        assert(self.functions == self.code);
        assert(self.data_count == null or self.data_count.? == self.data);
    }
};

fn vector_count(input: *reader.Reader) !u32 {
    assert(input.position <= input.bytes.len);
    const count = try input.integer();
    if (count > input.bytes.len - input.position) return error.UnexpectedEnd;
    assert(count <= input.bytes.len);
    return count;
}

fn reference_type(input: *reader.Reader) !void {
    assert(input.position <= input.bytes.len);
    const value = try input.byte();
    if (value != 0x70 and value != 0x6f) return error.InvalidValueType;
    assert(value == 0x70 or value == 0x6f);
}

fn signed_integer(input: *reader.Reader, bits: u8) !void {
    assert(bits == 32 or bits == 64);
    const count: u8 = (bits + 6) / 7;
    for (0..count) |index| {
        const byte = try input.byte();
        if (index + 1 == count) {
            const mask: u8 = if (bits == 32) 0x78 else 0x7e;
            const high = byte & mask;
            if (high != 0 and high != mask) return error.InvalidLeb128;
        }
        if (byte < 128) {
            assert(input.position <= input.bytes.len);
            return;
        }
    }
    return error.InvalidLeb128;
}

fn constant_expression(input: *reader.Reader) !void {
    assert(input.position <= input.bytes.len);
    const opcode = try input.byte();
    switch (opcode) {
        0x41 => try signed_integer(input, 32),
        0x42 => try signed_integer(input, 64),
        0x43 => _ = try input.take(4),
        0x44 => _ = try input.take(8),
        0x23, 0xd2 => _ = try input.integer(),
        0xd0 => try reference_type(input),
        else => return error.InvalidConstantExpression,
    }
    if (try input.byte() != 0x0b) return error.InvalidConstantExpression;
    assert(input.position <= input.bytes.len);
}

fn element(input: *reader.Reader) !void {
    assert(input.position <= input.bytes.len);
    const flags = try input.integer();
    if (flags > 7) return error.InvalidElement;
    if (flags == 2 or flags == 6) _ = try input.integer();
    if (flags & 1 == 0) try constant_expression(input);
    if (flags != 0 and flags != 4) {
        if (flags < 4) {
            if (try input.byte() != 0) return error.InvalidElement;
        } else try reference_type(input);
    }
    const count = try vector_count(input);
    for (0..count) |_| {
        if (flags < 4) _ = try input.integer() else try constant_expression(input);
    }
    assert(input.position <= input.bytes.len);
}

fn code_body(input: *reader.Reader) !void {
    assert(input.position <= input.bytes.len);
    const bytes = try input.take(try input.integer());
    var body = reader.Reader{ .bytes = bytes, .steps = input.steps };
    const count = try vector_count(&body);
    for (0..count) |_| {
        _ = try body.integer();
        _ = try body.value_type();
    }
    if (body.position == bytes.len or bytes[bytes.len - 1] != 0x0b) {
        return error.InvalidCodeBody;
    }
    assert(body.position < bytes.len);
}

fn data_segment(input: *reader.Reader) !void {
    assert(input.position <= input.bytes.len);
    const flags = try input.integer();
    if (flags > 2) return error.InvalidDataSegment;
    if (flags == 2) _ = try input.integer();
    if (flags != 1) try constant_expression(input);
    _ = try input.take(try input.integer());
    assert(input.position <= input.bytes.len);
}
