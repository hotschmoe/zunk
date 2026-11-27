const std = @import("std");
const assert = @import("assert.zig").assert;
const api = @import("gen/serve_io.zig");
const serve_loop = @import("gen/serve_loop.zig");
const serve_sim = @import("gen/serve_sim.zig");
const types = @import("gen/serve_sim_types.zig");

const steps_default: u32 = 6000;
const steps_max: u32 = 10000000;
const seeds_max: u32 = 1000000;
const fault_steps_max: u32 = 250;
const repeat_every: u32 = 4;
const fault_cases: u64 = 56;
const text_bytes: usize = 4 * 1024 * 1024;
const coverage_seeds_min: u32 = 8;

const Options = struct {
    seed: u64,
    steps: u32 = steps_default,
    seeds: u32 = 1,
    replay: ?[]const u8 = null,
    budget_s: u32 = 0,
};

const Runner = struct {
    io: std.Io,
    sim: *serve_sim.Sim,
    loop: *serve_loop.Loop,
    text: []u8,
    options: serve_sim.Options = undefined,
    totals: types.Counters = .{},
    campaign_hash: u64 = 0,
    failures: u32 = 0,
};

var active: ?*Runner = null;
pub const panic = std.debug.FullPanic(panic_handler);

fn panic_handler(message: []const u8, address: ?usize) noreturn {
    if (active) |runner| {
        save_trace(runner, "panic") catch |err| {
            std.debug.print("saving the trace failed: {s}\n", .{@errorName(err)});
        };
    }
    std.debug.defaultPanic(message, address);
}

fn reserve(comptime T: type) error{OutOfMemory}!*T {
    return @ptrCast(@alignCast(std.heap.page_allocator.rawAlloc(
        @sizeOf(T),
        .of(T),
        @returnAddress(),
    ) orelse return error.OutOfMemory));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parse_options(init.io, args);
    assert(options.steps > 0 and options.seeds > 0);
    const runner = try reserve(Runner);
    runner.* = .{
        .io = init.io,
        .sim = try reserve(serve_sim.Sim),
        .loop = try reserve(serve_loop.Loop),
        .text = try init.arena.allocator().alloc(u8, text_bytes),
    };
    assert(@intFromPtr(runner.sim) != @intFromPtr(runner.loop));
    active = runner;
    defer active = null;
    if (options.replay) |path| return replay(runner, path);
    try campaign(runner, options);
}

fn parse_options(io: std.Io, args: []const []const u8) !Options {
    assert(args.len > 0);
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var options: Options = .{ .seed = seed };
    var index: u32 = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingArgument;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, name, "--steps")) {
            options.steps = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            options.seeds = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--budget")) {
            options.budget_s = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--replay")) {
            options.replay = value;
        } else return error.UnknownArgument;
    }
    if (options.steps == 0 or options.steps > steps_max) return error.StepLimit;
    if (options.seeds == 0 or options.seeds > seeds_max) return error.SeedLimit;
    assert(options.steps <= steps_max);
    return options;
}

fn fault_for(seed: u64, steps: u32) serve_sim.Options {
    const case = seed % fault_cases;
    const call: serve_sim.FaultCall = @fromBackingInt(@intCast(case % serve_sim.fault_calls));
    const fault: serve_sim.Fault = .{
        .call = call,
        .error_index = @intCast(case % types.failure_variants),
        .countdown = if (call == .listen) 0 else @intCast((case / serve_sim.fault_calls) % 4),
    };
    assert(case < fault_cases and fault.countdown < 4);
    assert(fault.error_index < types.failure_variants);
    return .{ .seed = seed, .steps = @min(steps, fault_steps_max), .fault = fault };
}

const Outcome = struct { hash: u64, failed: types.Failed };

fn run_once(runner: *Runner, options: serve_sim.Options) Outcome {
    assert(options.steps > 0);
    runner.options = options;
    const config = runner.sim.begin(options);
    runner.loop.init(runner.sim.interface(), config);
    const result = runner.loop.run();
    runner.sim.finish(result);
    const outcome: Outcome = .{
        .hash = runner.sim.sh.trace.hash,
        .failed = runner.sim.sh.verdict.failed,
    };
    assert(runner.sim.sh.verdict.failed == outcome.failed);
    assert(outcome.hash == runner.sim.sh.trace.hash);
    return outcome;
}

fn run_checked(runner: *Runner, options: serve_sim.Options, twice: bool) !Outcome {
    assert(options.steps > 0);
    const first = run_once(runner, options);
    if (first.failed != .none) {
        report_failure(runner);
        return first;
    }
    runner.totals.merge(&runner.sim.sh.counters);
    if (!twice) return first;
    const second = run_once(runner, options);
    if (second.hash != first.hash or second.failed != first.failed) {
        runner.sim.sh.verdict.fail(.trace_mismatch, "same seed gave hashes {x} and {x}", .{
            first.hash, second.hash,
        });
        report_failure(runner);
        return .{ .hash = first.hash, .failed = .trace_mismatch };
    }
    assert(first.failed == .none and second.hash == first.hash);
    return first;
}

