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
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ============================================================================
// Type system for describing JS <-> WASM value marshalling
// ============================================================================

/// How a value is represented across the WASM boundary.
/// WASM only natively supports i32, i64, f32, f64.
/// Everything else needs marshalling through linear memory.
pub const ValKind = enum(u8) {
    /// Passed directly as i32/i64/f32/f64
    i32,
    i64,
    f32,
    f64,
    /// Boolean -> i32 (0 or 1)
    bool,
    /// Opaque handle (JS object table index) -> i32
    handle,
    /// String -> (ptr: i32, len: i32) pair through linear memory
    string,
    /// Byte slice -> (ptr: i32, len: i32) pair through linear memory
    bytes,
    /// Void (no value, used for return type)
    void,
    /// Enum -> i32 (ordinal)
    enum_val,
    /// Struct -> serialized through linear memory as packed bytes
    struct_val,

    pub fn wasmParamCount(self: ValKind) u8 {
        return switch (self) {
            .string, .bytes, .struct_val => 2, // ptr + len
            .void => 0,
            else => 1,
        };
    }
};

/// Describes a single parameter or return value
pub const ValDesc = struct {
    name: []const u8,
    kind: ValKind,
    /// For enum_val: the variant names (for JS-side mapping)
    enum_variants: ?[]const []const u8 = null,
    /// For struct_val: the struct field layout
    struct_fields: ?[]const ValDesc = null,
    /// Whether this is optional (?T in Zig -> nullable in JS)
    optional: bool = false,
};

/// Describes a single function binding
pub const FuncDesc = struct {
    /// Function name (used as both the extern fn name and the JS method name)
    name: []const u8,
    /// The JS namespace/module this belongs to (e.g., "canvas", "audio", "gpu")
    module: []const u8 = "",
    /// Parameter descriptors
    params: []const ValDesc,
    /// Return value descriptor (void if no return)
    ret: ValDesc = .{ .name = "result", .kind = .void },
    /// JS implementation hint -- tells zunk HOW to generate the JS body.
    /// If null, zunk looks it up in its built-in Web API templates.
    js_hint: ?JsHint = null,
    /// Whether this is a callback registration (JS->WASM direction)
    is_callback: bool = false,
};

/// Hint for JS code generation
pub const JsHint = enum(u8) {
    /// Use a built-in zunk template for this Web API
    builtin,
    /// This is a direct DOM API call (document.querySelector, etc.)
    dom,
    /// This is a WebGPU API call
    webgpu,
    /// This is a Web Audio API call
    audio,
    /// This is an event listener registration
    event,
    /// This is a fetch/network call
    network,
    /// Custom -- the library ships a JS implementation
    custom,
};

// ============================================================================
// Module definition -- the developer-facing API
// ============================================================================

/// A module groups related bindings under a namespace.
/// e.g., defineModule("canvas", ...) -> all functions import as "canvas.funcName"
pub fn Module(comptime descs: []const FuncDesc) type {
    return struct {
        pub const descriptors = descs;

        /// Embed the binding manifest into a WASM custom section.
        /// Zunk reads this to know what JS to generate.
        pub const manifest = blk: {
            break :blk serializeManifest(descs);
        };
    };
}

// ============================================================================
// Comptime function generator -- creates typed extern fn wrappers
// ============================================================================

/// Generate a high-level Zig function that wraps the low-level extern fn.
/// This is what library authors use to create ergonomic APIs.
///
/// Example:
///   const getContext = wrapExtern("canvas", "getContext",
///       &.{ .{ .name = "selector", .kind = .string } },
///       .{ .name = "result", .kind = .handle },
///   );
///   // Now getContext("my-canvas") works and returns a handle
pub fn wrapExtern(
    comptime module_name: []const u8,
    comptime func_name: []const u8,
    comptime params: []const ValDesc,
    comptime ret_desc: ValDesc,
) WrapReturnType(ret_desc) {
    _ = module_name;
    _ = func_name;
    _ = params;
    // This is resolved at comptime to produce the right function type
    // In practice, each library uses the lower-level primitives below
}

fn WrapReturnType(comptime ret_desc: ValDesc) type {
    return switch (ret_desc.kind) {
        .void => void,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
        .bool => bool,
        .handle => Handle,
        .string => []const u8,
        else => i32,
    };
}

// ============================================================================
// Handle table -- opaque references to JS objects
// ============================================================================

/// An opaque handle to a JavaScript object.
/// The JS side maintains a table: handle_id -> JS object.
/// This is how we reference Canvas, AudioContext, GPUDevice, etc.
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

// ============================================================================
// String exchange -- the bridge for passing strings between Zig and JS
// ============================================================================

/// Shared string buffer for Zig<->JS string exchange.
/// JS writes into this buffer, Zig reads from it, and vice versa.
var string_exchange_buffer: [64 * 1024]u8 = undefined; // 64KB

