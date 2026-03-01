const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;
const imgui = zunk.web.imgui;

var ctx: canvas.Ctx2D = undefined;
var ui: imgui.CanvasUi = undefined;

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

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk imgui demo");

    const backend = imgui.Canvas2DBackend.init(ctx);
    ui = imgui.CanvasUi.init(backend);
}

export fn frame(_: f32) void {
    input.poll();

    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    canvas.setFillColor(ctx, .{ .r = 20, .g = 20, .b = 25 });
    canvas.fillRect(ctx, 0, 0, w, h);

    ui.begin(w);

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
