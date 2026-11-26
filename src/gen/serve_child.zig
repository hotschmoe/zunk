const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const process_io = @import("serve_process.zig");
const Io = std.Io;
pub const arguments_max: u16 = 32;
pub const argument_bytes_max: u32 = 8192;
const output_turns_max: u64 = std.math.maxInt(u32);
const Capture = struct {
    mutex: Io.Mutex = .init,
    result: api.BuildResult = .{},
};
const Waiter = struct {
    event: Io.Event = .unset,
    term: std.process.Child.WaitError!std.process.Child.Term = error.AccessDenied,
};

pub fn validate(argv: []const []const u8) api.Failure!void {
    if (argv.len == 0 or argv.len > arguments_max) return error.InvalidConfig;
    if (argv[0].len == 0) return error.InvalidConfig;
    var bytes: u32 = 0;
    for (argv) |argument| {
        if (argument.len + 1 > argument_bytes_max - bytes) return error.InvalidConfig;
        if (std.mem.findScalar(u8, argument, 0) != null) return error.InvalidConfig;
        bytes += @intCast(argument.len + 1);
    }
    assert(bytes <= argument_bytes_max);
    assert(argv.len <= arguments_max);
}

pub fn run(io: Io, argv: []const []const u8) api.BuildResult {
    assert(argv.len > 0);
    assert(argv.len <= arguments_max);
    var child = process_io.spawn(io, argv) catch |err| return failure(err);
    defer child.kill(io);
    var tree = process_io.Tree.init(&child) catch |err| return failure(err);
    defer tree.deinit();
    defer tree.terminate();
    const output = child.stdout.?;
    const errors = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer output.close(io);
    defer errors.close(io);
    var capture: Capture = .{};
    var stdout = io.concurrent(drain, .{ io, output, &capture }) catch |err| return failure(err);
    defer stdout.cancel(io);
    var stderr = io.concurrent(drain, .{ io, errors, &capture }) catch |err| return failure(err);
    defer stderr.cancel(io);
    var waiter: Waiter = .{};
    var future = io.concurrent(wait_child, .{ io, &child, &waiter }) catch |err|
        return failure(err);
    defer future.await(io);
    waiter.event.wait(io) catch {
        tree.terminate();
        future.await(io);
        stdout.cancel(io);
        stderr.cancel(io);
        capture.result.cancelled = true;
        return capture.result;
    };
    future.await(io);
    tree.terminate();
    stdout.await(io);
    stderr.await(io);
    const term = waiter.term catch |err| return failure(err);
    capture.result.success = term.success() and !capture.result.io_failed;
    assert(capture.result.len <= api.output_bytes_max);
    return capture.result;
}

fn wait_child(io: Io, child: *std.process.Child, waiter: *Waiter) void {
    assert(child.id != null);
    assert(child.stdout == null and child.stderr == null);
    waiter.term = child.wait(io);
    waiter.event.set(io);
}

fn drain(io: Io, file: Io.File, capture: *Capture) void {
    var buffer: [4096]u8 = undefined;
    for (0..output_turns_max) |_| {
        var vectors = [_][]u8{&buffer};
        const count = file.readStreaming(io, &vectors) catch |err| {
            if (err != error.Canceled and err != error.EndOfStream) {
                capture.mutex.lockUncancelable(io);
                capture.result.io_failed = true;
                capture.mutex.unlock(io);
            }
            return;
        };
        if (count == 0) return;
        assert(count <= buffer.len);
        capture.mutex.lockUncancelable(io);
        const result = &capture.result;
        const keep = @min(count, api.output_bytes_max - result.len);
        @memcpy(result.output[result.len..][0..keep], buffer[0..keep]);
        result.len += @intCast(keep);
        result.truncated = result.truncated or keep != count;
        assert(result.len <= api.output_bytes_max);
        capture.mutex.unlock(io);
    }
    capture.mutex.lockUncancelable(io);
    capture.result.io_failed = true;
    capture.mutex.unlock(io);
}

fn failure(err: anyerror) api.BuildResult {
    var result: api.BuildResult = .{};
    const message = std.fmt.bufPrint(
        &result.output,
        "build IO: {s}",
        .{@errorName(err)},
    ) catch @panic("build diagnostic bound");
    result.len = @intCast(message.len);
    assert(result.len <= api.output_bytes_max);
    assert(!result.success);
    return result;
}
