/// zunk/bind -- Comptime binding descriptor system for Zig <-> Browser JS FFI.
///
/// Write your Web API bindings ONCE in Zig. Comptime generates:
///   1. The `extern fn` declarations your Zig code calls
///   2. A binding manifest embedded in a WASM custom section
///      that zunk reads to auto-generate the matching JavaScript
///
/// USAGE IN A LIBRARY (e.g., your WebGPU UI lib):
///
///   const web = @import("zunk-bind");
///
///   pub const canvas = web.defineModule("canvas", .{
///       web.func("getContext", .{ .selector = JsSelector }, .{ .ctx_handle = Handle }),
///       web.func("setSize",   .{ .w = u32, .h = u32 },      .{}),
///       web.func("clear",     .{ .r = f32, .g = f32, .b = f32, .a = f32 }, .{}),
///   });
///
/// USAGE IN APP CODE:
///
///   canvas.getContext("#my-canvas");
///   canvas.setSize(800, 600);
///
const std = @import("std");

/// How a value crosses the WASM boundary.
pub const ValKind = enum(u8) {
    i32,
    i64,
    f32,
    f64,
    bool,
    handle,
    string,
    bytes,
    void,
    enum_val,
    struct_val,

    pub fn wasmParamCount(self: ValKind) u8 {
        return switch (self) {
            .string, .bytes, .struct_val => 2,
            .void => 0,
            else => 1,
        };
    }
};

pub const ValDesc = struct {
    name: []const u8,
    kind: ValKind,
    enum_variants: ?[]const []const u8 = null,
    struct_fields: ?[]const ValDesc = null,
    optional: bool = false,
};

pub const FuncDesc = struct {
    name: []const u8,
    module: []const u8 = "",
    params: []const ValDesc,
    ret: ValDesc = .{ .name = "result", .kind = .void },
    js_hint: ?JsHint = null,
    is_callback: bool = false,
};

pub const JsHint = enum(u8) {
    builtin,
    dom,
    webgpu,
    audio,
    event,
    network,
    custom,
};

pub fn Module(comptime descs: []const FuncDesc) type {
    return struct {
        pub const descriptors = descs;
        pub const manifest = serializeManifest(descs);
    };
}

/// Opaque reference to a JS object (maps to an integer ID in the JS handle table).
pub const Handle = enum(i32) {
    null_handle = 0,
    _,

    pub fn isNull(self: Handle) bool {
        return self == .null_handle;
    }

    pub fn toInt(self: Handle) i32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(id: i32) Handle {
        return @enumFromInt(id);
    }
};

// 64 KB shared buffer for Zig<->JS string exchange.
var string_exchange_buffer: [64 * 1024]u8 = undefined;

pub export fn __zunk_string_buf_ptr() [*]u8 {
    return &string_exchange_buffer;
}

pub export fn __zunk_string_buf_len() usize {
    return string_exchange_buffer.len;
}

pub fn readExchangeString(len: usize) []const u8 {
    if (len > string_exchange_buffer.len) return &.{};
    return string_exchange_buffer[0..len];
}

pub fn writeExchangeString(s: []const u8) struct { ptr: [*]const u8, len: usize } {
    const write_len = @min(s.len, string_exchange_buffer.len);
    @memcpy(string_exchange_buffer[0..write_len], s[0..write_len]);
    return .{ .ptr = &string_exchange_buffer, .len = write_len };
}

const MAX_CALLBACKS = 256;

pub const CallbackFn = *const fn (arg0: i32, arg1: i32, arg2: i32, arg3: i32) void;

var callback_table: [MAX_CALLBACKS]?CallbackFn = [_]?CallbackFn{null} ** MAX_CALLBACKS;
var next_callback_id: u32 = 1;

pub fn registerCallback(cb: CallbackFn) u32 {
    const id = next_callback_id;
    if (id >= MAX_CALLBACKS) return 0;
    callback_table[id] = cb;
    next_callback_id += 1;
    return id;
}

