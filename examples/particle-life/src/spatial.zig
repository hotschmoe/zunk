const std = @import("std");
const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const particle = @import("particle.zig");
const shaders = @import("shaders.zig");
const sim = @import("simulation.zig");

const BufferInfo = sim.BufferInfo;
const createStorageBuffer = sim.createStorageBuffer;
const createUniformBuffer = sim.createUniformBuffer;

pub fn calculateGridSize(sim_width: f32, sim_height: f32, bin_size: f32) struct { grid_x: u32, grid_y: u32, bin_count: u32 } {
    const grid_x = @as(u32, @intFromFloat(@ceil(sim_width / bin_size)));
    const grid_y = @as(u32, @intFromFloat(@ceil(sim_height / bin_size)));
    return .{ .grid_x = grid_x, .grid_y = grid_y, .bin_count = grid_x * grid_y };
}

pub fn calculatePrefixSumIterations(bin_count: u32) u32 {
    const log2_bins = std.math.log2_int_ceil(u32, bin_count);
    return ((log2_bins + 1) / 2) * 2;
}

pub const SpatialPipeline = struct {
    bin_clear_pipeline: gpu.ComputePipeline,
    bin_fill_pipeline: gpu.ComputePipeline,
    prefix_sum_pipeline: gpu.ComputePipeline,
    sort_clear_pipeline: gpu.ComputePipeline,
    sort_pipeline: gpu.ComputePipeline,
    forces_pipeline: gpu.ComputePipeline,

    particle_readonly_group: gpu.BindGroup,
    options_group: gpu.BindGroup,
    bin_size_group: gpu.BindGroup,
    prefix_sum_group_0: gpu.BindGroup,
    prefix_sum_group_1: gpu.BindGroup,
    sort_group: gpu.BindGroup,
    forces_group: gpu.BindGroup,

    particle_temp_buffer: BufferInfo,
    bin_offset_buffer: BufferInfo,
    bin_offset_temp_buffer: BufferInfo,
    prefix_sum_step_buffer: BufferInfo,

    bin_count: u32,
    prefix_sum_iterations: u32,

    pub fn init(
        particle_buffer: BufferInfo,
        force_buffer: BufferInfo,
        options_buffer: BufferInfo,
        sim_width: f32,
        sim_height: f32,
        max_force_radius: f32,
    ) !SpatialPipeline {

        const grid = calculateGridSize(sim_width, sim_height, max_force_radius);
        const bin_count = grid.bin_count;
        const prefix_sum_iterations = calculatePrefixSumIterations(bin_count);

        const particle_temp_buffer = createStorageBuffer(particle_buffer.size);
        const bin_offset_buffer = createStorageBuffer((bin_count + 1) * 4);
        const bin_offset_temp_buffer = createStorageBuffer((bin_count + 1) * 4);
        const prefix_sum_step_buffer = createUniformBuffer(prefix_sum_iterations * 256);

        var step_sizes: [2048]u32 = undefined;
        @memset(&step_sizes, 0);
        for (0..prefix_sum_iterations) |i| {
            step_sizes[i * 64] = @as(u32, 1) << @intCast(i);
        }
        prefix_sum_step_buffer.writeTyped(u32, 0, step_sizes[0..(prefix_sum_iterations * 64)]);

        const binning_shader = gpu.createShaderModule(shaders.spatial_binning);
        const prefix_sum_shader = gpu.createShaderModule(shaders.prefix_sum);
        const sort_shader = gpu.createShaderModule(shaders.particle_sort);
        const forces_shader = gpu.createShaderModule(shaders.force_computation);

        // Bind group layouts
        const particle_readonly_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
        });

        const options_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .uniform),
        });

        const bin_size_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .storage),
        });

        const prefix_sum_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(1, gpu.ShaderVisibility.COMPUTE, .storage),
            gpu.BindGroupLayoutEntry.initBuffer(2, gpu.ShaderVisibility.COMPUTE, .uniform).withDynamicOffset(),
        });

        const sort_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(1, gpu.ShaderVisibility.COMPUTE, .storage),
            gpu.BindGroupLayoutEntry.initBuffer(2, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(3, gpu.ShaderVisibility.COMPUTE, .storage),
        });

        const forces_layout = gpu.createBindGroupLayout(&[_]gpu.BindGroupLayoutEntry{
            gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(1, gpu.ShaderVisibility.COMPUTE, .storage),
            gpu.BindGroupLayoutEntry.initBuffer(2, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
            gpu.BindGroupLayoutEntry.initBuffer(3, gpu.ShaderVisibility.COMPUTE, .read_only_storage),
        });

        // Bind groups
        const particle_readonly_group = gpu.createBindGroup(particle_readonly_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, particle_buffer.handle, particle_buffer.size),
        });

        const options_group = gpu.createBindGroup(options_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, options_buffer.handle, options_buffer.size),
        });

        const bin_size_group = gpu.createBindGroup(bin_size_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, bin_offset_buffer.handle, bin_offset_buffer.size),
        });

        const prefix_sum_group_0 = gpu.createBindGroup(prefix_sum_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, bin_offset_buffer.handle, bin_offset_buffer.size),
            gpu.BindGroupEntry.initBufferFull(1, bin_offset_temp_buffer.handle, bin_offset_temp_buffer.size),
            gpu.BindGroupEntry.initBuffer(2, prefix_sum_step_buffer.handle, 0, 4),
        });

        const prefix_sum_group_1 = gpu.createBindGroup(prefix_sum_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, bin_offset_temp_buffer.handle, bin_offset_temp_buffer.size),
            gpu.BindGroupEntry.initBufferFull(1, bin_offset_buffer.handle, bin_offset_buffer.size),
            gpu.BindGroupEntry.initBuffer(2, prefix_sum_step_buffer.handle, 0, 4),
        });

        const sort_group = gpu.createBindGroup(sort_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, particle_buffer.handle, particle_buffer.size),
            gpu.BindGroupEntry.initBufferFull(1, particle_temp_buffer.handle, particle_temp_buffer.size),
            gpu.BindGroupEntry.initBufferFull(2, bin_offset_buffer.handle, bin_offset_buffer.size),
            gpu.BindGroupEntry.initBufferFull(3, bin_offset_temp_buffer.handle, bin_offset_temp_buffer.size),
        });

        const forces_group = gpu.createBindGroup(forces_layout, &[_]gpu.BindGroupEntry{
            gpu.BindGroupEntry.initBufferFull(0, particle_temp_buffer.handle, particle_temp_buffer.size),
            gpu.BindGroupEntry.initBufferFull(1, particle_buffer.handle, particle_buffer.size),
            gpu.BindGroupEntry.initBufferFull(2, bin_offset_buffer.handle, bin_offset_buffer.size),
            gpu.BindGroupEntry.initBufferFull(3, force_buffer.handle, force_buffer.size),
        });

        // Pipelines
        const binning_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ particle_readonly_layout, options_layout, bin_size_layout });
        const prefix_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{prefix_sum_layout});
        const sort_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ sort_layout, options_layout });
        const forces_pl = gpu.createPipelineLayout(&[_]gpu.BindGroupLayout{ forces_layout, options_layout });

        return .{
            .bin_clear_pipeline = gpu.createComputePipeline(binning_pl, binning_shader, "clearBinSize"),
            .bin_fill_pipeline = gpu.createComputePipeline(binning_pl, binning_shader, "fillBinSize"),
            .prefix_sum_pipeline = gpu.createComputePipeline(prefix_pl, prefix_sum_shader, "prefixSumStep"),
            .sort_clear_pipeline = gpu.createComputePipeline(sort_pl, sort_shader, "clearBinSize"),
            .sort_pipeline = gpu.createComputePipeline(sort_pl, sort_shader, "sortParticles"),
            .forces_pipeline = gpu.createComputePipeline(forces_pl, forces_shader, "computeForces"),
            .particle_readonly_group = particle_readonly_group,
            .options_group = options_group,
            .bin_size_group = bin_size_group,
            .prefix_sum_group_0 = prefix_sum_group_0,
            .prefix_sum_group_1 = prefix_sum_group_1,
            .sort_group = sort_group,
            .forces_group = forces_group,
            .particle_temp_buffer = particle_temp_buffer,
            .bin_offset_buffer = bin_offset_buffer,
            .bin_offset_temp_buffer = bin_offset_temp_buffer,
            .prefix_sum_step_buffer = prefix_sum_step_buffer,
            .bin_count = bin_count,
            .prefix_sum_iterations = prefix_sum_iterations,
        };
    }

    pub fn computeForces(self: *SpatialPipeline, particle_count: u32, particle_buf: gpu.Buffer, particle_temp_buf: gpu.Buffer) gpu.CommandEncoder {
        const encoder = gpu.createCommandEncoder();

        gpu.copyBufferInEncoder(encoder, particle_buf, 0, particle_temp_buf, 0, particle_count * @sizeOf(particle.Particle));

        const binning_pass = gpu.beginComputePass(encoder);

        gpu.computePassSetPipeline(binning_pass, self.bin_clear_pipeline);
        gpu.computePassSetBindGroup(binning_pass, 0, self.particle_readonly_group);
        gpu.computePassSetBindGroup(binning_pass, 1, self.options_group);
        gpu.computePassSetBindGroup(binning_pass, 2, self.bin_size_group);
        gpu.computePassDispatch(binning_pass, (self.bin_count + 1 + 63) / 64, 1, 1);

        gpu.computePassSetPipeline(binning_pass, self.bin_fill_pipeline);
        gpu.computePassDispatch(binning_pass, (particle_count + 63) / 64, 1, 1);

        gpu.computePassSetPipeline(binning_pass, self.prefix_sum_pipeline);
        for (0..self.prefix_sum_iterations) |i| {
            const group = if (i % 2 == 0) self.prefix_sum_group_0 else self.prefix_sum_group_1;
            const offset = @as(u32, @intCast(i)) * 256;
            gpu.computePassSetBindGroupWithOffset(binning_pass, 0, group, offset);
            gpu.computePassDispatch(binning_pass, (self.bin_count + 1 + 63) / 64, 1, 1);
        }

        gpu.computePassSetPipeline(binning_pass, self.sort_clear_pipeline);
        gpu.computePassSetBindGroup(binning_pass, 0, self.sort_group);
        gpu.computePassSetBindGroup(binning_pass, 1, self.options_group);
        gpu.computePassDispatch(binning_pass, (self.bin_count + 1 + 63) / 64, 1, 1);

        gpu.computePassSetPipeline(binning_pass, self.sort_pipeline);
        gpu.computePassDispatch(binning_pass, (particle_count + 63) / 64, 1, 1);

        gpu.computePassEnd(binning_pass);

        const forces_pass = gpu.beginComputePass(encoder);
        gpu.computePassSetPipeline(forces_pass, self.forces_pipeline);
        gpu.computePassSetBindGroup(forces_pass, 0, self.forces_group);
        gpu.computePassSetBindGroup(forces_pass, 1, self.options_group);
        gpu.computePassDispatch(forces_pass, (particle_count + 63) / 64, 1, 1);
        gpu.computePassEnd(forces_pass);

        return encoder;
    }

    pub fn deinit(self: *SpatialPipeline) void {
        self.particle_temp_buffer.destroy();
        self.bin_offset_buffer.destroy();
        self.bin_offset_temp_buffer.destroy();
        self.prefix_sum_step_buffer.destroy();
    }
};
