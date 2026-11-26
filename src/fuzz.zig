const std = @import("std");
const workload = @import("fuzz_generate.zig");
const path = @import("gen/build_path.zig");
const reader = @import("gen/wasm_reader.zig");
const resolver = @import("gen/js_resolve.zig");
const assert = @import("assert.zig").assert;
const commit = @import("fuzz_options").commit;
const memory_max: u32 = 16 * 1024 * 1024;
const iterations_default: u32 = 4096;
const iterations_max: u32 = 10000000;

const Options = struct {
    seed: u64,
    iterations: u32 = iterations_default,
    replay: ?[]const u8 = null,
};
const Counters = struct {
    accepted: u64 = 0,
    rejected_reader: u64 = 0,
    rejected_generation: u64 = 0,
    unresolved: u64 = 0,
    provided: u64 = 0,
    duplicate: u64 = 0,
    zero_imports: u64 = 0,
    many_imports: u64 = 0,
    custom: u64 = 0,
    determinism: u64 = 0,
    no_output: u64 = 0,
    memory_limit: u64 = 0,
    step_limit: u64 = 0,
    import_limit: u64 = 0,
    option_limit: u64 = 0,
    source_map: u64 = 0,
    fonts: u64 = 0,
    profiles: [16]u64 = @splat(0),
    mutations: [16]u64 = @splat(0),
    truncated_sections: [13]u64 = @splat(0),
};
const Context = struct {
    io: std.Io,
    options: Options,
    number: u32 = 0,
    case: *workload.Case,
};
var active: ?*Context = null;
pub const panic = std.debug.FullPanic(panic_handler);

fn panic_handler(message: []const u8, address: ?usize) noreturn {
    _ = address;
    if (active) |context| {
        save_failure(context, message) catch |err| {
            std.debug.print("saving panic failed: {s}\n", .{@errorName(err)});
        };
    }
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    assert(memory_max >= workload.input_max);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parse_options(init.io, args);
    const memory = try init.arena.allocator().alloc(u8, 3 * memory_max);
    @memset(memory[0..memory_max], 0xa5);
    @memset(memory[memory_max..][0..memory_max], 0x5a);
    const case = try init.arena.allocator().create(workload.Case);
    var context = Context{ .io = init.io, .options = options, .case = case };
    active = &context;
    defer active = null;
    std.debug.print("fuzz seed={d} iterations={d} commit={s}\n", .{
        options.seed, options.iterations, commit,
    });
    var counters = Counters{};
    var random = std.Random.DefaultPrng.init(options.seed);
    const started = std.Io.Clock.awake.now(init.io);
    for (0..options.iterations) |number| {
        context.number = @intCast(number);
        if (options.replay) |file| {
            case.* = .{};
            const bytes = try std.Io.Dir.cwd().readFile(init.io, file, &case.buffer.bytes);
            case.buffer.length = @intCast(bytes.len);
            try replay_expectation(&context, file);
        } else {
            try workload.generate(case, random.random(), @intCast(number));
        }
        check_case(case, memory, &counters) catch |err| {
            try save_failure(&context, @errorName(err));
            return err;
        };
        counters.profiles[case.profile] += 1;
        counters.mutations[case.mutation] += 1;
        if (case.mutation == 15) counters.truncated_sections[case.truncation] += 1;
    }
    const elapsed = started.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    print_counters(counters, options.iterations, elapsed);
    if (options.replay == null and options.iterations >= 512) try verify_coverage(counters);
    assert(context.number < options.iterations);
}

fn parse_options(io: std.Io, args: []const []const u8) !Options {
    assert(args.len > 0);
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var options = Options{ .seed = seed };
    var index: u32 = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingArgument;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, name, "--iterations")) {
            options.iterations = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--replay")) {
            options.replay = value;
        } else return error.UnknownArgument;
    }
    if (options.replay != null) options.iterations = 1;
    if (options.iterations == 0 or options.iterations > iterations_max) return error.IterationLimit;
    assert(options.iterations <= iterations_max);
    return options;
}

