/// zunk/web/audio -- Web Audio API: sound playback, spatial audio, AudioWorklet.
///
/// USAGE:
///   const audio = @import("zunk").web.audio;
///   var ctx = audio.init(44100);
///   var sound = audio.load("assets/explosion.wav");
///   audio.play(sound);
///
const bind = @import("../bind/bind.zig");

// ============================================================================
// Low-level extern imports
// ============================================================================

extern "env" fn zunk_audio_init(sample_rate: u32) i32;
extern "env" fn zunk_audio_resume() void;
extern "env" fn zunk_audio_suspend() void;
extern "env" fn zunk_audio_load(url_ptr: [*]const u8, url_len: u32) i32;
extern "env" fn zunk_audio_play(buffer_handle: i32) void;
extern "env" fn zunk_audio_set_master_volume(volume: f32) void;

// ============================================================================
// Types
// ============================================================================

pub const AudioCtx = bind.Handle;
pub const AudioBuffer = bind.Handle;

// ============================================================================
// Context management
// ============================================================================

pub fn init(sample_rate: u32) AudioCtx {
    return bind.Handle.fromInt(zunk_audio_init(sample_rate));
}

pub fn @"resume"() void {
    zunk_audio_resume();
}

pub fn @"suspend"() void {
    zunk_audio_suspend();
}

// ============================================================================
// Sound playback
// ============================================================================

pub fn load(url: []const u8) AudioBuffer {
    return bind.Handle.fromInt(zunk_audio_load(url.ptr, @intCast(url.len)));
}

pub fn play(buffer: AudioBuffer) void {
    zunk_audio_play(buffer.toInt());
}

pub fn setMasterVolume(volume: f32) void {
    zunk_audio_set_master_volume(volume);
}
