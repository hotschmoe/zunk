const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;
var stop_requested: std.atomic.Value(bool) = .init(false);
var signal_owner: ?*Signals = null;

pub fn stopping() bool {
    return stop_requested.load(.acquire);
}

pub const Signals = struct {
    previous: if (is_windows) void else [2]std.posix.Sigaction,

    pub fn init(signals: *Signals) api.Failure!void {
        assert(signal_owner == null);
        signal_owner = signals;
        errdefer signal_owner = null;
        stop_requested.store(false, .release);
        if (is_windows) {
            if (SetConsoleCtrlHandler(console_signal, .TRUE) == .FALSE) return error.System;
        } else {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = posix_signal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &action, &signals.previous[0]);
            std.posix.sigaction(.TERM, &action, &signals.previous[1]);
        }
        assert(signal_owner == signals);
    }

    pub fn deinit(signals: *Signals) void {
        assert(signal_owner == signals);
        if (is_windows) {
            if (SetConsoleCtrlHandler(console_signal, .FALSE) == .FALSE) {
                std.debug.print("serve: could not restore console handler\n", .{});
            }
        } else {
            std.posix.sigaction(.INT, &signals.previous[0], null);
            std.posix.sigaction(.TERM, &signals.previous[1], null);
        }
        signal_owner = null;
        assert(signal_owner == null);
    }
};

fn posix_signal(signal: std.posix.SIG) callconv(.c) void {
    assert(signal == .INT or signal == .TERM);
    stop_requested.store(true, .release);
}

fn console_signal(kind: u32) callconv(.winapi) windows.BOOL {
    if (kind != 0 and kind != 1) return .FALSE;
    assert(kind <= 1);
    stop_requested.store(true, .release);
    return .TRUE;
}

pub const Tree = struct {
    id: if (is_windows) windows.HANDLE else std.posix.pid_t,
    terminated: bool = false,

    pub fn init(child: *std.process.Child) api.Failure!Tree {
        assert(child.id != null);
        assert(child.stdout != null and child.stderr != null);
        if (is_windows) {
            const job = CreateJobObjectW(null, null) orelse return error.System;
            errdefer windows.CloseHandle(job);
            const limits: JobLimits = .{ .basic = .{ .flags = 0x2000 } };
            if (SetInformationJobObject(job, 9, &limits, @sizeOf(JobLimits)) == .FALSE) {
                return error.System;
            }
            if (AssignProcessToJobObject(job, child.id.?) == .FALSE) return error.System;
            if (ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.System;
            return .{ .id = job };
        }
        assert(child.id.? > 0);
        return .{ .id = child.id.? };
    }

    pub fn terminate(tree: *Tree) void {
        if (tree.terminated) return;
        if (is_windows) {
            if (TerminateJobObject(tree.id, 1) == .FALSE) {
                std.debug.print("build: job termination failed\n", .{});
            }
        } else {
            assert(tree.id > 0);
            std.posix.kill(-tree.id, .KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.debug.print("build: group termination: {s}\n", .{@errorName(err)}),
            };
        }
        tree.terminated = true;
        assert(tree.terminated);
    }

    pub fn deinit(tree: Tree) void {
        assert(tree.terminated);
        if (!is_windows) assert(tree.id > 0);
        if (is_windows) windows.CloseHandle(tree.id);
    }
};

pub fn spawn(io: std.Io, argv: []const []const u8) !std.process.Child {
    assert(argv.len > 0);
    assert(argv.len <= @import("serve_child.zig").arguments_max);
    assert(argv[0].len > 0);
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (is_windows) null else 0,
        .start_suspended = is_windows,
    });
}

const JobLimits = extern struct {
    basic: extern struct {
        process_time: i64 = 0,
        job_time: i64 = 0,
        flags: u32 = 0,
        working_min: windows.SIZE_T = 0,
        working_max: windows.SIZE_T = 0,
        processes: u32 = 0,
        affinity: windows.SIZE_T = 0,
        priority: u32 = 0,
        scheduling: u32 = 0,
    } = .{},
    counters: [6]u64 = @splat(0),
    process_memory: windows.SIZE_T = 0,
    job_memory: windows.SIZE_T = 0,
    process_peak: windows.SIZE_T = 0,
    job_peak: windows.SIZE_T = 0,
};

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateJobObjectW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn AssignProcessToJobObject(
    job: windows.HANDLE,
    process: windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateJobObject(
    job: windows.HANDLE,
    code: u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetInformationJobObject(
    job: windows.HANDLE,
    class: u32,
    information: *const JobLimits,
    length: u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) u32;
