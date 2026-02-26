const std = @import("std");

pub const WasmValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
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
    func_type: ?FuncType = null,
    param_names: []const []const u8 = &.{},
};

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

pub const ExportKind = enum(u8) {
    func = 0,
    table = 1,
    memory = 2,
    global = 3,
};

pub const Analysis = struct {
    imports: []Import,
    exports: []Export,
    func_types: []FuncType,
    explicit_manifest: ?[]const u8,
    has_name_section: bool,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
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

    pub fn getImportSignature(self: *const Analysis, imp: *const Import) ?FuncType {
        if (imp.func_type) |ft| return ft;
        if (imp.type_idx < self.func_types.len) return self.func_types[imp.type_idx];
        return null;
    }

    pub fn hasExport(self: *const Analysis, name: []const u8) bool {
        for (self.exports) |exp| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, name)) return true;
        }
        return false;
    }
};

const SECTION_TYPE: u8 = 1;
const SECTION_IMPORT: u8 = 2;
const SECTION_EXPORT: u8 = 7;
const SECTION_CUSTOM: u8 = 0;

pub fn analyze(allocator: std.mem.Allocator, wasm: []const u8) !Analysis {
    var result = Analysis{
        .imports = &.{},
        .exports = &.{},
        .func_types = &.{},
        .explicit_manifest = null,
        .has_name_section = false,
    };

    if (wasm.len < 8) return result;

    if (!std.mem.eql(u8, wasm[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6D })) {
        return error.InvalidWasmMagic;
    }

    var pos: usize = 8;

    var imports_list: std.ArrayList(Import) = .empty;
    defer imports_list.deinit(allocator);
    var exports_list: std.ArrayList(Export) = .empty;
    defer exports_list.deinit(allocator);
    var types_list: std.ArrayList(FuncType) = .empty;
    defer types_list.deinit(allocator);

    while (pos < wasm.len) {
        const section_id = wasm[pos];
        pos += 1;
        const section_size = readLeb128(wasm, &pos) orelse break;
        const section_end = pos + section_size;

        switch (section_id) {
            SECTION_TYPE => {
                try parseTypeSection(allocator, wasm, &pos, section_end, &types_list);
            },
            SECTION_IMPORT => {
                try parseImportSection(allocator, wasm, &pos, section_end, &imports_list);
            },
            SECTION_EXPORT => {
                try parseExportSection(allocator, wasm, &pos, section_end, &exports_list);
            },
            SECTION_CUSTOM => {
                const name_len = readLeb128(wasm, &pos) orelse break;
                if (pos + name_len <= section_end) {
                    const section_name = wasm[pos .. pos + name_len];
                    pos += name_len;

                    if (std.mem.eql(u8, section_name, "name")) {
                        result.has_name_section = true;
                        parseNameSection(allocator, wasm, &pos, section_end, imports_list.items) catch {};
                    } else if (std.mem.eql(u8, section_name, "zunk_bindings")) {
                        if (section_end > pos) {
                            result.explicit_manifest = wasm[pos..section_end];
                        }
                    }
                }
                pos = section_end;
            },
            else => {
                pos = section_end;
            },
        }
    }

    for (imports_list.items) |*imp| {
        if (imp.type_idx < types_list.items.len) {
            imp.func_type = types_list.items[imp.type_idx];
        }
    }

    result.imports = try imports_list.toOwnedSlice(allocator);
    result.exports = try exports_list.toOwnedSlice(allocator);
    result.func_types = try types_list.toOwnedSlice(allocator);

    return result;
}

fn parseTypeSection(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    pos: *usize,
    end: usize,
    types: *std.ArrayList(FuncType),
) !void {
    const count = readLeb128(wasm, pos) orelse return;
    var i: usize = 0;
    while (i < count and pos.* < end) : (i += 1) {
        if (pos.* >= wasm.len or wasm[pos.*] != 0x60) {
            pos.* = end;
            return;
        }
        pos.* += 1;

        // Read params
        const num_params = readLeb128(wasm, pos) orelse return;
        var params = try allocator.alloc(WasmValType, num_params);
        var j: usize = 0;
        while (j < num_params) : (j += 1) {
            if (pos.* >= wasm.len) break;
            params[j] = @enumFromInt(wasm[pos.*]);
            pos.* += 1;
        }

        // Read returns
        const num_returns = readLeb128(wasm, pos) orelse {
            allocator.free(params);
            return;
        };
        var returns = try allocator.alloc(WasmValType, num_returns);
        j = 0;
        while (j < num_returns) : (j += 1) {
            if (pos.* >= wasm.len) break;
            returns[j] = @enumFromInt(wasm[pos.*]);
            pos.* += 1;
        }

        try types.append(allocator, .{ .params = params, .returns = returns });
    }
}