fn check_case(case: *const workload.Case, memory: []u8, counters: *Counters) !void {
    assert(memory.len == 3 * memory_max);
    assert(case.count <= workload.imports_max);
    const options = @import("gen/js_gen.zig").GenOptions{
        .wasm_filename = "fuzz.wasm",
        .json_report = true,
        .wasm_preload = case.buffer.length % 2 == 0,
        .bridge_js_chunks = if (case.buffer.length % 3 == 0) &.{.{
            .origin = "fuzz/bridge.js",
            .source = "window.fuzzBridge = true;\n",
        }} else &.{},
        .fonts = if (case.buffer.length % 5 == 0) &.{.{
            .family = "Fuzz",
            .weight = 400,
            .file = "fuzz.ttf",
        }} else &.{},
        .fonts_blocking = case.buffer.length % 7 == 0,
    };
    var first_output = path.Publication{};
    var second_output = path.Publication{};
    const first = observe(memory[0..memory_max], case.buffer.slice(), options, .{}, &first_output);
    const second = observe(
        memory[memory_max..][0..memory_max],
        case.buffer.slice(),
        options,
        .{},
        &second_output,
    );
    if (first) |result| {
        if (case.malformed) return error.AcceptedMalformed;
        const again = second catch return error.NondeterministicError;
        try compare_output(result, again);
        counters.determinism += 1;
        var oracle = std.heap.FixedBufferAllocator.init(memory[2 * memory_max ..]);
        try accounting(case, result, oracle.allocator(), counters);
        try probe_limits(case, memory[2 * memory_max ..], options, counters);
        counters.accepted += 1;
        counters.custom += @intFromBool(result.analysis.has_name_section);
        counters.zero_imports += @intFromBool(case.count == 0);
        counters.many_imports += @intFromBool(case.count >= 96);
        counters.source_map += @intFromBool(result.generated.js_map.len > 0);
        counters.fonts += @intFromBool(options.fonts.len > 0);
    } else |err| {
        if (second) |_| return error.NondeterministicAcceptance else |other| {
            if (err != other) return error.NondeterministicError;
        }
        if (!case.malformed) return err;
        switch (err) {
            error.OutOfMemory, error.WriteFailed, error.StepLimit => return err,
            else => {},
        }
        if (first_output.stage != .reader) return error.RejectedAtWrongStage;
        counters.rejected_reader += 1;
        counters.no_output += 1;
    }
}

fn observe(
    memory: []u8,
    bytes: []const u8,
    options: @import("gen/js_gen.zig").GenOptions,
    limits: path.Limits,
    output: *path.Publication,
) !path.Result {
    assert(memory.len > 0);
    path.build(memory, bytes, options, limits, output) catch |err| {
        if (output.result != null) return error.OutputOnError;
        return err;
    };
    const result = output.result orelse return error.MissingOutput;
    assert(result.generated.js.len > 0);
    assert(result.generated.dispositions.len == result.analysis.imports.len);
    return result;
}

fn compare_output(first: path.Result, second: path.Result) !void {
    assert(first.generated.dispositions.len == first.analysis.imports.len);
    const a = first.generated;
    const b = second.generated;
    if (!std.mem.eql(u8, a.js, b.js) or !std.mem.eql(u8, a.html, b.html) or
        !std.mem.eql(u8, a.report, b.report) or !std.mem.eql(u8, a.js_map, b.js_map) or
        !std.mem.eql(u8, &a.js_hash, &b.js_hash)) return error.NondeterministicOutput;
    if (!std.mem.eql(@import("gen/js_gen.zig").Disposition, a.dispositions, b.dispositions)) {
        return error.NondeterministicAccounting;
    }
    assert(a.js.len > 0 and a.html.len > 0);
    assert(b.js.len > 0 and b.html.len > 0);
}

fn accounting(
    case: *const workload.Case,
    result: path.Result,
    allocator: std.mem.Allocator,
    counters: *Counters,
) !void {
    assert(case.count <= workload.imports_max);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.generated.report,
        .{ .allocate = .alloc_always },
    );
    const entries = parsed.value.object.get("resolutions") orelse return error.MissingReport;
    if (entries.array.items.len != case.count) return error.MissingReportImport;
    if (result.analysis.imports.len != case.count) return error.MissingAnalyzedImport;
    for (case.declarations[0..case.count], 0..) |declaration, index| {
        const import = &result.analysis.imports[index];
        if (!std.mem.eql(u8, declaration.module, import.module) or
            !std.mem.eql(u8, declaration.name, import.name) or declaration.kind != import.kind)
            return error.ChangedImport;
        const signature = result.analysis.getImportSignature(import);
        const resolution = try resolver.resolve(allocator, import, signature);
        const expected = resolution.confidence != .stub;
        const provided = result.generated.dispositions[index] == .provided;
        const entry = entries.array.items[index].object;
        const confidence = entry.get("confidence") orelse return error.MissingConfidence;
        const unresolved = std.mem.eql(u8, confidence.string, "stub");
        if (provided != expected or provided == unresolved) return error.ImportAccounting;
        if (!std.mem.eql(u8, entry.get("module").?.string, declaration.module) or
            !std.mem.eql(u8, entry.get("name").?.string, declaration.name))
            return error.ChangedReportImport;
        counters.provided += @intFromBool(provided);
        counters.unresolved += @intFromBool(unresolved);
        for (case.declarations[0..index]) |previous| {
            if (std.mem.eql(u8, previous.module, declaration.module) and
                std.mem.eql(u8, previous.name, declaration.name)) counters.duplicate += 1;
        }
    }
    assert(result.generated.dispositions.len == case.count);
}

