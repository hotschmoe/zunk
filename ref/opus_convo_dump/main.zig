/// Example: A simple game loop written entirely in Zig.
/// The developer writes ZERO JavaScript and ZERO HTML.
/// zunk generates everything needed to run this in a browser.
///
/// Build & run:   zunk run
/// Deploy:        zunk deploy
///
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;

// ============================================================================
// Game state — all in Zig, no JS anywhere
// ============================================================================

const Ball = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    radius: f32,
    color: canvas.Color,
};

var ctx: canvas.Ctx2D = undefined;
var width: f32 = 800;
var height: f32 = 600;
var balls: [50]Ball = undefined;
var ball_count: usize = 0;
var frame_count: u64 = 0;

// ============================================================================
// Exported lifecycle — zunk's JS calls these
// ============================================================================

/// Called once after WASM is loaded and WebGPU/Canvas is ready.
export fn init() void {
    app.setTitle("Bouncing Balls — Pure Zig");
    input.init();
    ctx = canvas.getContext2D("app");

    // Spawn some balls
    var seed: u32 = 42;
    for (&balls, 0..) |*ball, i| {
        if (i >= 20) break;
        seed = lcg(seed);
        ball.* = .{
            .x = @as(f32, @floatFromInt(seed % 700)) + 50,
            .y = @as(f32, @floatFromInt(lcg(seed) % 500)) + 50,
            .vx = @as(f32, @floatFromInt(seed % 200)) - 100,
            .vy = @as(f32, @floatFromInt(lcg(seed) % 200)) - 100,
            .radius = @as(f32, @floatFromInt(seed % 20)) + 5,
            .color = .{
                .r = @intCast(seed % 200 + 55),
                .g = @intCast(lcg(seed) % 200 + 55),
                .b = @intCast(lcg(lcg(seed)) % 200 + 55),
            },
        };
        seed = lcg(seed);
        ball_count += 1;
    }

    app.logInfo("init complete: bouncing balls demo");
}

/// Called every requestAnimationFrame. dt = seconds since last frame.
export fn frame(dt: f32) void {
    input.poll();
    frame_count += 1;

    // Spawn ball on click
    const mouse = input.getMouse();
    if (mouse.buttons.left and ball_count < balls.len) {
        balls[ball_count] = .{
            .x = mouse.x,
            .y = mouse.y,
            .vx = mouse.dx * 5,
            .vy = mouse.dy * 5,
            .radius = 10,
            .color = .{
                .r = @intCast(frame_count % 200 + 55),
                .g = @intCast((frame_count * 7) % 200 + 55),
                .b = @intCast((frame_count * 13) % 200 + 55),
            },
        };
        ball_count += 1;
    }

    // Clear
    canvas.clearRect(ctx, 0, 0, width, height);

    // Update & draw balls
    for (balls[0..ball_count]) |*ball| {
        ball.x += ball.vx * dt;
        ball.y += ball.vy * dt;

        // Bounce off walls
        if (ball.x - ball.radius < 0) {
            ball.x = ball.radius;
            ball.vx = @abs(ball.vx);
        }
        if (ball.x + ball.radius > width) {
            ball.x = width - ball.radius;
            ball.vx = -@abs(ball.vx);
        }
        if (ball.y - ball.radius < 0) {
            ball.y = ball.radius;
            ball.vy = @abs(ball.vy);
        }
        if (ball.y + ball.radius > height) {
            ball.y = height - ball.radius;
            ball.vy = -@abs(ball.vy);
        }

        // Gravity
        ball.vy += 200 * dt;

        // Draw
        canvas.setFillColor(ctx, ball.color);
        canvas.beginPath(ctx);
        canvas.arc(ctx, ball.x, ball.y, ball.radius, 0, 6.28318);
        canvas.fill(ctx);
    }

    // Draw HUD
    canvas.setFillColor(ctx, .{ .r = 255, .g = 255, .b = 255 });
    canvas.setFont(ctx, "14px monospace");
    canvas.fillText(ctx, "click to spawn balls | ESC to clear", 10, 20);

    // ESC to clear
    if (input.isKeyPressed(.escape)) {
        ball_count = 0;
    }
}

/// Called when the window/canvas is resized.
export fn resize(w: u32, h: u32) void {
    width = @floatFromInt(w);
    height = @floatFromInt(h);
    canvas.setSize(canvas.getWebGPUSurface("app"), w, h);
}

// ============================================================================
// Utility
// ============================================================================

fn lcg(seed: u32) u32 {
    return seed *% 1664525 +% 1013904223;
}
