const std = @import("std");
const bind = @import("../bind/bind.zig");

extern "env" fn zunk_app_set_title(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_open_url(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_log(level: u32, ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_performance_now() f64;
extern "env" fn zunk_app_set_cursor(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_clipboard_write(ptr: [*]const u8, len: u32) void;

pub fn setTitle(title: []const u8) void {
    zunk_app_set_title(title.ptr, @intCast(title.len));
}

pub fn openUrl(url: []const u8) void {
    zunk_app_open_url(url.ptr, @intCast(url.len));
}

pub fn setCursor(cursor: []const u8) void {
    zunk_app_set_cursor(cursor.ptr, @intCast(cursor.len));
}

pub const LogLevel = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub fn log(level: LogLevel, msg: []const u8) void {
    zunk_app_log(@backingInt(level), msg.ptr, @intCast(msg.len));
}

pub fn logDebug(msg: []const u8) void {
    log(.debug, msg);
}

pub fn logInfo(msg: []const u8) void {
    log(.info, msg);
}

pub fn logWarn(msg: []const u8) void {
    log(.warn, msg);
}

pub fn logErr(msg: []const u8) void {
    log(.err, msg);
}

/// A `std.Options.logFn` that routes `std.log` to the browser console
/// (`console.debug/info/warn/error` by level). The default logFn pulls in
/// `std.Io.Threaded`, which does not compile on wasm32-freestanding, so any
/// wasm entry point that (transitively) calls `std.log` must declare:
///
///     pub const std_options: std.Options = .{ .logFn = zunk.web.logFn };
///
/// Lines longer than 512 bytes are truncated.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    const msg = std.fmt.bufPrint(&buf, prefix ++ format, args) catch buf[0..];
    log(switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    }, msg);
}

pub fn performanceNow() f64 {
    return zunk_app_performance_now();
}

pub fn clipboardWrite(text: []const u8) void {
    zunk_app_clipboard_write(text.ptr, @intCast(text.len));
}
