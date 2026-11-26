const std = @import("std");
const resolver = @import("gen/js_resolve.zig");
const Reader = @import("gen/wasm_reader.zig").Reader;
const assert = @import("assert.zig").assert;

pub const input_max: u32 = 65536;
pub const imports_max: u32 = 128;
pub const header = "\x00asm\x01\x00\x00\x00";
const long_name: [2048]u8 = @splat('x');
const unusual_names = [_][]const u8{ "", "caf\xc3\xa9", "quote'\"\\\n", "__proto__" };
const prefix_names = [_][]const u8{
    "ctx2d_fill_rect",        "zunk_canvas_clear_rect", "audio_play", "input_poll",
    "zunk_gpu_create_buffer", "fx_poll",                "ime_poll",   "ui_button",
    "unknown_symbol",
};

pub const Buffer = struct {
    bytes: [input_max]u8 = undefined,
    length: u32 = 0,

    pub fn append(self: *Buffer, bytes: []const u8) !void {
        assert(self.length <= input_max);
        if (bytes.len > input_max - self.length) return error.InputLimit;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += @intCast(bytes.len);
        assert(self.length <= input_max);
    }

    pub fn byte(self: *Buffer, value: u8) !void {
        assert(self.length <= input_max);
        try self.append(&.{value});
        assert(self.length > 0);
    }

    pub fn integer(self: *Buffer, value: u32) !void {
        assert(self.length <= input_max);
        var remaining = value;
        for (0..5) |_| {
            const low: u8 = @truncate(remaining & 127);
            remaining >>= 7;
            try self.byte(low | @as(u8, if (remaining != 0) 128 else 0));
            if (remaining == 0) break;
        }
        assert(remaining == 0);
    }

    pub fn name(self: *Buffer, bytes: []const u8) !void {
        assert(bytes.len <= input_max);
        try self.integer(@intCast(bytes.len));
        try self.append(bytes);
        assert(self.length >= bytes.len + 1);
    }

    pub fn section(self: *Buffer, id: u8, body: []const u8) !void {
        assert(id <= 12);
        try self.byte(id);
        try self.integer(@intCast(body.len));
        try self.append(body);
        assert(self.length > body.len);
    }

    pub fn slice(self: *const Buffer) []const u8 {
        assert(self.length <= input_max);
        const result = self.bytes[0..self.length];
        assert(result.len == self.length);
        return result;
    }
};

pub const Declaration = struct { module: []const u8, name: []const u8, kind: u8 };
pub const Case = struct {
    buffer: Buffer = .{},
    declarations: [imports_max]Declaration = undefined,
    count: u32 = 0,
    malformed: bool = false,
    mutation: u8 = 0,
    profile: u8 = 0,
    import_offset: u32 = 0,
    name_offset: u32 = 0,
    kind_offset: u32 = 0,
    export_offset: u32 = 0,
    truncation: u8 = 0,
    parameters: u8 = 0,
};

pub fn generate(case: *Case, random: std.Random, number: u32) !void {
    case.* = .{};
    case.profile = @intCast(number % 16);
    case.mutation = @intCast((number / 16) % 16);
    case.truncation = case.profile % 13;
    assert(case.profile < 16);
    try case.buffer.append(header);
    try types(case, random);
    try imports(case, random);
    try remaining_sections(case, random);
    try mutate(case, random);
    assert(case.buffer.length <= input_max);
}

fn types(case: *Case, random: std.Random) !void {
    assert(case.buffer.length == 8);
    var body = Buffer{};
    try body.append(&.{ 2, 0x60 });
    case.parameters = random.uintLessThan(u8, 7);
    try body.byte(case.parameters);
    const values = [_]u8{ 0x7f, 0x7e, 0x7d, 0x7c };
    for (0..case.parameters) |_| try body.byte(values[random.uintLessThan(u8, values.len)]);
    const returns = random.uintLessThan(u8, 3);
    try body.byte(returns);
    for (0..returns) |_| try body.byte(values[random.uintLessThan(u8, values.len)]);
    try body.append(&.{ 0x60, 0, 0 });
    if (case.profile == 0) {
        try case.buffer.append(&.{ 1, @as(u8, @intCast(body.length)) | 128, 0 });
        try case.buffer.append(body.slice());
    } else try case.buffer.section(1, body.slice());
    assert(case.parameters <= 6);
}

fn select_name(profile: u8, random: std.Random) []const u8 {
    assert(profile < 16);
    const name = switch (profile) {
        1 => "console_log",
        2 => "definitely_unknown",
        3 => "random",
        4 => &long_name,
        5...8 => unusual_names[profile - 5],
        9 => resolver.exact_db[random.uintLessThan(u32, resolver.exact_db.len)].name,
        10 => prefix_names[random.uintLessThan(u32, prefix_names.len)],
        else => "performance_now",
    };
    assert(name.len <= long_name.len);
    return name;
}

