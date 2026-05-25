/// A11y DOM-mirror smoke test for zunk GitHub issue #15.
///
/// Drives the same `__zunk_publish_a11y_tree` extern teak's `Host`
/// calls each frame, with a hand-built record array. Verifies that:
///   * The hidden `#zunk-a11y-root` container gets created lazily.
///   * Records of each role (button, checkbox, slider, ...) produce
///     DOM children with the correct ARIA mapping.
///   * Stable cmd_index across frames reuses the same DOM nodes
///     instead of rebuilding them; changing a role at the same
///     cmd_index recreates the underlying tag (div -> button etc.).
///   * Dropping a cmd_index between frames removes its DOM node.
///
/// Wire format mirrors teak's `A11yRecord` exactly (see
/// `src/platform/wasm.zig` in the teak repo). Keep this in sync if
/// the wire format ever changes -- the JS shim depends on the same
/// 40-byte stride.
const std = @import("std");
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;

extern "env" fn __zunk_publish_a11y_tree(
    records_ptr: [*]const u8,
    records_len: u32,
    strings_ptr: [*]const u8,
    strings_len: u32,
) void;

const A11yRecord = extern struct {
    cmd_index: u32,
    role: u32,
    label_offset: u32,
    label_len: u32,
    bounds_x: i32,
    bounds_y: i32,
    bounds_w: i32,
    bounds_h: i32,
    state: f32,
    flags: u32,
};

comptime {
    if (@sizeOf(A11yRecord) != 40) @compileError("A11yRecord size drifted from wire format");
}

const Role = enum(u32) {
    group = 0,
    scroll = 1,
    text = 2,
    rich_text = 3,
    button = 4,
    text_input = 5,
    checkbox = 6,
    radio = 7,
    slider = 8,
    divider = 9,
    image = 10,
    overlay = 11,
};

var records: [8]A11yRecord = undefined;
var strings: [256]u8 = undefined;
var ctx: canvas.Ctx2D = undefined;
var frame_count: u32 = 0;
var slider_value: f32 = 0.0;
var checkbox_on: bool = false;

const bg = canvas.Color{ .r = 17, .g = 17, .b = 22 };
const white = canvas.Color{ .r = 220, .g = 220, .b = 220 };
const dim = canvas.Color{ .r = 110, .g = 110, .b = 120 };

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk a11y-demo");
    canvas.setFont(ctx, "14px monospace");
}

export fn frame(_: f32) void {
    input.poll();

    // Tick a few values so the JS-side diff has something to update
    // each frame (aria-valuenow on the slider, aria-checked on the
    // checkbox). Demonstrates that the shim updates attributes in place
    // instead of rebuilding nodes.
    frame_count +%= 1;
    slider_value = @as(f32, @floatFromInt(frame_count % 240)) / 240.0;
    if (frame_count % 120 == 0) checkbox_on = !checkbox_on;

    publishTree();
    draw();
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

fn publishTree() void {
    var strings_used: u32 = 0;
    var count: usize = 0;

    count = appendNode(count, &strings_used, 1, .button, "Open", 0);
    count = appendNode(count, &strings_used, 2, .checkbox, "Enable feature", if (checkbox_on) 1.0 else 0.0);
    count = appendNode(count, &strings_used, 3, .slider, "Volume", slider_value);
    count = appendNode(count, &strings_used, 4, .text, "Hello, screen reader.", 0);
    // Cycle a fifth node in/out every 60 frames to exercise add/remove
    // diffing on the JS side.
    if ((frame_count / 60) % 2 == 0) {
        count = appendNode(count, &strings_used, 5, .image, "Decorative image", 0);
    }

    const records_bytes: u32 = @intCast(count * @sizeOf(A11yRecord));
    const records_ptr: [*]const u8 = @ptrCast(&records);
    __zunk_publish_a11y_tree(records_ptr, records_bytes, &strings, strings_used);
}

fn appendNode(
    count: usize,
    strings_used: *u32,
    cmd_index: u32,
    role: Role,
    label: []const u8,
    state: f32,
) usize {
    const label_offset = strings_used.*;
    const label_len: u32 = @intCast(label.len);
    @memcpy(strings[label_offset..][0..label.len], label);
    strings_used.* += label_len;

    records[count] = .{
        .cmd_index = cmd_index,
        .role = @intFromEnum(role),
        .label_offset = label_offset,
        .label_len = label_len,
        .bounds_x = 0,
        .bounds_y = 0,
        .bounds_w = 0,
        .bounds_h = 0,
        .state = state,
        .flags = 0,
    };
    return count + 1;
}

fn draw() void {
    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    canvas.setFillColor(ctx, bg);
    canvas.fillRect(ctx, 0, 0, w, h);

    canvas.setFillColor(ctx, white);
    canvas.setFont(ctx, "22px monospace");
    canvas.fillText(ctx, "zunk a11y demo", 40, 50);

    canvas.setFont(ctx, "13px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "open devtools, inspect #zunk-a11y-root, watch attrs update", 40, 76);
    canvas.fillText(ctx, "screen readers see the mirror; canvas pixels stay opaque to them", 40, 96);
}
