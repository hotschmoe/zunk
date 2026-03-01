const bind = @import("../bind/bind.zig");

extern "env" fn zunk_audio_init(sample_rate: u32) i32;
extern "env" fn zunk_audio_resume() void;
extern "env" fn zunk_audio_suspend() void;
extern "env" fn zunk_audio_load(url_ptr: [*]const u8, url_len: u32) i32;
extern "env" fn zunk_audio_load_memory(data_ptr: [*]const u8, data_len: u32) i32;
extern "env" fn zunk_audio_is_ready(buffer_handle: i32) i32;
extern "env" fn zunk_audio_play(buffer_handle: i32) void;
extern "env" fn zunk_audio_decode_asset(asset_handle: i32) i32;
extern "env" fn zunk_audio_set_master_volume(volume: f32) void;

pub const AudioCtx = bind.Handle;
pub const AudioBuffer = bind.Handle;

pub fn init(sample_rate: u32) AudioCtx {
    return bind.Handle.fromInt(zunk_audio_init(sample_rate));
}

pub fn @"resume"() void {
    zunk_audio_resume();
}

pub fn @"suspend"() void {
    zunk_audio_suspend();
}

pub fn load(url: []const u8) AudioBuffer {
    return bind.Handle.fromInt(zunk_audio_load(url.ptr, @intCast(url.len)));
}

/// Load audio from raw bytes (e.g. from @embedFile). Returns a handle
/// immediately; the browser decodes asynchronously. Use isReady() to
/// check when the buffer can be played.
pub fn loadFromMemory(data: []const u8) AudioBuffer {
    return bind.Handle.fromInt(zunk_audio_load_memory(data.ptr, @intCast(data.len)));
}

/// Returns true once an async load/decode has completed and the buffer
/// is ready to play.
pub fn isReady(buffer: AudioBuffer) bool {
    return zunk_audio_is_ready(buffer.toInt()) != 0;
}

pub fn play(buffer: AudioBuffer) void {
    zunk_audio_play(buffer.toInt());
}

/// Decode a fetched asset (from zunk.web.asset) as audio. Poll isReady().
pub fn decodeAsset(asset_handle: bind.Handle) AudioBuffer {
    return bind.Handle.fromInt(zunk_audio_decode_asset(asset_handle.toInt()));
}

pub fn setMasterVolume(volume: f32) void {
    zunk_audio_set_master_volume(volume);
}
