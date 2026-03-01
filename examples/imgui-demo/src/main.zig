const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;
const imgui = zunk.web.imgui;

const math = @import("std").math;
const tau = math.pi * 2.0;

var ctx: canvas.Ctx2D = undefined;
var ui: imgui.CanvasUi = undefined;

const panel_width: f32 = 320;

const defaults = .{
    .brightness = @as(f32, 0.75),
    .fullscreen = false,
    .vsync = true,
    .volume = @as(f32, 0.5),
    .mute = false,
    .sensitivity = @as(f32, 1.0),
    .invert_y = false,
};

var brightness: f32 = defaults.brightness;
var fullscreen: bool = defaults.fullscreen;
var vsync: bool = defaults.vsync;
var volume: f32 = defaults.volume;
var mute: bool = defaults.mute;
var sensitivity: f32 = defaults.sensitivity;
var invert_y: bool = defaults.invert_y;
var apply_count: u32 = 0;

// Tracker dot -- smoothly follows mouse, affected by sensitivity + invert-Y
var tracker_x: f32 = 200;
var tracker_y: f32 = 200;

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk imgui demo");

    const backend = imgui.Canvas2DBackend.init(ctx);
    ui = imgui.CanvasUi.init(backend);
}

export fn frame(dt: f32) void {
    input.poll();

    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    // Background brightness: map 0..1 to dark (5) .. light (60)
    const bg_val: u8 = @intFromFloat(5.0 + brightness * 55.0);
    canvas.setFillColor(ctx, .{ .r = bg_val, .g = bg_val, .b = bg_val + 5 });
    canvas.fillRect(ctx, 0, 0, w, h);

    drawPreview(dt, w, h);
    drawUI(w);
}

fn drawUI(w: f32) void {
    const ui_width = @min(panel_width, w);
    ui.begin(ui_width);

    ui.label("zunk imgui demo");

    ui.beginPanel("Display Settings");
    _ = ui.slider("Brightness", &brightness, 0.0, 1.0);
    _ = ui.checkbox("Fullscreen", &fullscreen);
    _ = ui.checkbox("VSync", &vsync);
    ui.separator();
    ui.endPanel();

    ui.beginPanel("Audio Settings");
    _ = ui.slider("Volume", &volume, 0.0, 1.0);
    _ = ui.checkbox("Mute", &mute);
    ui.separator();
    ui.endPanel();

    ui.beginPanel("Controls");
    _ = ui.slider("Sensitivity", &sensitivity, 0.1, 5.0);
    _ = ui.checkbox("Invert Y-Axis", &invert_y);
    ui.separator();
    ui.endPanel();

    ui.label(statusLine());

    ui.beginHorizontal();
    if (ui.button("Apply##apply")) apply_count += 1;
    if (ui.button("Reset##reset")) resetSettings();
    ui.endHorizontal();

    ui.end();
}

fn drawPreview(dt: f32, w: f32, h: f32) void {
    const preview_x = panel_width + 20;
    if (w < preview_x + 100) return;

    const preview_w = w - preview_x - 20;
    const preview_h = h - 40;
    const preview_y: f32 = 20;

    // Preview border
    canvas.setStrokeColor(ctx, .{ .r = 80, .g = 80, .b = 80 });
    canvas.setLineWidth(ctx, 1);
    canvas.strokeRect(ctx, preview_x, preview_y, preview_w, preview_h);

    // Preview label
    canvas.setFont(ctx, "13px monospace");
    canvas.setFillColor(ctx, .{ .r = 100, .g = 100, .b = 100 });
    canvas.fillText(ctx, "LIVE PREVIEW", preview_x + 8, preview_y + 14);

    // Brightness gradient bar
    drawBrightnessBar(preview_x + 8, preview_y + 36, preview_w - 16);

    // Volume meter
    drawVolumeMeter(preview_x + 8, preview_y + 70, preview_w - 16);

    // Tracker dot (follows mouse with sensitivity, invert-Y)
    updateTracker(dt, preview_x, preview_y, preview_w, preview_h);
    drawTracker(preview_x, preview_y, preview_w, preview_h);

    // Settings readout
    drawSettingsReadout(preview_x + 8, preview_y + preview_h - 80);
}

fn drawBrightnessBar(x: f32, y: f32, w: f32) void {
    const bar_h: f32 = 20;

    // Track
    canvas.setFillColor(ctx, .{ .r = 30, .g = 30, .b = 30 });
    canvas.fillRect(ctx, x, y, w, bar_h);

    // Fill based on brightness
    const fill_w = w * brightness;
    const bright_r: u8 = @intFromFloat(brightness * 255.0);
    const bright_g: u8 = @intFromFloat(brightness * 220.0);
    const bright_b: u8 = @intFromFloat(60.0 + brightness * 140.0);
    canvas.setFillColor(ctx, .{ .r = bright_r, .g = bright_g, .b = bright_b });
    canvas.fillRect(ctx, x, y, fill_w, bar_h);

    canvas.setFont(ctx, "11px monospace");
    canvas.setFillColor(ctx, .{ .r = 200, .g = 200, .b = 200 });
    canvas.fillText(ctx, "BRIGHTNESS", x + 4, y + 5);
}

