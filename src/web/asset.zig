const bind = @import("../bind/bind.zig");

extern "env" fn zunk_asset_fetch(url_ptr: [*]const u8, url_len: u32) i32;
extern "env" fn zunk_asset_is_ready(handle: i32) i32;
extern "env" fn zunk_asset_get_len(handle: i32) i32;
extern "env" fn zunk_asset_get_ptr(handle: i32, dest_ptr: [*]u8) i32;

pub const Handle = bind.Handle;

/// Start fetching an asset from a URL. Returns a handle immediately;
/// the browser fetches asynchronously. Poll with isReady().
pub fn fetch(url: []const u8) Handle {
    return bind.Handle.fromInt(zunk_asset_fetch(url.ptr, @intCast(url.len)));
}

/// Returns true once the fetch has completed and the raw bytes are available.
pub fn isReady(handle: Handle) bool {
    return zunk_asset_is_ready(handle.toInt()) != 0;
}

/// Returns the byte length of the fetched asset, or 0 if not yet ready.
pub fn getLen(handle: Handle) usize {
    return @intCast(zunk_asset_get_len(handle.toInt()));
}

/// Copy fetched bytes into the provided buffer. Returns the filled slice.
pub fn getBytes(handle: Handle, dest: []u8) []u8 {
    const len: usize = @intCast(zunk_asset_get_ptr(handle.toInt(), dest.ptr));
    return dest[0..len];
}

// TODO: fetchAll(urls) -> []Handle -- batch loading
// TODO: getProgress(handle) -> f32 -- download progress (0.0 to 1.0)
// TODO: fetchStreaming(url) -> StreamHandle -- progressive/streaming loading
// TODO: fetchWithOptions(url, .{ .cache = .reload }) -- cache control
