pub const bind = @import("bind/bind.zig");

pub const web = struct {
    pub const canvas = @import("web/canvas.zig");
    pub const input = @import("web/input.zig");
    pub const audio = @import("web/audio.zig");
    pub const app = @import("web/app.zig");
    pub const asset = @import("web/asset.zig");
    pub const fx = @import("web/fx.zig");
    pub const ime = @import("web/ime.zig");
    pub const gpu = @import("web/gpu.zig");
    pub const ui = @import("web/ui.zig");
    pub const imgui = @import("web/imgui.zig");
    pub const render_backend = @import("web/render_backend.zig");
    pub const logFn = app.logFn;
};

pub const Handle = bind.Handle;
pub const CallbackFn = bind.CallbackFn;
pub const registerCallback = bind.registerCallback;
pub const readExchangeString = bind.readExchangeString;
pub const writeExchangeString = bind.writeExchangeString;

// Version source and release procedure: docs/VERSIONING.md.
pub const version: []const u8 = @import("build_options").version;

// Keep the exchange and callback exports in the WASM binary.
comptime {
    _ = &bind.__zunk_string_buf_ptr;
    _ = &bind.__zunk_string_buf_len;
    _ = &bind.__zunk_invoke_callback;
}
