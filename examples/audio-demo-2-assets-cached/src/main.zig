const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const audio = zunk.web.audio;
const asset = zunk.web.asset;
const app = zunk.web.app;

const math = @import("std").math;

const tau = math.pi * 2.0;

var ctx: canvas.Ctx2D = undefined;
var explode_asset: asset.Handle = undefined;
var sfx_buffer: audio.AudioBuffer = undefined;
var sfx_ready: bool = false;
var asset_decoded: bool = false;
var audio_started: bool = false;
var volume: f32 = 0.8;

// Click state (detect edges, not held)
var prev_mouse_left: bool = false;

// Visual feedback for each click-to-play
const max_rings = 8;
var rings: [max_rings]Ring = [_]Ring{.{}} ** max_rings;
var next_ring: usize = 0;

const Ring = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    radius: f32 = 0,
    alpha: f32 = 0,
};

const bg = canvas.Color{ .r = 12, .g = 12, .b = 18 };
const white = canvas.Color{ .r = 220, .g = 220, .b = 220 };
const dim = canvas.Color{ .r = 60, .g = 60, .b = 60 };
const accent = canvas.Color{ .r = 255, .g = 120, .b = 50 };
const ready_color = canvas.Color{ .r = 80, .g = 200, .b = 120 };

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk audio demo (cached assets)");

    _ = audio.init(44100);
    explode_asset = asset.fetch("assets/explode.ogg");
    audio.setMasterVolume(volume);
}

export fn frame(dt: f32) void {
    input.poll();

    if (!sfx_ready) {
        if (!asset_decoded) {
            if (asset.isReady(explode_asset)) {
                sfx_buffer = audio.decodeAsset(explode_asset);
                asset_decoded = true;
            }
        } else {
            sfx_ready = audio.isReady(sfx_buffer);
        }
    }

    const mouse = input.getMouse();
    const just_clicked = mouse.buttons.left and !prev_mouse_left;
    prev_mouse_left = mouse.buttons.left;

    // First interaction resumes the AudioContext (browser autoplay policy).
    if (just_clicked and !audio_started) {
        audio.@"resume"();
        audio_started = true;
    }

    // Play sound on click (if decoded) or on spacebar.
    if ((just_clicked or input.isKeyPressed(.space)) and audio_started and sfx_ready) {
        audio.play(sfx_buffer);
        spawnRing(mouse.x, mouse.y);
    }

    // Volume control with up/down arrows.
    if (input.isKeyPressed(.arrow_up)) {
        volume = @min(1.0, volume + 0.1);
        audio.setMasterVolume(volume);
    }
    if (input.isKeyPressed(.arrow_down)) {
        volume = @max(0.0, volume - 0.1);
        audio.setMasterVolume(volume);
    }

    // -- Draw --
    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    canvas.setFillColor(ctx, bg);
    canvas.fillRect(ctx, 0, 0, w, h);

    // Title
    canvas.setFillColor(ctx, white);
    canvas.setFont(ctx, "20px monospace");
    canvas.fillText(ctx, "zunk audio demo (cached)", 20, 40);
    canvas.setFont(ctx, "14px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "fetch() + Web Audio. no js. no html.", 20, 62);

    // Status indicators
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, "STATUS", 20, 100);

    drawIndicator(20, 120, "context started", audio_started);
    drawIndicator(20, 142, "sfx decoded", sfx_ready);

    // Volume bar
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, "VOLUME", 20, 185);
    canvas.setFillColor(ctx, dim);
    canvas.fillRect(ctx, 20, 195, 200, 12);
    canvas.setFillColor(ctx, accent);
    canvas.fillRect(ctx, 20, 195, 200 * volume, 12);
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "arrow up/down to adjust", 20, 225);

    // Instructions
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, "HOW TO USE", 20, 265);
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "click or press space to play sound", 20, 285);
    canvas.fillText(ctx, "asset: explode.ogg (41KB, fetched from URL)", 20, 305);

    // Expanding rings
    for (&rings) |*ring| {
        if (!ring.active) continue;
        ring.radius += dt * 200;
        ring.alpha -= dt * 2.5;
        if (ring.alpha <= 0) {
            ring.active = false;
            continue;
        }
        canvas.setStrokeColor(ctx, .{
            .r = accent.r,
            .g = accent.g,
            .b = accent.b,
            .a = @intFromFloat(@max(0, ring.alpha) * 255),
        });
        canvas.setLineWidth(ctx, 2);
        canvas.beginPath(ctx);
        canvas.arc(ctx, ring.x, ring.y, ring.radius, 0, tau);
        canvas.stroke(ctx);
    }
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

fn spawnRing(x: f32, y: f32) void {
    rings[next_ring] = .{ .active = true, .x = x, .y = y, .radius = 0, .alpha = 1.0 };
    next_ring = (next_ring + 1) % max_rings;
}

fn drawIndicator(x: f32, y: f32, label: []const u8, active: bool) void {
    canvas.setFillColor(ctx, if (active) ready_color else dim);
    canvas.fillRect(ctx, x, y, 12, 12);
    canvas.setFillColor(ctx, white);
    canvas.fillText(ctx, label, x + 20, y + 10);
}