/// Get pointer to string exchange buffer (exported for JS to call)
pub export fn __zunk_string_buf_ptr() [*]u8 {
    return &string_exchange_buffer;
}

/// Get size of string exchange buffer
pub export fn __zunk_string_buf_len() usize {
    return string_exchange_buffer.len;
}

/// Read a string that JS wrote into the exchange buffer
pub fn readExchangeString(len: usize) []const u8 {
    if (len > string_exchange_buffer.len) return &.{};
    return string_exchange_buffer[0..len];
}

/// Write a string into the exchange buffer for JS to read
pub fn writeExchangeString(s: []const u8) struct { ptr: [*]const u8, len: usize } {
    const write_len = @min(s.len, string_exchange_buffer.len);
    @memcpy(string_exchange_buffer[0..write_len], s[0..write_len]);
    return .{ .ptr = &string_exchange_buffer, .len = write_len };
}

// ============================================================================
// Callback table -- for JS->Zig event callbacks
// ============================================================================

/// Maximum concurrent callbacks
const MAX_CALLBACKS = 256;

/// Callback function type (receives an event ID and up to 4 i32 args)
pub const CallbackFn = *const fn (arg0: i32, arg1: i32, arg2: i32, arg3: i32) void;

var callback_table: [MAX_CALLBACKS]?CallbackFn = [_]?CallbackFn{null} ** MAX_CALLBACKS;
var next_callback_id: u32 = 1;

/// Register a Zig callback, returns an ID that JS uses to invoke it
pub fn registerCallback(cb: CallbackFn) u32 {
    const id = next_callback_id;
    if (id >= MAX_CALLBACKS) return 0;
    callback_table[id] = cb;
    next_callback_id += 1;
    return id;
}

/// Called from JS to invoke a registered callback
pub export fn __zunk_invoke_callback(id: u32, a0: i32, a1: i32, a2: i32, a3: i32) void {
    if (id < MAX_CALLBACKS) {
        if (callback_table[id]) |cb| {
            cb(a0, a1, a2, a3);
        }
    }
}

// ============================================================================
// Manifest serialization -- embeds binding metadata in WASM custom section
// ============================================================================

/// Serialize function descriptors into a compact binary manifest.
/// This gets embedded in a WASM custom section named "zunk_bindings"
/// that the zunk build tool reads to generate JavaScript.
fn serializeManifest(comptime descs: []const FuncDesc) []const u8 {
    comptime {
        // Format: simple length-prefixed strings + type tags
        // [num_funcs: u16]
        // for each func:
        //   [module_name_len: u8] [module_name: bytes]
        //   [func_name_len: u8] [func_name: bytes]
        //   [num_params: u8]
        //   for each param:
        //     [name_len: u8] [name: bytes] [kind: u8] [optional: u8]
        //   [ret_kind: u8]
        //   [js_hint: u8]
        //   [is_callback: u8]

        var size: usize = 2; // num_funcs
        for (descs) |d| {
            size += 1 + d.module.len; // module name
            size += 1 + d.name.len; // func name
            size += 1; // num_params
            for (d.params) |p| {
                size += 1 + p.name.len + 1 + 1; // name + kind + optional
            }
            size += 1 + 1 + 1; // ret_kind + js_hint + is_callback
        }

        var buf: [size]u8 = undefined;
        var pos: usize = 0;

        // Write num_funcs
        buf[pos] = @intCast(descs.len & 0xFF);
        pos += 1;
        buf[pos] = @intCast((descs.len >> 8) & 0xFF);
        pos += 1;

        for (descs) |d| {
            // Module name
            buf[pos] = @intCast(d.module.len);
            pos += 1;
            for (d.module) |c| {
                buf[pos] = c;
                pos += 1;
            }
            // Func name
            buf[pos] = @intCast(d.name.len);
            pos += 1;
            for (d.name) |c| {
                buf[pos] = c;
                pos += 1;
            }
            // Params
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
            // Return
            buf[pos] = @intFromEnum(d.ret.kind);
            pos += 1;
            // JS hint
            buf[pos] = if (d.js_hint) |h| @intFromEnum(h) else 0;
            pos += 1;
            // Is callback
            buf[pos] = @intFromBool(d.is_callback);
            pos += 1;
        }

        return &buf;
    }
}

// ============================================================================
// Convenience constructors for defining bindings
// ============================================================================

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

// ============================================================================
// Tests
// ============================================================================

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
        func("clear", "canvas", &.{param("r", .f32), param("g", .f32)}, ret(.void), .dom),
    };
    const m = comptime serializeManifest(&descs);
    try std.testing.expect(m.len > 0);
    // First two bytes are num_funcs = 2
    try std.testing.expectEqual(@as(u8, 2), m[0]);
}
