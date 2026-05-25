/// File-dialog bridge smoke test for zunk GitHub issue #14.
///
/// Demonstrates the request/poll ABI a host integration (e.g. teak's
/// `Host.requestFileDialog`) drives against the zunk runtime:
///
///   1. On a user click we call `__zunk_request_file_dialog(id, mode,
///      name*, name_len, pattern*, pattern_len)` -- the JS bridge zunk
///      auto-generates opens `showOpenFilePicker` / `showSaveFilePicker`.
///   2. Each frame we check our local slot table for a result. When the
///      browser resolves (or the user cancels) zunk's bridge calls our
///      exported `__zunk_file_dialog_result(id, path*, path_len)`, which
///      copies the path into the slot. `path_len == 0` signals cancel.
///
/// This file deliberately mirrors teak's `wasm.zig` shape (single slot
/// table, 1024-byte path buffer, status enum) so the example doubles as
/// the integration contract.
const std = @import("std");
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;

extern "env" fn __zunk_request_file_dialog(
    id: u32,
    mode: u32,
    name_ptr: [*]const u8,
    name_len: u32,
    pattern_ptr: [*]const u8,
    pattern_len: u32,
) void;

const SlotState = enum { idle, pending, resolved_ok, resolved_cancelled };

const Slot = struct {
    state: SlotState = .idle,
    path_buf: [1024]u8 = undefined,
    path_len: u32 = 0,
};

var slot: Slot = .{};
var ctx: canvas.Ctx2D = undefined;

const bg = canvas.Color{ .r = 17, .g = 17, .b = 22 };
const white = canvas.Color{ .r = 220, .g = 220, .b = 220 };
const dim = canvas.Color{ .r = 110, .g = 110, .b = 120 };
const accent = canvas.Color{ .r = 100, .g = 180, .b = 255 };
const accent_hover = canvas.Color{ .r = 130, .g = 200, .b = 255 };
const ok = canvas.Color{ .r = 130, .g = 220, .b = 130 };
const warn = canvas.Color{ .r = 240, .g = 180, .b = 80 };

const open_btn = Rect{ .x = 40, .y = 100, .w = 220, .h = 44 };
const save_btn = Rect{ .x = 280, .y = 100, .w = 220, .h = 44 };

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h;
    }
};

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk file-dialog demo");
    canvas.setFont(ctx, "14px monospace");
}

export fn frame(_: f32) void {
    input.poll();

    const mouse = input.getMouse();
    const clicked = input.isMouseButtonPressed(.left);

    if (clicked and slot.state != .pending) {
        if (open_btn.contains(mouse.x, mouse.y)) {
            requestDialog(.open);
        } else if (save_btn.contains(mouse.x, mouse.y)) {
            requestDialog(.save);
        }
    }

    draw(mouse);
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

/// zunk's JS bridge writes the chosen path here and flips the slot
/// state. `path_len == 0` means the user cancelled (or the browser
/// rejected the picker). Triggered from the file-picker promise inside
/// the auto-generated JS resolver entry for `__zunk_request_file_dialog`.
export fn __zunk_file_dialog_result(id: u32, path_ptr: [*]const u8, path_len: u32) void {
    if (id != 1 or slot.state != .pending) return;
    if (path_len == 0) {
        slot.state = .resolved_cancelled;
        slot.path_len = 0;
        return;
    }
    const cap: u32 = slot.path_buf.len;
    const copy: u32 = @min(path_len, cap);
    @memcpy(slot.path_buf[0..copy], path_ptr[0..copy]);
    slot.path_len = copy;
    slot.state = .resolved_ok;
}

const Mode = enum(u32) { open = 0, save = 1 };

fn requestDialog(mode: Mode) void {
    slot.state = .pending;
    slot.path_len = 0;
    const name = "Zig sources";
    const pattern = "*.zig;*.zon";
    __zunk_request_file_dialog(
        1,
        @intFromEnum(mode),
        name.ptr,
        name.len,
        pattern.ptr,
        pattern.len,
    );
}

fn draw(mouse: input.Mouse) void {
    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    canvas.setFillColor(ctx, bg);
    canvas.fillRect(ctx, 0, 0, w, h);

    canvas.setFillColor(ctx, white);
    canvas.setFont(ctx, "22px monospace");
    canvas.fillText(ctx, "zunk file-dialog demo", 40, 50);
    canvas.setFont(ctx, "13px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "click a button -- browser picker opens -- result polled each frame", 40, 74);

    drawButton(open_btn, "Open file...", mouse);
    drawButton(save_btn, "Save file...", mouse);

    canvas.setFont(ctx, "14px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "filter: \"Zig sources\" *.zig;*.zon", 40, 180);

    canvas.setFont(ctx, "16px monospace");
    switch (slot.state) {
        .idle => {
            canvas.setFillColor(ctx, dim);
            canvas.fillText(ctx, "status: idle -- waiting for click", 40, 230);
        },
        .pending => {
            canvas.setFillColor(ctx, accent);
            canvas.fillText(ctx, "status: pending -- waiting for picker", 40, 230);
        },
        .resolved_ok => {
            canvas.setFillColor(ctx, ok);
            canvas.fillText(ctx, "status: ok", 40, 230);
            canvas.setFillColor(ctx, white);
            canvas.fillText(ctx, slot.path_buf[0..slot.path_len], 40, 256);
        },
        .resolved_cancelled => {
            canvas.setFillColor(ctx, warn);
            canvas.fillText(ctx, "status: cancelled", 40, 230);
        },
    }
}

fn drawButton(r: Rect, label: []const u8, mouse: input.Mouse) void {
    const hover = r.contains(mouse.x, mouse.y);
    const enabled = slot.state != .pending;
    const fill = if (!enabled) dim else if (hover) accent_hover else accent;
    canvas.setFillColor(ctx, fill);
    canvas.fillRect(ctx, r.x, r.y, r.w, r.h);
    canvas.setFillColor(ctx, bg);
    canvas.setFont(ctx, "16px monospace");
    canvas.fillText(ctx, label, r.x + 16, r.y + 28);
}
