const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const asset = zunk.web.asset;
const app = zunk.web.app;
const ui = zunk.web.ui;

const simulation = @import("simulation.zig");

const SEED: u32 = 42;

var sim: ?simulation.Simulation = null;
var sim_initialized: bool = false;
var paused: bool = false;

var pending_resize: ?struct { w: u32, h: u32 } = null;
var last_canvas_w: u32 = 0;
var last_canvas_h: u32 = 0;

var noise_asset: asset.Handle = undefined;
var noise_texture: gpu.Texture = undefined;
var noise_ready: bool = false;
var noise_fetched: bool = false;

var panel: ui.Panel = undefined;
var sl_particle_pow: ui.Element = undefined;
var sl_species: ui.Element = undefined;
var sl_sim_width: ui.Element = undefined;
var sl_sim_height: ui.Element = undefined;
var sl_friction: ui.Element = undefined;
var sl_central_force: ui.Element = undefined;
var cb_symmetric: ui.Element = undefined;
var cb_looping: ui.Element = undefined;
var btn_pause: ui.Element = undefined;
var btn_center: ui.Element = undefined;
var btn_restart: ui.Element = undefined;
var btn_randomize: ui.Element = undefined;
var btn_fullscreen: ui.Element = undefined;

var prev_particle_pow: f32 = 16.0;
var prev_species: f32 = 6.0;
var prev_sim_w: f32 = 16.0;
var prev_sim_h: f32 = 16.0;

export fn init() void {
    input.init();
    app.setTitle("Particle Life - zunk");

    noise_asset = asset.fetch("assets/blue-noise.png");

    // Build UI panel
    panel = ui.createPanel("Settings");

    sl_particle_pow = ui.addSlider(panel, "Particles (2^n)", 10, 20, 16, 1);
    sl_species = ui.addSlider(panel, "Species", 1, 16, 6, 1);
    sl_sim_width = ui.addSlider(panel, "Sim Width (*64)", 1, 50, 16, 1);
    sl_sim_height = ui.addSlider(panel, "Sim Height (*64)", 1, 50, 16, 1);

    _ = ui.addSeparator(panel);

    sl_friction = ui.addSlider(panel, "Friction", 0, 100, 10, 1);
    sl_central_force = ui.addSlider(panel, "Central Force", 0, 100, 0, 1);
    cb_symmetric = ui.addCheckbox(panel, "Symmetric Forces", false);
    cb_looping = ui.addCheckbox(panel, "Looping Borders", false);

    _ = ui.addSeparator(panel);

    btn_pause = ui.addButton(panel, "Pause");
    btn_center = ui.addButton(panel, "Center View");
    btn_restart = ui.addButton(panel, "Restart");
    btn_randomize = ui.addButton(panel, "Randomize");
    btn_fullscreen = ui.addButton(panel, "Fullscreen");
}

fn currentParticleCount() u32 {
    const pow: u5 = @intFromFloat(prev_particle_pow);
    return @as(u32, 1) << pow;
}

fn currentSimWidth() f32 {
    return prev_sim_w * 64.0;
}

fn currentSimHeight() f32 {
    return prev_sim_h * 64.0;
}

fn initSim() void {
    sim = simulation.Simulation.init(
        currentParticleCount(),
        @intFromFloat(prev_species),
        currentSimWidth(),
        currentSimHeight(),
        SEED,
    ) catch return;
    sim_initialized = true;
    if (pending_resize) |pr| {
        last_canvas_w = pr.w;
        last_canvas_h = pr.h;
        pending_resize = null;
    }
    if (last_canvas_w > 0 and last_canvas_h > 0) {
        sim.?.updateCamera(last_canvas_w, last_canvas_h);
    }
}

fn reinitSim() void {
    if (sim) |*s| s.deinit();
    sim = null;
    sim_initialized = false;
    noise_ready = false;
    noise_fetched = false;
    noise_asset = asset.fetch("assets/blue-noise.png");
    initSim();
}

export fn frame(dt: f32) void {
    input.poll();

    if (!sim_initialized) {
        initSim();
    }

    // Load blue noise texture
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

    // Read heavy sliders -- reinit on change
    const new_pp = ui.getFloat(sl_particle_pow);
    const new_sp = ui.getFloat(sl_species);
    const new_sw = ui.getFloat(sl_sim_width);
    const new_sh = ui.getFloat(sl_sim_height);

    if (new_pp != prev_particle_pow or new_sp != prev_species or new_sw != prev_sim_w or new_sh != prev_sim_h) {
        prev_particle_pow = new_pp;
        prev_species = new_sp;
        prev_sim_w = new_sw;
        prev_sim_h = new_sh;
        reinitSim();
    }

    // Read lightweight controls
    if (sim) |*s| {
        s.friction_coefficient = ui.getFloat(sl_friction);
        s.options.central_force = ui.getFloat(sl_central_force) / 10.0;
        s.symmetric_forces = ui.getBool(cb_symmetric);
        s.options.looping_borders = if (ui.getBool(cb_looping)) 1.0 else 0.0;
    }

    if (ui.isClicked(btn_pause)) paused = !paused;
    if (ui.isClicked(btn_fullscreen)) ui.requestFullscreen();

    if (sim) |*s| {
        if (ui.isClicked(btn_center)) s.centerView();
        if (ui.isClicked(btn_restart)) s.restart();
        if (ui.isClicked(btn_randomize)) s.randomize();
    }

    // Keyboard shortcuts
    if (input.isKeyPressed(.space)) paused = !paused;
    if (input.isKeyPressed(.s)) ui.togglePanel(panel);

    // Simulation tick
    if (sim) |*s| {
        s.handleInput();
        s.update(if (paused) 0.0 else dt);
        s.render();
    }
}

export fn resize(w: u32, h: u32) void {
    last_canvas_w = w;
    last_canvas_h = h;
    if (sim) |*s| {
        s.updateCamera(w, h);
    } else {
        pending_resize = .{ .w = w, .h = h };
    }
}
