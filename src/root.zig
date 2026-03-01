/// # zunk -- Write web apps in pure Zig.
///
/// zunk provides everything you need to build and ship Zig WASM applications:
///
///   - **Runtime library** (this file): Web API bindings your Zig code imports
///   - **Build tool** (`zunk run` / `zunk deploy`): Compiles, bundles, and serves
///
/// ## Quick Start
///
/// ```zig
/// const zunk = @import("zunk");
/// const canvas = zunk.web.canvas;
/// const input = zunk.web.input;
/// const app = zunk.web.app;
///
/// var ctx: canvas.Ctx2D = undefined;
///
/// export fn init() void {
///     input.init();
///     ctx = canvas.getContext2D("app");
///     app.setTitle("My Game");
/// }
///
/// export fn frame(dt: f32) void {
///     input.poll();
///     if (input.isKeyDown(.space)) { /* jump */ }
///     canvas.clearRect(ctx, 0, 0, 800, 600);
///     canvas.setFillColor(ctx, .{ .r = 255, .g = 100, .b = 50 });
///     canvas.fillRect(ctx, 100, 100, 50, 50);
/// }
///
/// export fn resize(w: u32, h: u32) void {
///     canvas.setSize(ctx, w, h);
/// }
/// ```
///
/// ## Exported Lifecycle Functions
///
/// Your WASM module should export these functions for zunk's JS to call:
///
///   - `export fn init() void` -- Called once after WASM loads
///   - `export fn frame(dt: f32) void` -- Called every requestAnimationFrame
///   - `export fn resize(w: u32, h: u32) void` -- Called on window resize
///   - `export fn cleanup() void` -- Called on page unload (optional)
///

pub const bind = @import("bind/bind.zig");

pub const web = struct {
    pub const canvas = @import("web/canvas.zig");
    pub const input = @import("web/input.zig");
    pub const audio = @import("web/audio.zig");
    pub const app = @import("web/app.zig");
    pub const asset = @import("web/asset.zig");
    pub const gpu = @import("web/gpu.zig");
    pub const ui = @import("web/ui.zig");
};

pub const Handle = bind.Handle;
pub const CallbackFn = bind.CallbackFn;
pub const registerCallback = bind.registerCallback;
pub const readExchangeString = bind.readExchangeString;
pub const writeExchangeString = bind.writeExchangeString;

// Force these exports into the WASM binary.
comptime {
    _ = &bind.__zunk_string_buf_ptr;
    _ = &bind.__zunk_string_buf_len;
    _ = &bind.__zunk_invoke_callback;
}

test {
    @import("std").testing.refAllDecls(@This());
}
