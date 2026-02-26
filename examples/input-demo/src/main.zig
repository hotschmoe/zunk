const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;

const math = @import("std").math;

var ctx: canvas.Ctx2D = undefined;

// Colors
const bg = canvas.Color{ .r = 17, .g = 17, .b = 17 };
const white = canvas.Color{ .r = 220, .g = 220, .b = 220 };
const dim = canvas.Color{ .r = 60, .g = 60, .b = 60 };
const green = canvas.Color{ .r = 80, .g = 200, .b = 120 };
const red = canvas.Color{ .r = 220, .g = 60, .b = 60 };
const blue = canvas.Color{ .r = 60, .g = 120, .b = 220 };
const yellow = canvas.Color{ .r = 220, .g = 200, .b = 60 };

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk input demo");
    canvas.setFont(ctx, "14px monospace");
}

export fn frame(_: f32) void {
    input.poll();

    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    // Clear
    canvas.setFillColor(ctx, bg);
    canvas.fillRect(ctx, 0, 0, w, h);

    // Title
    canvas.setFillColor(ctx, white);
    canvas.setFont(ctx, "20px monospace");
    canvas.fillText(ctx, "zunk input demo", 20, 40);
    canvas.setFont(ctx, "14px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "no js. no html. just zig.", 20, 62);

    // -- Mouse section --
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, "MOUSE", 20, 100);

    const mouse = input.getMouse();

    // Mouse position crosshair
    canvas.setStrokeColor(ctx, .{ .r = 100, .g = 100, .b = 100, .a = 120 });
    canvas.setLineWidth(ctx, 1);
    canvas.beginPath(ctx);
    canvas.moveTo(ctx, mouse.x, 0);
    canvas.lineTo(ctx, mouse.x, h);
    canvas.stroke(ctx);
    canvas.beginPath(ctx);
    canvas.moveTo(ctx, 0, mouse.y);
    canvas.lineTo(ctx, w, mouse.y);
    canvas.stroke(ctx);

    // Mouse cursor circle
    canvas.setStrokeColor(ctx, green);
    canvas.setLineWidth(ctx, 2);
    canvas.beginPath(ctx);
    canvas.arc(ctx, mouse.x, mouse.y, 16, 0, math.pi * 2.0);
    canvas.stroke(ctx);

    // Mouse button indicators
    drawButton(ctx, 20, 115, "L", mouse.buttons.left);
    drawButton(ctx, 60, 115, "M", mouse.buttons.middle);
    drawButton(ctx, 100, 115, "R", mouse.buttons.right);

    // Mouse coords text
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "pos / wheel", 150, 130);

    // -- Keyboard section --
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, "KEYBOARD", 20, 180);

    // WASD cluster
    drawKey(ctx, 60, 195, "W", input.isKeyDown(.w));
    drawKey(ctx, 20, 235, "A", input.isKeyDown(.a));
    drawKey(ctx, 60, 235, "S", input.isKeyDown(.s));
    drawKey(ctx, 100, 235, "D", input.isKeyDown(.d));

    // Arrow keys
    drawKey(ctx, 200, 195, "^", input.isKeyDown(.arrow_up));
    drawKey(ctx, 160, 235, "<", input.isKeyDown(.arrow_left));
    drawKey(ctx, 200, 235, "v", input.isKeyDown(.arrow_down));
    drawKey(ctx, 240, 235, ">", input.isKeyDown(.arrow_right));

    // Special keys
    drawWideKey(ctx, 20, 280, "SPACE", 120, input.isKeyDown(.space));
    drawKey(ctx, 160, 280, "Sh", input.isKeyDown(.shift));
    drawKey(ctx, 200, 280, "Ct", input.isKeyDown(.ctrl));
    drawKey(ctx, 240, 280, "Es", input.isKeyDown(.escape));

    // Number row
    const num_keys = [_]input.Key{ .key_1, .key_2, .key_3, .key_4, .key_5, .key_6, .key_7, .key_8, .key_9, .key_0 };
    const num_labels = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" };
    for (num_keys, num_labels, 0..) |key, label, i| {
        drawKey(ctx, 20 + @as(f32, @floatFromInt(i)) * 40, 325, label, input.isKeyDown(key));
    }
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

fn drawKey(c: canvas.Ctx2D, x: f32, y: f32, label: []const u8, active: bool) void {
    const color = if (active) green else dim;
    canvas.setFillColor(c, color);
    canvas.fillRect(c, x, y, 32, 32);
    const text_color = if (active) bg else white;
    canvas.setFillColor(c, text_color);
    canvas.fillText(c, label, x + 10, y + 21);
}

fn drawWideKey(c: canvas.Ctx2D, x: f32, y: f32, label: []const u8, w_key: f32, active: bool) void {
    const color = if (active) green else dim;
    canvas.setFillColor(c, color);
    canvas.fillRect(c, x, y, w_key, 32);
    const text_color = if (active) bg else white;
    canvas.setFillColor(c, text_color);
    canvas.fillText(c, label, x + w_key / 2 - 20, y + 21);
}

fn drawButton(c: canvas.Ctx2D, x: f32, y: f32, label: []const u8, active: bool) void {
    const color = if (active) red else dim;
    canvas.setFillColor(c, color);
    canvas.beginPath(c);
    canvas.arc(c, x + 14, y + 14, 14, 0, math.pi * 2.0);
    canvas.fill(c);
    const text_color = if (active) white else canvas.Color{ .r = 140, .g = 140, .b = 140 };
    canvas.setFillColor(c, text_color);
    canvas.fillText(c, label, x + 8, y + 19);
}
