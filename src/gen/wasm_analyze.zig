const std = @import("std");
const reader = @import("wasm_reader.zig");
const assert = @import("../assert.zig").assert;

pub const WasmValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B,
    funcref = 0x70,
    externref = 0x6F,
};

pub const FuncType = struct {
    params: []const WasmValType,
    returns: []const WasmValType,
};

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    type_idx: u32,
    kind: u8 = 0,
    func_type: ?FuncType = null,
    param_names: []const []const u8 = &.{},
};

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

pub const ExportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };

pub const Analysis = struct {
    imports: []Import,
    exports: []Export,
    func_types: []FuncType,
    explicit_manifest: ?[]const u8,
    has_name_section: bool,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        assert(self.imports.len <= entries_max);
        assert(self.func_types.len <= entries_max);
        for (self.imports) |*imp| {
            allocator.free(imp.module);
            allocator.free(imp.name);
            for (imp.param_names) |pn| allocator.free(pn);
            if (imp.param_names.len > 0) allocator.free(imp.param_names);
        }
        allocator.free(self.imports);
        for (self.exports) |*exp| allocator.free(exp.name);
        allocator.free(self.exports);
        for (self.func_types) |*ft| {
            allocator.free(ft.params);
            allocator.free(ft.returns);
        }
        allocator.free(self.func_types);
        self.* = undefined;
    }

    pub fn get_import_signature(self: *const Analysis, imp: *const Import) ?FuncType {
        assert(imp.kind <= 3);
        assert(self.func_types.len <= entries_max);
        if (imp.kind != 0) return null;
        if (imp.func_type) |ft| return ft;
        if (imp.type_idx < self.func_types.len) return self.func_types[imp.type_idx];
        return null;
    }

    pub fn has_export(self: *const Analysis, name: []const u8) bool {
        assert(self.exports.len <= entries_max);
        assert(self.imports.len <= entries_max);
        for (self.exports) |exp| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, name)) return true;
        }
        return false;
    }
};

pub const input_max: u32 = 10 * 1024 * 1024;
pub const entries_max: u32 = 65536;
pub const steps_max: u64 = 256 * 1024 * 1024;

pub fn analyze(allocator: std.mem.Allocator, wasm: []const u8, steps: *u64) !Analysis {
    if (wasm.len > input_max) return error.InputLimit;
    var input = reader.Reader{ .bytes = wasm, .steps = steps };
    const header = try input.take(8);
    if (!std.mem.eql(u8, header[0..4], "\x00asm")) return error.InvalidWasmMagic;
    if (!std.mem.eql(u8, header[4..8], "\x01\x00\x00\x00")) return error.InvalidVersion;
    var result = Analysis{
        .imports = &.{},
        .exports = &.{},
        .func_types = &.{},
        .explicit_manifest = null,
        .has_name_section = false,
    };
    var seen: [8]bool = @splat(false);
    for (0..wasm.len) |_| {
        if (input.position == wasm.len) break;
        const id = try input.byte();
        const bytes = try input.take(try input.integer());
        if (id != 0 and id != 1 and id != 2 and id != 7) continue;
        if (id != 0) {
            if (seen[id] or (id == 1 and seen[2])) return error.InvalidSectionOrder;
            seen[id] = true;
        }
        var section = reader.Reader{ .bytes = bytes, .steps = steps };
        try parse_section(allocator, &section, id, &result);
    }
    for (result.imports) |*imp| {
        if (imp.kind == 0) {
            if (imp.type_idx >= result.func_types.len) return error.InvalidTypeIndex;
            imp.func_type = result.func_types[imp.type_idx];
        }
    }
    assert(input.position == wasm.len);
    assert(result.imports.len <= entries_max);
    return result;
}

fn parse_section(
    allocator: std.mem.Allocator,
    section: *reader.Reader,
    id: u8,
    result: *Analysis,
) !void {
    assert(id == 0 or id == 1 or id == 2 or id == 7);
    assert(section.position == 0);
    switch (id) {
        0 => try parse_custom(allocator, section, result),
        1 => result.func_types = try parse_types(allocator, section),
        2 => {
            result.imports = try parse_imports(allocator, section);
            for (result.imports) |*imp| {
                if (imp.kind == 0 and imp.type_idx < result.func_types.len) {
                    imp.func_type = result.func_types[imp.type_idx];
                }
            }
        },
        7 => result.exports = try parse_exports(allocator, section),
        else => assert(false),
    }
    try section.finished();
}