pub export fn __zunk_invoke_callback(id: u32, a0: i32, a1: i32, a2: i32, a3: i32) void {
    if (id < MAX_CALLBACKS) {
        if (callback_table[id]) |cb| {
            cb(a0, a1, a2, a3);
        }
    }
}

fn serializeManifest(comptime descs: []const FuncDesc) []const u8 {
    comptime {
        var size: usize = 2;
        for (descs) |d| {
            size += 1 + d.module.len;
            size += 1 + d.name.len;
            size += 1;
            for (d.params) |p| {
                size += 1 + p.name.len + 1 + 1;
            }
            size += 1 + 1 + 1;
        }

        var buf: [size]u8 = undefined;
        var pos: usize = 0;

        buf[pos] = @intCast(descs.len & 0xFF);
        pos += 1;
        buf[pos] = @intCast((descs.len >> 8) & 0xFF);
        pos += 1;

        for (descs) |d| {
            buf[pos] = @intCast(d.module.len);
            pos += 1;
            for (d.module) |c| {
                buf[pos] = c;
                pos += 1;
            }
            buf[pos] = @intCast(d.name.len);
            pos += 1;
            for (d.name) |c| {
                buf[pos] = c;
                pos += 1;
            }
            buf[pos] = @intCast(d.params.len);
            pos += 1;
            for (d.params) |p| {
                buf[pos] = @intCast(p.name.len);
                pos += 1;
                for (p.name) |c| {
                    buf[pos] = c;
                    pos += 1;
                }
                buf[pos] = @intFromEnum(p.kind);
                pos += 1;
                buf[pos] = @intFromBool(p.optional);
                pos += 1;
            }
            buf[pos] = @intFromEnum(d.ret.kind);
            pos += 1;
            buf[pos] = if (d.js_hint) |h| @intFromEnum(h) else 0;
            pos += 1;
            buf[pos] = @intFromBool(d.is_callback);
            pos += 1;
        }

        return &buf;
    }
}

pub fn param(comptime name: []const u8, comptime kind: ValKind) ValDesc {
    return .{ .name = name, .kind = kind };
}

pub fn optParam(comptime name: []const u8, comptime kind: ValKind) ValDesc {
    return .{ .name = name, .kind = kind, .optional = true };
}

pub fn ret(comptime kind: ValKind) ValDesc {
    return .{ .name = "result", .kind = kind };
}

pub fn func(
    comptime name: []const u8,
    comptime module: []const u8,
    comptime params: []const ValDesc,
    comptime return_val: ValDesc,
    comptime hint: ?JsHint,
) FuncDesc {
    return .{
        .name = name,
        .module = module,
        .params = params,
        .ret = return_val,
        .js_hint = hint,
    };
}

pub fn callback(
    comptime name: []const u8,
    comptime module: []const u8,
    comptime params: []const ValDesc,
) FuncDesc {
    return .{
        .name = name,
        .module = module,
        .params = params,
        .is_callback = true,
    };
}

test "ValKind wasm param counts" {
    try std.testing.expectEqual(@as(u8, 1), ValKind.i32.wasmParamCount());
    try std.testing.expectEqual(@as(u8, 2), ValKind.string.wasmParamCount());
    try std.testing.expectEqual(@as(u8, 0), ValKind.void.wasmParamCount());
}

test "Handle round-trip" {
    const h = Handle.fromInt(42);
    try std.testing.expectEqual(@as(i32, 42), h.toInt());
    try std.testing.expect(!h.isNull());
    try std.testing.expect(Handle.null_handle.isNull());
}

test "manifest serialization compiles" {
    const descs = comptime [_]FuncDesc{
        func("getContext", "canvas", &.{param("sel", .string)}, ret(.handle), .dom),
        func("clear", "canvas", &.{ param("r", .f32), param("g", .f32) }, ret(.void), .dom),
    };
    const m = comptime serializeManifest(&descs);
    try std.testing.expect(m.len > 0);
    try std.testing.expectEqual(@as(u8, 2), m[0]);
}
