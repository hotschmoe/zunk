const std = @import("std");
const wasm = @import("wasm_analyze.zig");
const generator = @import("js_gen.zig");
const assert = @import("../assert.zig").assert;

pub const Limits = struct {
    steps: u64 = wasm.steps_max,
    imports: u32 = 1024,
    option_bytes: u32 = 65536,
};

pub const Result = struct {
    analysis: wasm.Analysis,
    generated: generator.GenResult,
};

pub const Publication = struct {
    result: ?Result = null,
    stage: enum { reader, generation } = .reader,
};

pub fn build(
    storage: []u8,
    bytes: []const u8,
    options: generator.GenOptions,
    limits: Limits,
    publication: *Publication,
) !void {
    assert(storage.len > 0);
    assert(limits.imports <= wasm.entries_max);
    publication.* = .{};
    const option_bytes = try measure_options(options, limits.option_bytes);
    var memory = std.heap.FixedBufferAllocator.init(storage);
    var steps = limits.steps;
    const analysis = try wasm.analyze(memory.allocator(), bytes, &steps);
    if (analysis.imports.len > limits.imports) return error.ImportLimit;
    // Reserve the finite generator loops, including 64x64 edit-distance suggestions.
    const generation_steps = (@as(u64, bytes.len) + option_bytes) * 128 +
        analysis.imports.len * 262144;
    if (generation_steps > steps) return error.StepLimit;
    publication.stage = .generation;
    const generated = try generator.generate(memory.allocator(), &analysis, options);
    assert(generated.dispositions.len == analysis.imports.len);
    assert(memory.end_index <= storage.len);
    publication.result = .{ .analysis = analysis, .generated = generated };
}

fn measure_options(options: generator.GenOptions, limit: u32) !u64 {
    if (options.fonts.len > 128 or options.bridge_js_chunks.len > 64) return error.OptionLimit;
    var count: u64 = options.public_url.len + options.wasm_filename.len + options.js_filename.len;
    if (options.js_integrity) |value| count += value.len;
    for (options.fonts) |font| count += font.family.len + font.file.len;
    for (options.bridge_js_chunks) |chunk| count += chunk.origin.len + chunk.source.len;
    if (count > limit) return error.OptionLimit;
    assert(count <= limit);
    assert(options.fonts.len <= 128 and options.bridge_js_chunks.len <= 64);
    return count;
}