fn campaign(runner: *Runner, options: Options) !void {
    assert(options.seeds > 0 or options.budget_s > 0);
    const started = std.Io.Clock.awake.now(runner.io);
    std.debug.print("sim seed={d} steps={d} seeds={d} budget_s={d}\n", .{
        options.seed, options.steps, options.seeds, options.budget_s,
    });
    var done: u32 = 0;
    for (0..seeds_max) |index| {
        const seed = options.seed +% index;
        const repeat = index % repeat_every == 0;
        const main_run = try run_checked(runner, .{ .seed = seed, .steps = options.steps }, repeat);
        const fault_run = try run_checked(runner, fault_for(seed, options.steps), false);
        runner.campaign_hash = types.mix(runner.campaign_hash, main_run.hash ^ fault_run.hash);
        runner.totals.seeds += 1;
        done += 1;
        if (main_run.failed != .none or fault_run.failed != .none) runner.failures += 1;
        if (runner.failures > 0 and options.budget_s == 0) break;
        const budget_ms = @as(u64, options.budget_s) * 1000;
        if (budget_ms > 0 and elapsed_ms(runner, started) >= budget_ms) break;
        if (options.budget_s == 0 and done >= options.seeds) break;
        if (runner.failures >= 3) break;
        assert(runner.failures <= done);
    }
    const milliseconds = elapsed_ms(runner, started);
    assert(done > 0 and runner.totals.seeds == done);
    print_summary(runner, done, milliseconds);
    if (runner.failures > 0) std.process.exit(1);
    const enforce = done >= coverage_seeds_min;
    if (enforce and !coverage_ok(&runner.totals)) std.process.exit(1);
}

fn elapsed_ms(runner: *Runner, started: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(
        @max(started.durationTo(std.Io.Clock.awake.now(runner.io)).toNanoseconds(), 0),
        1000000,
    ));
}

fn print_group(comptime label: []const u8, comptime Enum: type, values: []const u64) void {
    assert(values.len == std.meta.fieldNames(Enum).len);
    std.debug.print("{s}:", .{label});
    inline for (comptime std.meta.fieldNames(Enum), 0..) |name, index| {
        std.debug.print(" {s}={d}", .{ name, values[index] });
    }
    std.debug.print("\n", .{});
    assert(label.len > 0);
}

fn print_summary(runner: *Runner, done: u32, milliseconds: u64) void {
    const totals = &runner.totals;
    assert(done > 0 and totals.seeds == done);
    print_group("kinds", types.Kind, &totals.kinds);
    print_group("errors", types.Error, &totals.errors);
    print_group("limits", types.Limit, &totals.limits);
    print_group("timeouts", types.Timeout, &totals.timeouts);
    std.debug.print("variants: {any}\n", .{totals.variants});
    std.debug.print(
        "steps={d} served={d} publications={d} reloads={d} pongs={d} builds_ok={d}\n",
        .{
            totals.steps,
            totals.served,
            totals.publications,
            totals.reloads,
            totals.pongs,
            totals.builds_ok,
        },
    );
    std.debug.print("seeds={d} failures={d} milliseconds={d} campaign_hash={x}\n", .{
        done, runner.failures, milliseconds, runner.campaign_hash,
    });
    assert(runner.failures <= done);
}

fn coverage_ok(totals: *const types.Counters) bool {
    assert(totals.seeds > 0);
    var ok = true;
    inline for (.{
        .{ "kind", types.Kind, totals.kinds },
        .{ "error", types.Error, totals.errors },
        .{ "limit", types.Limit, totals.limits },
        .{ "timeout", types.Timeout, totals.timeouts },
    }) |group| {
        inline for (comptime std.meta.fieldNames(group[1]), 0..) |name, index| {
            if (group[2][index] == 0) {
                std.debug.print("COVERAGE zero {s} counter: {s}\n", .{ group[0], name });
                ok = false;
            }
        }
    }
    for (totals.variants, 0..) |count, index| {
        if (count == 0) {
            std.debug.print("COVERAGE zero failure variant {d}\n", .{index});
            ok = false;
        }
    }
    assert(!ok or totals.steps > 0);
    return ok;
}

fn fault_text(options: serve_sim.Options, buffer: []u8) []const u8 {
    assert(buffer.len >= 16);
    const fault = options.fault orelse return "none";
    assert(fault.error_index < types.failure_variants);
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{
        @backingInt(fault.call), fault.error_index, fault.countdown,
    }) catch "none";
}

fn report_failure(runner: *Runner) void {
    const v = &runner.sim.sh.verdict;
    assert(v.failed != .none and runner.options.steps > 0);
    var fault_buffer: [32]u8 = undefined;
    std.debug.print("FAIL seed={d} steps={d} fault={s} kind={s} step={d} now_ms={d}\n  {s}\n", .{
        runner.options.seed,
        runner.options.steps,
        fault_text(runner.options, &fault_buffer),
        @tagName(v.failed),
        runner.sim.sh.step,
        runner.sim.sh.now_ms,
        v.text(),
    });
    save_trace(runner, @tagName(v.failed)) catch |err| {
        std.debug.print("saving the trace failed: {s}\n", .{@errorName(err)});
    };
    assert(v.failed != .none);
}

