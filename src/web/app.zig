/// zunk/web/app -- App lifecycle, timing, window control, fetch.
///
/// USAGE:
///   const app = @import("zunk").web.app;
///   app.setTitle("My Game");
///   app.logInfo("started up");
///   const t = app.performanceNow();
///
const bind = @import("../bind/bind.zig");

// ============================================================================
// Low-level extern imports
// ============================================================================

extern "env" fn zunk_app_set_title(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_open_url(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_log(level: u32, ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_performance_now() f64;
extern "env" fn zunk_app_set_cursor(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_app_clipboard_write(ptr: [*]const u8, len: u32) void;

// ============================================================================
// Window / document
// ============================================================================

pub fn setTitle(title: []const u8) void {
    zunk_app_set_title(title.ptr, @intCast(title.len));
}

pub fn openUrl(url: []const u8) void {
    zunk_app_open_url(url.ptr, @intCast(url.len));
}

pub fn setCursor(cursor: []const u8) void {
    zunk_app_set_cursor(cursor.ptr, @intCast(cursor.len));
}

// ============================================================================
// Logging
// ============================================================================

pub const LogLevel = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub fn log(level: LogLevel, msg: []const u8) void {
    zunk_app_log(@intFromEnum(level), msg.ptr, @intCast(msg.len));
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

// ============================================================================
// Timing
// ============================================================================

pub fn performanceNow() f64 {
    return zunk_app_performance_now();
}

// ============================================================================
// Clipboard
// ============================================================================

pub fn clipboardWrite(text: []const u8) void {
    zunk_app_clipboard_write(text.ptr, @intCast(text.len));
}