fn parseImportSection(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    pos: *usize,
    end: usize,
    imports: *std.ArrayList(Import),
) !void {
    const count = readLeb128(wasm, pos) orelse return;
    var i: usize = 0;
    while (i < count and pos.* < end) : (i += 1) {
        const mod_len = readLeb128(wasm, pos) orelse return;
        if (pos.* + mod_len > wasm.len) return;
        const module = try allocator.dupe(u8, wasm[pos.* .. pos.* + mod_len]);
        pos.* += mod_len;

        const name_len = readLeb128(wasm, pos) orelse {
            allocator.free(module);
            return;
        };
        if (pos.* + name_len > wasm.len) {
            allocator.free(module);
            return;
        }
        const name = try allocator.dupe(u8, wasm[pos.* .. pos.* + name_len]);
        pos.* += name_len;

        if (pos.* >= wasm.len) {
            allocator.free(module);
            allocator.free(name);
            return;
        }
        const kind = wasm[pos.*];
        pos.* += 1;

        if (kind == 0) {
            const type_idx = readLeb128(wasm, pos) orelse {
                allocator.free(module);
                allocator.free(name);
                return;
            };
            try imports.append(allocator, .{
                .module = module,
                .name = name,
                .type_idx = @intCast(type_idx),
            });
        } else {
            allocator.free(module);
            allocator.free(name);
            switch (kind) {
                1 => {
                    pos.* += 1;
                    skipLimits(wasm, pos);
                },
                2 => {
                    skipLimits(wasm, pos);
                },
                3 => {
                    pos.* += 2;
                },
                else => {},
            }
        }
    }
}

fn parseExportSection(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    pos: *usize,
    end: usize,
    exports: *std.ArrayList(Export),
) !void {
    const count = readLeb128(wasm, pos) orelse return;
    var i: usize = 0;
    while (i < count and pos.* < end) : (i += 1) {
        const name_len = readLeb128(wasm, pos) orelse return;
        if (pos.* + name_len > wasm.len) return;
        const name = try allocator.dupe(u8, wasm[pos.* .. pos.* + name_len]);
        pos.* += name_len;

        if (pos.* >= wasm.len) {
            allocator.free(name);
            return;
        }
        const kind: ExportKind = @enumFromInt(wasm[pos.*]);
        pos.* += 1;

        const index = readLeb128(wasm, pos) orelse {
            allocator.free(name);
            return;
        };

        try exports.append(allocator, .{
            .name = name,
            .kind = kind,
            .index = @intCast(index),
        });
    }
}

fn parseNameSection(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    pos: *usize,
    end: usize,
    imports: []Import,
) !void {
    while (pos.* < end) {
        if (pos.* >= wasm.len) return;
        const subsection_id = wasm[pos.*];
        pos.* += 1;
        const subsection_size = readLeb128(wasm, pos) orelse return;
        const subsection_end = pos.* + subsection_size;

        if (subsection_id == 2) {
            const func_count = readLeb128(wasm, pos) orelse return;
            var fi: usize = 0;
            while (fi < func_count and pos.* < subsection_end) : (fi += 1) {
                const func_idx = readLeb128(wasm, pos) orelse return;
                const local_count = readLeb128(wasm, pos) orelse return;

                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(allocator);

                var li: usize = 0;
                while (li < local_count and pos.* < subsection_end) : (li += 1) {
                    _ = readLeb128(wasm, pos) orelse break;
                    const nl = readLeb128(wasm, pos) orelse break;
                    if (pos.* + nl <= wasm.len) {
                        try names.append(allocator, try allocator.dupe(u8, wasm[pos.* .. pos.* + nl]));
                        pos.* += nl;
                    }
                }

                if (func_idx < imports.len) {
                    imports[func_idx].param_names = try names.toOwnedSlice(allocator);
                } else {
                    for (names.items) |n| allocator.free(n);
                }
            }
        }

        pos.* = subsection_end;
    }
}

fn readLeb128(data: []const u8, pos: *usize) ?usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(usize, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
        if (shift > 35) return null;
    }
    return null;
}

fn skipLimits(wasm: []const u8, pos: *usize) void {
    if (pos.* >= wasm.len) return;
    const flags = wasm[pos.*];
    pos.* += 1;
    _ = readLeb128(wasm, pos);
    if (flags & 1 != 0) {
        _ = readLeb128(wasm, pos);
    }
}

test "analyze minimal wasm" {
    const minimal = [_]u8{
        0x00, 0x61, 0x73, 0x6D,
        0x01, 0x00, 0x00, 0x00,
    };
    var result = try analyze(std.testing.allocator, &minimal);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.imports.len);
    try std.testing.expectEqual(@as(usize, 0), result.exports.len);
}