fn imports(case: *Case, random: std.Random) !void {
    assert(case.profile < 16);
    case.count = switch (case.profile) {
        0 => 0,
        11 => 96 + random.uintLessThan(u32, 33),
        12 => 4,
        else => 2,
    };
    var body = Buffer{};
    try body.integer(case.count);
    for (0..case.count) |index| {
        const module: []const u8 = switch (case.profile) {
            13 => "wasi_snapshot_preview1",
            14 => "",
            15 => unusual_names[2],
            else => "env",
        };
        const name = if (case.profile == 11 and index % 2 == 0)
            long_name[0..384]
        else
            select_name(case.profile, random);
        const kind: u8 = if (case.profile == 12) @intCast(index) else 0;
        case.declarations[index] = .{ .module = module, .name = name, .kind = kind };
        try body.name(module);
        try body.integer(@intCast(name.len));
        if (index == 0) case.name_offset = body.length;
        try body.append(name);
        if (index == 0) case.kind_offset = body.length;
        try body.byte(kind);
        switch (kind) {
            0 => try body.byte(0),
            1 => try body.append(&.{ 0x70, 0, 1 }),
            2 => try body.append(&.{ 0, 1 }),
            3 => try body.append(&.{ 0x7f, 0 }),
            else => unreachable,
        }
    }
    const start = case.buffer.length;
    try case.buffer.section(2, body.slice());
    case.import_offset = case.buffer.length - body.length;
    case.name_offset += case.import_offset;
    case.kind_offset += case.import_offset;
    assert(case.import_offset > start);
}

fn remaining_sections(case: *Case, random: std.Random) !void {
    assert(case.buffer.length >= 8);
    const imported = case.profile == 12;
    const functions = if (imported) 1 else case.count;
    try case.buffer.section(3, &.{ 1, 1 });
    try case.buffer.section(4, if (imported) &.{0} else &.{ 1, 0x70, 0, 1 });
    try case.buffer.section(5, if (imported) &.{0} else &.{ 1, 0, 1 });
    try case.buffer.section(6, &.{ 1, 0x7f, 0, 0x41, 0, 0x0b });
    var exports = Buffer{};
    try exports.byte(1);
    try exports.name("init");
    try exports.byte(0);
    try exports.integer(functions);
    try case.buffer.section(7, exports.slice());
    case.export_offset = case.buffer.length - 2;
    var start = Buffer{};
    try start.integer(functions);
    try case.buffer.section(8, start.slice());
    var elements = Buffer{};
    try elements.append(&.{ 1, 0, 0x41, 0, 0x0b, 1 });
    try elements.integer(functions);
    try case.buffer.section(9, elements.slice());
    try case.buffer.section(10, &.{ 1, 5, 0, 0x41, 0, 0x1a, 0x0b });
    try case.buffer.section(11, &.{ 1, 0, 0x41, 0, 0x0b, 1, 'x' });
    var custom = Buffer{};
    const name: []const u8 = if (random.boolean()) "zunk_bindings" else "custom";
    try custom.name(name);
    try custom.append("{}");
    try case.buffer.section(0, custom.slice());
    try case.buffer.section(0, &.{ 4, 'n', 'a', 'm', 'e', 2, 1, 0 });
    assert(case.buffer.length <= input_max);
}

fn mutate(case: *Case, random: std.Random) !void {
    assert(case.mutation < 16);
    case.malformed = case.mutation != 0;
    const bytes = &case.buffer.bytes;
    switch (case.mutation) {
        0 => {},
        1 => case.buffer.length = random.uintLessThan(u32, 8),
        2 => bytes[9] = 127,
        3 => try case.buffer.append(&.{ 0, 0xff, 0xff, 0xff, 0xff, 0x1f }),
        4 => bytes[case.import_offset] = if (bytes[case.import_offset] == 127) 126 else 127,
        5 => bytes[8] = 13,
        6 => try case.buffer.section(2, &.{0}),
        7 => try case.buffer.section(1, &.{0}),
        8 => {
            if (case.count > 0) bytes[case.name_offset] = 0xff else bytes[10] = 127;
        },
        9 => bytes[11] = 0x7f,
        10 => bytes[4] = 2,
        11 => try case.buffer.section(0, &.{ 127, 0 }),
        12 => bytes[case.export_offset] = 4,
        13 => try case.buffer.append(&.{ 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0 }),
        14 => {
            if (case.count > 0) bytes[case.kind_offset] = 4 else bytes[8] = 255;
        },
        15 => try truncate(case, random),
        else => unreachable,
    }
    assert(case.buffer.length <= input_max);
}

fn truncate(case: *Case, random: std.Random) !void {
    assert(case.truncation < 13);
    var steps: u64 = input_max * 2;
    var input = Reader{ .bytes = case.buffer.slice(), .position = 8, .steps = &steps };
    for (0..13) |index| {
        const start = input.position;
        _ = try input.byte();
        const size = try input.integer();
        const payload = input.position;
        _ = try input.take(size);
        if (index == case.truncation) {
            const cuts = [_]u32{ start + 1, payload, payload + random.uintLessThan(u32, size) };
            case.buffer.length = cuts[random.uintLessThan(u8, cuts.len)];
            assert(case.buffer.length < input.position);
            return;
        }
    }
    unreachable;
}