fn entry_count(input: *reader.Reader) !u32 {
    assert(input.position <= input.bytes.len);
    const count = try input.integer();
    if (count > input.bytes.len - input.position) return error.UnexpectedEnd;
    if (count > entries_max) return error.EntryLimit;
    assert(count <= entries_max);
    return count;
}

fn parse_types(allocator: std.mem.Allocator, input: *reader.Reader) ![]FuncType {
    assert(input.position == 0);
    const types = try allocator.alloc(FuncType, try entry_count(input));
    for (types) |*signature| {
        if (try input.byte() != 0x60) return error.InvalidFunctionType;
        const params = try allocator.alloc(WasmValType, try entry_count(input));
        for (params) |*value| value.* = @fromBackingInt(try input.value_type());
        const returns = try allocator.alloc(WasmValType, try entry_count(input));
        for (returns) |*value| value.* = @fromBackingInt(try input.value_type());
        signature.* = .{ .params = params, .returns = returns };
    }
    assert(types.len <= entries_max);
    return types;
}

fn parse_imports(allocator: std.mem.Allocator, input: *reader.Reader) ![]Import {
    assert(input.position == 0);
    const imports = try allocator.alloc(Import, try entry_count(input));
    for (imports) |*imp| {
        const module = try allocator.dupe(u8, try input.name());
        const name = try allocator.dupe(u8, try input.name());
        const kind = try input.byte();
        var type_index: u32 = 0;
        switch (kind) {
            0 => type_index = try input.integer(),
            1 => {
                const reference = try input.value_type();
                if (reference != 0x70 and reference != 0x6f) return error.UnsupportedValueType;
                try input.limits();
            },
            2 => try input.limits(),
            3 => {
                _ = try input.value_type();
                if (try input.byte() > 1) return error.InvalidMutability;
            },
            else => return error.InvalidImportKind,
        }
        imp.* = .{ .module = module, .name = name, .kind = kind, .type_idx = type_index };
    }
    assert(imports.len <= entries_max);
    return imports;
}

fn parse_exports(allocator: std.mem.Allocator, input: *reader.Reader) ![]Export {
    assert(input.position == 0);
    const exports = try allocator.alloc(Export, try entry_count(input));
    for (exports) |*exp| {
        const name = try allocator.dupe(u8, try input.name());
        const kind = try input.byte();
        if (kind > 3) return error.InvalidExportKind;
        exp.* = .{ .name = name, .kind = @fromBackingInt(kind), .index = try input.integer() };
    }
    assert(exports.len <= entries_max);
    return exports;
}

fn parse_custom(allocator: std.mem.Allocator, input: *reader.Reader, result: *Analysis) !void {
    assert(input.position == 0);
    const name = try input.name();
    if (std.mem.eql(u8, name, "name")) {
        result.has_name_section = true;
        for (0..input.bytes.len) |_| {
            if (input.position == input.bytes.len) break;
            const id = try input.byte();
            const bytes = try input.take(try input.integer());
            if (id == 2) {
                var names = reader.Reader{ .bytes = bytes, .steps = input.steps };
                try parse_names(allocator, &names, result.imports);
                try names.finished();
            }
        }
    } else {
        if (std.mem.eql(u8, name, "zunk_bindings")) {
            result.explicit_manifest = input.bytes[input.position..];
        }
        input.position = @intCast(input.bytes.len);
    }
    assert(input.position == input.bytes.len);
}

fn parse_names(allocator: std.mem.Allocator, input: *reader.Reader, imports: []Import) !void {
    assert(input.position == 0);
    const count = try entry_count(input);
    for (0..count) |_| {
        const index = try input.integer();
        const locals = try entry_count(input);
        var signature: ?FuncType = null;
        if (index < imports.len) signature = imports[index].func_type;
        var names: [][]const u8 = &.{};
        if (signature) |value| names = try allocator.alloc([]const u8, value.params.len);
        @memset(names, "");
        for (0..locals) |_| {
            const local_index = try input.integer();
            const name = try input.name();
            if (local_index < names.len) {
                names[local_index] = try allocator.dupe(u8, name);
            }
        }
        if (index < imports.len) imports[index].param_names = names;
    }
    assert(input.position <= input.bytes.len);
}
