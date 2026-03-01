const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const asset = zunk.web.asset;
const app = zunk.web.app;

const simulation = @import("simulation.zig");

const PARTICLE_COUNT: u32 = 65536;
const SPECIES_COUNT: u32 = 6;
const SIM_WIDTH: f32 = 1024.0;
const SIM_HEIGHT: f32 = 1024.0;
const SEED: u32 = 42;

var sim: ?simulation.Simulation = null;
var sim_initialized: bool = false;

var pending_resize: ?struct { w: u32, h: u32 } = null;

var noise_asset: asset.Handle = undefined;
var noise_texture: gpu.Texture = undefined;
var noise_ready: bool = false;
var noise_fetched: bool = false;

export fn init() void {
    input.init();
    app.setTitle("Particle Life - zunk");

    noise_asset = asset.fetch("assets/blue-noise.png");
    noise_fetched = false;
    noise_ready = false;
}

export fn frame(dt: f32) void {
    input.poll();

    if (!sim_initialized) {
        sim = simulation.Simulation.init(
            PARTICLE_COUNT,
            SPECIES_COUNT,
            SIM_WIDTH,
            SIM_HEIGHT,
            SEED,
        ) catch return;
        sim_initialized = true;
        if (pending_resize) |pr| {
            sim.?.updateCamera(pr.w, pr.h);
            pending_resize = null;
        }
    }

    if (!noise_ready) {
        if (!noise_fetched and asset.isReady(noise_asset)) {
            noise_texture = gpu.createTextureFromAsset(noise_asset);
            noise_fetched = true;
        }
        if (noise_fetched and gpu.isTextureReady(noise_texture)) {
            const view = gpu.createTextureView(noise_texture);
            if (sim) |*s| {
                s.setBlueNoiseTexture(view);
            }
            noise_ready = true;
        }
    }

    if (sim) |*s| {
        s.handleInput();
        s.update(dt);
        s.render();
    }
}

export fn resize(w: u32, h: u32) void {
    if (sim) |*s| {
        s.updateCamera(w, h);
    } else {
        pending_resize = .{ .w = w, .h = h };
    }
}