fn drawVolumeMeter(x: f32, y: f32, w: f32) void {
    const bar_h: f32 = 20;
    const effective_vol = if (mute) @as(f32, 0) else volume;

    // Track
    canvas.setFillColor(ctx, .{ .r = 30, .g = 30, .b = 30 });
    canvas.fillRect(ctx, x, y, w, bar_h);

    // Fill
    const fill_w = w * effective_vol;
    if (mute) {
        canvas.setFillColor(ctx, .{ .r = 80, .g = 40, .b = 40 });
    } else {
        const vol_g: u8 = @intFromFloat(100.0 + effective_vol * 155.0);
        canvas.setFillColor(ctx, .{ .r = 40, .g = vol_g, .b = 60 });
    }
    canvas.fillRect(ctx, x, y, fill_w, bar_h);

    canvas.setFont(ctx, "11px monospace");
    canvas.setFillColor(ctx, .{ .r = 200, .g = 200, .b = 200 });
    if (mute) {
        canvas.fillText(ctx, "VOLUME (MUTED)", x + 4, y + 5);
    } else {
        canvas.fillText(ctx, "VOLUME", x + 4, y + 5);
    }
}

fn updateTracker(dt: f32, px: f32, py: f32, pw: f32, ph: f32) void {
    const mouse = input.getMouse();

    // Target is mouse position clamped to preview area
    const target_x = clampf(mouse.x, px, px + pw);
    const raw_y = mouse.y;
    const target_y = if (invert_y) py + ph - (raw_y - py) else raw_y;
    const clamped_y = clampf(target_y, py, py + ph);

    // Lerp toward target; sensitivity scales the speed
    const speed = sensitivity * 8.0;
    const t = clampf(speed * dt, 0, 1);
    tracker_x += (target_x - tracker_x) * t;
    tracker_y += (clamped_y - tracker_y) * t;
}

fn drawTracker(px: f32, py: f32, pw: f32, ph: f32) void {
    // Crosshair lines
    canvas.setStrokeColor(ctx, .{ .r = 60, .g = 60, .b = 80, .a = 120 });
    canvas.setLineWidth(ctx, 1);
    canvas.beginPath(ctx);
    canvas.moveTo(ctx, tracker_x, py);
    canvas.lineTo(ctx, tracker_x, py + ph);
    canvas.stroke(ctx);
    canvas.beginPath(ctx);
    canvas.moveTo(ctx, px, tracker_y);
    canvas.lineTo(ctx, px + pw, tracker_y);
    canvas.stroke(ctx);

    // Outer ring
    canvas.setStrokeColor(ctx, .{ .r = 70, .g = 130, .b = 230 });
    canvas.setLineWidth(ctx, 2);
    canvas.beginPath(ctx);
    canvas.arc(ctx, tracker_x, tracker_y, 14, 0, tau);
    canvas.stroke(ctx);

    // Inner dot
    canvas.setFillColor(ctx, .{ .r = 100, .g = 160, .b = 255 });
    canvas.beginPath(ctx);
    canvas.arc(ctx, tracker_x, tracker_y, 4, 0, tau);
    canvas.fill(ctx);

    // Label
    canvas.setFont(ctx, "11px monospace");
    canvas.setFillColor(ctx, .{ .r = 100, .g = 100, .b = 100 });
    canvas.fillText(ctx, "move mouse here", tracker_x + 20, tracker_y - 6);
}

fn drawSettingsReadout(x: f32, y: f32) void {
    canvas.setFont(ctx, "12px monospace");
    canvas.setFillColor(ctx, .{ .r = 120, .g = 120, .b = 120 });

    canvas.fillText(ctx, "-- active settings --", x, y);

    var line_y = y + 18;
    const spacing: f32 = 16;

    if (fullscreen) {
        canvas.fillText(ctx, "[x] fullscreen", x, line_y);
    } else {
        canvas.fillText(ctx, "[ ] fullscreen", x, line_y);
    }
    line_y += spacing;

    if (vsync) {
        canvas.fillText(ctx, "[x] vsync", x, line_y);
    } else {
        canvas.fillText(ctx, "[ ] vsync", x, line_y);
    }
    line_y += spacing;

    if (invert_y) {
        canvas.fillText(ctx, "[x] invert-Y", x, line_y);
    } else {
        canvas.fillText(ctx, "[ ] invert-Y  (try it -- watch the dot)", x, line_y);
    }
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

fn resetSettings() void {
    brightness = defaults.brightness;
    fullscreen = defaults.fullscreen;
    vsync = defaults.vsync;
    volume = defaults.volume;
    mute = defaults.mute;
    sensitivity = defaults.sensitivity;
    invert_y = defaults.invert_y;
    apply_count = 0;
}

fn clampf(val: f32, lo: f32, hi: f32) f32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

var status_buf: [64]u8 = undefined;

fn statusLine() []const u8 {
    const prefix = "Applied: ";
    const suffix = " time(s)";
    @memcpy(status_buf[0..prefix.len], prefix);
    const digits_end = prefix.len + writeU32(status_buf[prefix.len..], apply_count);
    @memcpy(status_buf[digits_end .. digits_end + suffix.len], suffix);
    return status_buf[0 .. digits_end + suffix.len];
}

fn writeU32(buf: []u8, value: u32) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var n = value;
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    while (n > 0) : (len += 1) {
        tmp[len] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        buf[len - 1 - i] = tmp[i];
    }
    return len;
}