fn save_trace(runner: *Runner, reason: []const u8) !void {
    assert(reason.len > 0);
    const sim = runner.sim;
    var fault_buffer: [32]u8 = undefined;
    var name: [128]u8 = undefined;
    const fault = fault_text(runner.options, &fault_buffer);
    const seed = runner.options.seed;
    const path = try std.fmt.bufPrint(&name, "zig-out/sim/seed-{d}-{s}.trace", .{ seed, fault });
    var length: usize = 0;
    const head_format = "zunk-sim seed={d} steps={d} fault={s} hash={x} reason={s} step={d}\n";
    const head = try std.fmt.bufPrint(runner.text, head_format, .{
        seed, runner.options.steps, fault, sim.sh.trace.hash, reason, sim.sh.step,
    });
    length += head.len;
    const detail = try std.fmt.bufPrint(runner.text[length..], "# {s}\n", .{sim.sh.verdict.text()});
    length += detail.len;
    const trace = &sim.sh.trace;
    var index = trace.first_index();
    while (index < trace.count and length + 160 < runner.text.len) : (index += 1) {
        const record = trace.records[@intCast(index % types.trace_records_max)];
        const line_format = "{d} t={d} {s} a={d} b={d} c={d}\n";
        const line = try std.fmt.bufPrint(runner.text[length..], line_format, .{
            index, record.now_ms, @tagName(record.tag), record.a, record.b, record.c,
        });
        length += line.len;
    }
    assert(index == trace.count or length + 160 >= runner.text.len);
    try std.Io.Dir.cwd().createDirPath(runner.io, "zig-out/sim");
    const file: std.Io.Dir.WriteFileOptions = .{ .sub_path = path, .data = runner.text[0..length] };
    try std.Io.Dir.cwd().writeFile(runner.io, file);
    std.debug.print("trace saved: {s}\nreplay: zig build sim -- --replay {s}\n", .{ path, path });
    assert(length <= runner.text.len);
}

fn replay(runner: *Runner, path: []const u8) !void {
    assert(path.len > 0);
    const bytes = try std.Io.Dir.cwd().readFile(runner.io, path, runner.text);
    const line_end = std.mem.findScalar(u8, bytes, '\n') orelse return error.BadTrace;
    var options: serve_sim.Options = .{ .seed = 0, .steps = 0 };
    var recorded_hash: u64 = 0;
    var fault_field: []const u8 = "none";
    var fields = std.mem.splitScalar(u8, bytes[0..line_end], ' ');
    for (0..16) |_| {
        const field = fields.next() orelse break;
        const equals = std.mem.findScalar(u8, field, '=') orelse continue;
        const value = field[equals + 1 ..];
        const key = field[0..equals];
        if (std.mem.eql(u8, key, "seed")) options.seed = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "steps")) options.steps = try std.fmt.parseInt(u32, value, 10);
        if (std.mem.eql(u8, key, "hash")) recorded_hash = try std.fmt.parseInt(u64, value, 16);
        if (std.mem.eql(u8, key, "fault")) fault_field = value;
    }
    if (options.steps == 0) return error.BadTrace;
    if (!std.mem.eql(u8, fault_field, "none")) options = try parse_fault(options, fault_field);
    std.debug.print("replay seed={d} steps={d} fault={s}\n", .{
        options.seed, options.steps, fault_field,
    });
    assert(options.steps > 0 and options.steps <= steps_max);
    const outcome = run_once(runner, options);
    std.debug.print("replay result: {s} hash={x} recorded={x}\n", .{
        @tagName(outcome.failed), outcome.hash, recorded_hash,
    });
    if (outcome.failed != .none) report_failure(runner);
    if (outcome.hash != recorded_hash) std.process.exit(2);
    if (outcome.failed != .none) std.process.exit(1);
}

fn parse_fault(options: serve_sim.Options, text: []const u8) !serve_sim.Options {
    assert(text.len > 0 and options.steps > 0);
    var parts = std.mem.splitScalar(u8, text, '.');
    const call = try std.fmt.parseInt(u32, parts.next() orelse return error.BadTrace, 10);
    const error_index = try std.fmt.parseInt(u32, parts.next() orelse return error.BadTrace, 10);
    const countdown = try std.fmt.parseInt(u32, parts.next() orelse return error.BadTrace, 10);
    if (call >= serve_sim.fault_calls) return error.BadTrace;
    var result = options;
    result.fault = .{
        .call = @fromBackingInt(@intCast(call)),
        .error_index = error_index,
        .countdown = countdown,
    };
    assert(result.fault != null and result.steps == options.steps);
    return result;
}
