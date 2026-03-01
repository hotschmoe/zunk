const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;
const imgui = zunk.web.imgui;

var ctx: canvas.Ctx2D = undefined;
var ui: imgui.CanvasUi = undefined;

// Display settings
var brightness: f32 = 0.75;
var fullscreen: bool = false;
var vsync: bool = true;

// Audio settings
var volume: f32 = 0.5;
var mute: bool = false;

// Controls settings
var sensitivity: f32 = 1.0;
var invert_y: bool = false;

// Status
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

    // -- Display Settings --
    ui.beginPanel("Display Settings");
    _ = ui.slider("Brightness", &brightness, 0.0, 1.0);
    _ = ui.checkbox("Fullscreen", &fullscreen);
    _ = ui.checkbox("VSync", &vsync);
    ui.separator();
    ui.endPanel();

    // -- Audio Settings --
    ui.beginPanel("Audio Settings");
    _ = ui.slider("Volume", &volume, 0.0, 1.0);
    _ = ui.checkbox("Mute", &mute);
    ui.separator();
    ui.endPanel();

    // -- Controls --
    ui.beginPanel("Controls");
    _ = ui.slider("Sensitivity", &sensitivity, 0.1, 5.0);
    _ = ui.checkbox("Invert Y-Axis", &invert_y);
    ui.separator();
    ui.endPanel();

    // -- Status --
    ui.label(statusLine());

    // -- Action buttons --
    ui.beginHorizontal();
    if (ui.button("Apply##apply")) {
        apply_count += 1;
    }
    if (ui.button("Reset##reset")) {
        brightness = 0.75;
        fullscreen = false;
        vsync = true;
        volume = 0.5;
        mute = false;
        sensitivity = 1.0;
        invert_y = false;
        apply_count = 0;
    }
    ui.endHorizontal();

    ui.end();
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

var status_buf: [64]u8 = undefined;

fn statusLine() []const u8 {
    const prefix = "Applied: ";
    @memcpy(status_buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    var n = apply_count;
    if (n == 0) {
        status_buf[pos] = '0';
        pos += 1;
    } else {
        var digits: [10]u8 = undefined;
        var dlen: usize = 0;
        while (n > 0) {
            digits[dlen] = '0' + @as(u8, @intCast(n % 10));
            dlen += 1;
            n /= 10;
        }
        var i: usize = dlen;
        while (i > 0) {
            i -= 1;
            status_buf[pos] = digits[i];
            pos += 1;
        }
    }

    const suffix = " time(s)";
    @memcpy(status_buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    return status_buf[0..pos];
}
