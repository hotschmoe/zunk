const std = @import("std");
const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const app = zunk.web.app;

const particle = @import("particle.zig");
const system = @import("system.zig");
const shaders = @import("shaders.zig");
const spatial = @import("spatial.zig");

pub const BufferInfo = struct {
    handle: gpu.Buffer,
    size: u64,

    pub fn writeTyped(self: BufferInfo, comptime T: type, offset: u32, data: []const T) void {
        gpu.bufferWriteTyped(T, self.handle, offset, data);
    }

    pub fn destroy(self: BufferInfo) void {
        gpu.bufferDestroy(self.handle);
    }
};

pub fn createStorageBuffer(size: u64) BufferInfo {
    return .{
        .handle = gpu.createStorageBuffer(@intCast(size)),
        .size = size,
    };
}

pub fn createUniformBuffer(size: u64) BufferInfo {
    return .{
        .handle = gpu.createUniformBuffer(@intCast(size)),
        .size = size,
    };
}

pub const Simulation = struct {
    particle_count: u32,
    species_count: u32,
    sim_width: f32,
    sim_height: f32,

    particle_buffer: BufferInfo,
    species_buffer: BufferInfo,
    force_buffer: BufferInfo,
    options_buffer: BufferInfo,
    camera_buffer: BufferInfo,

    hdr_texture: gpu.Texture,
    hdr_texture_view: gpu.TextureView,
    blue_noise_texture_view: ?gpu.TextureView,
    canvas_width: u32,
    canvas_height: u32,

    glow_pipeline: gpu.RenderPipeline,
    circle_pipeline: gpu.RenderPipeline,
    point_pipeline: gpu.RenderPipeline,

    compose_pipeline: gpu.RenderPipeline,
    compose_bind_group_layout: gpu.BindGroupLayout,
    compose_bind_group: gpu.BindGroup,

    particle_bind_group: gpu.BindGroup,
    camera_bind_group: gpu.BindGroup,

    advance_pipeline: gpu.ComputePipeline,
    advance_particle_group: gpu.BindGroup,
    advance_options_group: gpu.BindGroup,

    spatial_pipeline: spatial.SpatialPipeline,
    max_force_radius: f32,

    rng: system.Rng,
    options: particle.SimulationOptions,
    camera: particle.CameraParams,
    symmetric_forces: bool,
    friction_coefficient: f32,

    pub fn init(
        particle_count: u32,
        species_count: u32,
        sim_width: f32,
        sim_height: f32,
        seed: u32,
    ) !Simulation {
        var sim = Simulation{
            .particle_count = particle_count,
            .species_count = species_count,
            .sim_width = sim_width,
            .sim_height = sim_height,
            .rng = system.Rng.init(seed),
            .options = particle.SimulationOptions.init(sim_width, sim_height, species_count),
            .camera = particle.CameraParams.initForSimulation(1024.0, 768.0, sim_width, sim_height),
            .symmetric_forces = false,
            .friction_coefficient = 10.0,
            .max_force_radius = 80.0,
            .particle_buffer = undefined,
            .species_buffer = undefined,
            .force_buffer = undefined,
            .options_buffer = undefined,
            .camera_buffer = undefined,
            .hdr_texture = undefined,
            .hdr_texture_view = undefined,
            .blue_noise_texture_view = null,
            .canvas_width = 1024,
            .canvas_height = 768,
            .glow_pipeline = undefined,
            .circle_pipeline = undefined,
            .point_pipeline = undefined,
            .compose_pipeline = undefined,
            .compose_bind_group_layout = undefined,
            .compose_bind_group = undefined,
            .particle_bind_group = undefined,
            .camera_bind_group = undefined,
            .advance_pipeline = undefined,
            .advance_particle_group = undefined,
            .advance_options_group = undefined,
            .spatial_pipeline = undefined,
        };

        sim.particle_buffer = createStorageBuffer(@sizeOf(particle.Particle) * particle_count);
        sim.species_buffer = createStorageBuffer(@sizeOf(particle.Species) * species_count);
        sim.force_buffer = createStorageBuffer(@sizeOf(particle.Force) * species_count * species_count);
        sim.options_buffer = createUniformBuffer(@sizeOf(particle.SimulationOptions));
        sim.camera_buffer = createUniformBuffer(@sizeOf(particle.CameraParams));

        sim.options.bin_size = sim.max_force_radius;

        try sim.setupInitAndGenerate();
        try sim.setupRenderPipeline();
        try sim.setupAdvancePipeline();

        sim.spatial_pipeline = try spatial.SpatialPipeline.init(
            sim.particle_buffer,
            sim.force_buffer,
            sim.options_buffer,
            sim_width,
            sim_height,
            sim.max_force_radius,
        );

        return sim;
    }

    fn setupInitAndGenerate(self: *Simulation) !void {
        const init_shader = gpu.createShaderModule(shaders.particle_init);
        const seed_buffer = createUniformBuffer(4);

        const layout_0 = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .storage),
        });
        const layout_1 = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .uniform),
        });
        const layout_2 = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .uniform),
        });

        const pipeline_layout = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ layout_0, layout_1, layout_2 });
        const init_pipeline = gpu.createComputePipeline(pipeline_layout, init_shader, "initParticles");

        const bg_particles = gpu.createBindGroup(layout_0, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.particle_buffer.handle, self.particle_buffer.size),
        });
        const bg_options = gpu.createBindGroup(layout_1, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.options_buffer.handle, self.options_buffer.size),
        });
        const bg_seed = gpu.createBindGroup(layout_2, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, seed_buffer.handle, seed_buffer.size),
        });

        self.options_buffer.writeTyped(particle.SimulationOptions, 0, &[_]particle.SimulationOptions{self.options});

        const seed_val = @as(u32, @intFromFloat(self.rng.next() * 4294967296.0));
        seed_buffer.writeTyped(u32, 0, &[_]u32{seed_val});

        const encoder = gpu.createCommandEncoder();
        const pass = gpu.beginComputePass(encoder);
        gpu.computePassSetPipeline(pass, init_pipeline);
        gpu.computePassSetBindGroup(pass, 0, bg_particles);
        gpu.computePassSetBindGroup(pass, 1, bg_options);
        gpu.computePassSetBindGroup(pass, 2, bg_seed);
        gpu.computePassDispatch(pass, (self.particle_count + 63) / 64, 1, 1);
        gpu.computePassEnd(pass);
        gpu.queueSubmit(gpu.encoderFinish(encoder));

        const MAX_SPECIES = 16;
        const actual = @min(self.species_count, MAX_SPECIES);

        var species: [MAX_SPECIES]particle.Species = undefined;
        var forces: [MAX_SPECIES * MAX_SPECIES]particle.Force = undefined;

        system.generateSpeciesColors(species[0..actual], &self.rng);
        const force_count = @as(usize, actual) * @as(usize, actual);
        system.generateForceMatrix(forces[0..force_count], actual, &self.rng, self.symmetric_forces);

        self.species_buffer.writeTyped(particle.Species, 0, species[0..actual]);
        self.force_buffer.writeTyped(particle.Force, 0, forces[0..force_count]);
        self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});

        seed_buffer.destroy();
    }

    fn setupRenderPipeline(self: *Simulation) !void {
        self.hdr_texture = gpu.createHDRTexture(self.canvas_width, self.canvas_height);
        self.hdr_texture_view = gpu.createTextureView(self.hdr_texture);

        const glow_shader = gpu.createShaderModule(shaders.particle_render_glow);
        const circle_shader = gpu.createShaderModule(shaders.particle_render_circle);
        const point_shader = gpu.createShaderModule(shaders.particle_render_point_hdr);

        const particle_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.VERTEX, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(1, gpu.ShaderVisibility.VERTEX, .read_only_storage),
        });
        const camera_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.VERTEX | gpu.ShaderVisibility.FRAGMENT, .uniform),
        });

        self.particle_bind_group = gpu.createBindGroup(particle_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.particle_buffer.handle, self.particle_buffer.size),
            gpu.BindGroupEntry.initBufferFull(1, self.species_buffer.handle, self.species_buffer.size),
        });
        self.camera_bind_group = gpu.createBindGroup(camera_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.camera_buffer.handle, self.camera_buffer.size),
        });

        const render_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ particle_layout, camera_layout });

        self.glow_pipeline = gpu.createRenderPipelineHDR(render_pl, glow_shader, "vertexGlow", "fragmentGlow", .rgba16float, true);
        self.circle_pipeline = gpu.createRenderPipelineHDR(render_pl, circle_shader, "vertexCircle", "fragmentCircle", .rgba16float, true);
        self.point_pipeline = gpu.createRenderPipelineHDR(render_pl, point_shader, "vertexPoint", "fragmentPoint", .rgba16float, true);

        const compose_shader_mod = gpu.createShaderModule(shaders.compose_shader);
        self.compose_bind_group_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initTexture(0, gpu.ShaderVisibility.FRAGMENT),
            gpu.BindGroupLayoutEntry.initTexture(1, gpu.ShaderVisibility.FRAGMENT),
        });

        self.compose_bind_group = gpu.createBindGroup(self.compose_bind_group_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initTextureView(0, self.hdr_texture_view),
            gpu.BindGroupEntry.initTextureView(1, self.hdr_texture_view),
        });

        const compose_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{self.compose_bind_group_layout});
        self.compose_pipeline = gpu.createRenderPipeline(compose_pl, compose_shader_mod, "vertexMain", "fragmentMain");
    }

    fn setupAdvancePipeline(self: *Simulation) !void {
        const advance_shader = gpu.createShaderModule(shaders.particle_advance);

        const particle_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .storage),
        });
        const options_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .uniform),
        });

        self.advance_particle_group = gpu.createBindGroup(particle_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.particle_buffer.handle, self.particle_buffer.size),
        });
        self.advance_options_group = gpu.createBindGroup(options_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, self.options_buffer.handle, self.options_buffer.size),
        });

        const advance_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ particle_layout, options_layout });
        self.advance_pipeline = gpu.createComputePipeline(advance_pl, advance_shader, "particleAdvance");
    }

    pub fn handleInput(self: *Simulation) void {
        const mouse = input.getMouse();
        const canvas_w: f32 = @floatFromInt(self.canvas_width);
        const canvas_h: f32 = @floatFromInt(self.canvas_height);

        // Zoom
        if (mouse.wheel != 0) {
            const zoom_speed: f32 = 0.001;
            const zoom_factor = 1.0 + mouse.wheel * zoom_speed;

            const mouse_x_ndc = (mouse.x / canvas_w) * 2.0 - 1.0;
            const mouse_y_ndc = 1.0 - (mouse.y / canvas_h) * 2.0;

            const mouse_world_x = self.camera.center_x + mouse_x_ndc * self.camera.extent_x;
            const mouse_world_y = self.camera.center_y + mouse_y_ndc * self.camera.extent_y;

            self.camera.extent_x *= zoom_factor;
            self.camera.extent_y *= zoom_factor;

            self.camera.center_x = mouse_world_x - mouse_x_ndc * self.camera.extent_x;
            self.camera.center_y = mouse_world_y - mouse_y_ndc * self.camera.extent_y;
            self.camera.pixels_per_unit = canvas_w / (2.0 * self.camera.extent_x);

            self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
        }

        // Pan (middle button)
        if (mouse.buttons.middle and (mouse.dx != 0 or mouse.dy != 0)) {
            const pan_speed = 1.0 / self.camera.pixels_per_unit;
            self.camera.center_x -= mouse.dx * pan_speed;
            self.camera.center_y += mouse.dy * pan_speed;
            self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
        }

        // Attract/repel
        if (mouse.buttons.left or mouse.buttons.right) {
            const mouse_x_ndc = if (canvas_w > 0) (mouse.x / canvas_w) * 2.0 - 1.0 else 0.0;
            const mouse_y_ndc = if (canvas_h > 0) 1.0 - (mouse.y / canvas_h) * 2.0 else 0.0;

            self.options.action_x = self.camera.center_x + mouse_x_ndc * self.camera.extent_x;
            self.options.action_y = self.camera.center_y + mouse_y_ndc * self.camera.extent_y;

            const drag_x_ndc = if (canvas_w > 0) (mouse.dx * 2.0) / canvas_w else 0.0;
            const drag_y_ndc = if (canvas_h > 0) (-mouse.dy * 2.0) / canvas_h else 0.0;
            self.options.action_vx = self.camera.extent_x * drag_x_ndc;
            self.options.action_vy = self.camera.extent_y * drag_y_ndc;
            self.options.action_radius = self.camera.extent_x / 16.0;
            self.options.action_force = if (mouse.buttons.left) 20.0 else -20.0;
        } else {
            self.options.action_force = 0.0;
            self.options.action_vx = 0.0;
            self.options.action_vy = 0.0;
            self.options.action_radius = 0.0;
        }
    }

    pub fn updateCamera(self: *Simulation, w: u32, h: u32) void {
        if (w != self.canvas_width or h != self.canvas_height) {
            self.canvas_width = w;
            self.canvas_height = h;

            gpu.destroyTexture(self.hdr_texture);
            self.hdr_texture = gpu.createHDRTexture(w, h);
            self.hdr_texture_view = gpu.createTextureView(self.hdr_texture);

            const noise_view = self.blue_noise_texture_view orelse self.hdr_texture_view;
            self.compose_bind_group = gpu.createBindGroup(self.compose_bind_group_layout, &[_]gpu.BindGroupEntry{
                gpu.BindGroupEntry.initTextureView(0, self.hdr_texture_view),
                gpu.BindGroupEntry.initTextureView(1, noise_view),
            });
        }

        self.camera = particle.CameraParams.initForSimulation(
            @floatFromInt(w),
            @floatFromInt(h),
            self.sim_width,
            self.sim_height,
        );
        self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
    }

    pub fn setBlueNoiseTexture(self: *Simulation, view: gpu.TextureView) void {
        self.blue_noise_texture_view = view;
        self.compose_bind_group = gpu.createBindGroup(self.compose_bind_group_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initTextureView(0, self.hdr_texture_view),
            gpu.BindGroupEntry.initTextureView(1, view),
        });
    }

    pub fn update(self: *Simulation, dt: f32) void {
        const clamped_dt = @min(dt, 0.025);
        self.options.dt = clamped_dt;
        const coeff = self.friction_coefficient;
        self.options.friction = if (coeff <= 0.0) 1.0 else std.math.exp(-clamped_dt * coeff);
        self.options_buffer.writeTyped(particle.SimulationOptions, 0, &[_]particle.SimulationOptions{self.options});

        const encoder = self.spatial_pipeline.computeForces(
            self.particle_count,
            self.particle_buffer.handle,
            self.spatial_pipeline.particle_temp_buffer.handle,
        );

        const advance_pass = gpu.beginComputePass(encoder);
        gpu.computePassSetPipeline(advance_pass, self.advance_pipeline);
        gpu.computePassSetBindGroup(advance_pass, 0, self.advance_particle_group);
        gpu.computePassSetBindGroup(advance_pass, 1, self.advance_options_group);
        gpu.computePassDispatch(advance_pass, (self.particle_count + 63) / 64, 1, 1);
        gpu.computePassEnd(advance_pass);

        gpu.queueSubmit(gpu.encoderFinish(encoder));
    }

    pub fn render(self: *Simulation) void {
        const vertex_count = self.particle_count * 6;

        // HDR pass
        const hdr_pass = gpu.beginRenderPassHDR(self.hdr_texture_view, 0.001, 0.001, 0.001, 0.0);

        gpu.renderPassSetBindGroup(hdr_pass, 0, self.particle_bind_group);
        gpu.renderPassSetBindGroup(hdr_pass, 1, self.camera_bind_group);

        gpu.renderPassSetPipeline(hdr_pass, self.glow_pipeline);
        gpu.renderPassDraw(hdr_pass, vertex_count, 1, 0, 0);

        if (self.camera.pixels_per_unit < 1.0) {
            gpu.renderPassSetPipeline(hdr_pass, self.point_pipeline);
        } else {
            gpu.renderPassSetPipeline(hdr_pass, self.circle_pipeline);
        }
        gpu.renderPassDraw(hdr_pass, vertex_count, 1, 0, 0);

        gpu.renderPassEnd(hdr_pass);

        // Screen pass (HDR -> tonemap)
        const screen_pass = gpu.beginRenderPass(0.1, 0.0, 0.1, 1.0);
        gpu.renderPassSetPipeline(screen_pass, self.compose_pipeline);
        gpu.renderPassSetBindGroup(screen_pass, 0, self.compose_bind_group);
        gpu.renderPassDraw(screen_pass, 3, 1, 0, 0);
        gpu.renderPassEnd(screen_pass);

        gpu.present();
    }

    pub fn deinit(self: *Simulation) void {
        self.particle_buffer.destroy();
        self.species_buffer.destroy();
        self.force_buffer.destroy();
        self.options_buffer.destroy();
        self.camera_buffer.destroy();
        self.spatial_pipeline.deinit();
    }
};