fn probe_limits(
    case: *const workload.Case,
    memory: []u8,
    options: @import("gen/js_gen.zig").GenOptions,
    counters: *Counters,
) !void {
    assert(memory.len == memory_max);
    assert(!case.malformed);
    var output = path.Publication{};
    const tiny = observe(memory[0..1], case.buffer.slice(), options, .{}, &output);
    if (tiny) |_| return error.MissedMemoryLimit else |err| {
        if (err != error.OutOfMemory) return err;
        counters.memory_limit += 1;
    }
    const late = observe(memory[0..4096], case.buffer.slice(), options, .{}, &output);
    if (late) |_| {} else |err| {
        if (err != error.OutOfMemory and err != error.WriteFailed) return err;
        if (output.stage == .generation) counters.rejected_generation += 1;
    }
    const limited = observe(memory, case.buffer.slice(), options, .{ .steps = 1 }, &output);
    if (limited) |_| return error.MissedStepLimit else |err| {
        if (err != error.StepLimit) return err;
        counters.step_limit += 1;
    }
    if (case.count > 0) {
        const imports = observe(memory, case.buffer.slice(), options, .{ .imports = 0 }, &output);
        if (imports) |_| return error.MissedImportLimit else |err| {
            if (err != error.ImportLimit) return err;
            counters.import_limit += 1;
        }
    }
    const option_limit = observe(
        memory,
        case.buffer.slice(),
        options,
        .{ .option_bytes = 0 },
        &output,
    );
    if (option_limit) |_| return error.MissedOptionLimit else |err| {
        if (err != error.OptionLimit) return err;
        counters.option_limit += 1;
    }
}

fn recover_declarations(case: *workload.Case) !void {
    assert(case.buffer.length <= workload.input_max);
    var steps: u64 = 10000000;
    var input = reader.Reader{ .bytes = case.buffer.slice(), .steps = &steps };
    if (!std.mem.eql(u8, try input.take(8), workload.header)) return error.InvalidHeader;
    for (0..case.buffer.length) |_| {
        if (input.position == input.bytes.len) break;
        const id = try input.byte();
        const bytes = try input.take(try input.integer());
        if (id != 2) continue;
        var imports = reader.Reader{ .bytes = bytes, .steps = &steps };
        case.count = try imports.integer();
        if (case.count > workload.imports_max) return error.InputLimit;
        for (case.declarations[0..case.count]) |*declaration| {
            const module = try imports.name();
            const name = try imports.name();
            const kind = try imports.byte();
            declaration.* = .{ .module = module, .name = name, .kind = kind };
            switch (kind) {
                0 => _ = try imports.integer(),
                1 => {
                    _ = try imports.value_type();
                    try imports.limits();
                },
                2 => try imports.limits(),
                3 => {
                    _ = try imports.value_type();
                    _ = try imports.byte();
                },
                else => return error.InvalidImportKind,
            }
        }
    }
    assert(case.count <= workload.imports_max);
}

fn replay_expectation(context: *Context, file: []const u8) !void {
    assert(context.case.buffer.length <= workload.input_max);
    recover_declarations(context.case) catch |err| switch (err) {
        error.InputLimit => return err,
        else => context.case.malformed = true,
    };
    var filename: [4096]u8 = undefined;
    const expectation = try std.fmt.bufPrint(&filename, "{s}.expect", .{file});
    var bytes: [16]u8 = undefined;
    const saved = std.Io.Dir.cwd().readFile(context.io, expectation, &bytes) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (std.mem.eql(u8, saved, "reject\n")) {
        context.case.malformed = true;
    } else if (!std.mem.eql(u8, saved, "accept\n")) return error.InvalidExpectation;
    assert(saved.len > 0);
}

fn save_failure(context: *const Context, reason: []const u8) !void {
    assert(context.case.buffer.length <= workload.input_max);
    assert(context.number < context.options.iterations);
    var filename: [160]u8 = undefined;
    const file = try std.fmt.bufPrint(
        &filename,
        "zig-out/fuzz/seed-{d}-case-{d}.wasm",
        .{ context.options.seed, context.number },
    );
    std.debug.print("FAIL seed={d} case={d} commit={s} reason={s} replay={s}\n", .{
        context.options.seed, context.number, commit, reason, file,
    });
    try std.Io.Dir.cwd().createDirPath(context.io, "zig-out/fuzz");
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = file,
        .data = context.case.buffer.slice(),
    });
    var expectation_name: [176]u8 = undefined;
    const expectation = try std.fmt.bufPrint(&expectation_name, "{s}.expect", .{file});
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = expectation,
        .data = if (context.case.malformed) "reject\n" else "accept\n",
    });
    assert(file.len < filename.len);
    assert(expectation.len < expectation_name.len);
}

fn verify_coverage(counters: Counters) !void {
    assert(counters.determinism == counters.accepted);
    assert(counters.no_output == counters.rejected_reader);
    inline for (comptime std.meta.fieldNames(Counters)) |name| {
        const value = @field(counters, name);
        if (@TypeOf(value) == u64) {
            if (value == 0) return error.CoverageGap;
        } else {
            for (value) |count| if (count == 0) return error.CoverageGap;
        }
    }
}

fn print_counters(counters: Counters, iterations: u32, elapsed_ns: i96) void {
    assert(iterations > 0);
    assert(counters.accepted + counters.rejected_reader == iterations);
    inline for (comptime std.meta.fieldNames(Counters)) |name| {
        std.debug.print("{s}={any}\n", .{ name, @field(counters, name) });
    }
    const seconds = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / 1000000000;
    std.debug.print("cases={d} seconds={d:.3} cases_per_second={d:.0}\n", .{
        iterations, seconds, @as(f64, @floatFromInt(iterations)) / seconds,
    });
}
