const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const files = @import("serve_files.zig");
const child_io = @import("serve_child.zig");
const process_io = @import("serve_process.zig");
const Io = std.Io;
const JobState = enum { empty, pending, working, done };
const sockets_max: u16 = api.connections_max * 2 + 2;
const transfer_bytes_max: u32 = 65536;
const FileSlot = struct {
    state: JobState = .empty,
    job: api.FileJob = undefined,
    result: api.Failure!api.FileValue = error.System,
    opened: ?Io.File = null,
};
const TransferSlot = struct {
    state: JobState,
    future: ?Io.Future(void),
    buffer: [transfer_bytes_max]u8,
    len: u32,
    result: api.Transfer,

    fn init(slot: *TransferSlot) void {
        slot.state = .empty;
        slot.future = null;
        slot.len = 0;
        slot.result = .pending;
        assert(slot.future == null);
        assert(slot.len == 0);
    }
};
const SocketSlot = struct {
    used: bool,
    stream: ?Io.net.Stream,
    connect_state: JobState,
    connect_future: ?Io.Future(void),
    input: TransferSlot,
    output: TransferSlot,

    fn init(slot: *SocketSlot) void {
        slot.used = false;
        slot.stream = null;
        slot.connect_state = .empty;
        slot.connect_future = null;
        slot.input.init();
        slot.output.init();
        assert(!slot.used);
        assert(slot.stream == null);
    }
};

pub const Options = struct {
    io: Io,
    root: []const u8,
    config: api.Config,
};

pub const Real = struct {
    options: Options,
    root: Io.Dir,
    server: ?Io.net.Server,
    proxy: ?Io.net.IpAddress,
    signals: process_io.Signals,
    mutex: Io.Mutex,
    condition: Io.Condition,
    stopped: bool,
    jobs: [api.snapshots_max]FileSlot,
    watch_state: JobState,
    watch_result: api.Failure!api.Changes,
    build_state: JobState,
    build_result: api.BuildResult,
    build_future: ?Io.Future(void),
    file_future: ?Io.Future(void),
    accept_state: JobState,
    accept_future: ?Io.Future(void),
    accepted: ?Io.net.Stream,
    sockets: [sockets_max]SocketSlot,
    watcher: files.Watcher,
    completion_cursor: u16,
    ready_cursor: u16,

    pub fn init(real: *Real, options: Options) !void {
        if (options.root.len == 0 or
            options.root.len > api.path_bytes_max or
            options.config.watch_paths.len > files.directories_max or
            options.config.watch_files.len > files.entries_max) return error.InvalidConfig;
        try child_io.validate(options.config.build_cmd);
        real.options = options;
        real.server = null;
        real.proxy = null;
        real.mutex = .init;
        real.condition = .init;
        real.stopped = false;
        for (&real.jobs) |*job| job.* = .{};
        real.watch_state = .empty;
        real.watch_result = error.System;
        real.build_state = .empty;
        real.build_future = null;
        real.file_future = null;
        real.accept_state = .empty;
        real.accept_future = null;
        real.accepted = null;
        for (&real.sockets) |*socket| socket.init();
        real.watcher.init();
        real.completion_cursor = 0;
        real.ready_cursor = 0;
        real.root = try Io.Dir.cwd().openDir(options.io, options.root, .{});
        errdefer real.root.close(options.io);
        if (options.config.proxy_target) |target| real.proxy = try proxy_address(target);
        try real.signals.init();
        errdefer real.signals.deinit();
        real.file_future = try options.io.concurrent(file_worker, .{real});
        assert(real.file_future != null);
        assert(!real.stopped);
    }

    pub fn deinit(real: *Real) void {
        const io = real.options.io;
        real.mutex.lockUncancelable(io);
        real.stopped = true;
        real.condition.broadcast(io);
        real.mutex.unlock(io);
        if (real.accept_future) |*future| future.cancel(io);
        if (real.accepted) |stream| stream.close(io);
        for (&real.sockets, 0..) |*slot, index| {
            if (slot.used) close(real, @intCast(index));
        }
        cancel_build(real);
        if (real.file_future) |*future| future.await(io);
        for (&real.jobs) |*slot| {
            if (slot.opened != null) files.close(io, &slot.opened);
        }
        if (real.server) |*server| server.deinit(io);
        real.root.close(io);
        real.signals.deinit();
        assert(real.stopped);
        assert(real.build_future == null);
    }

    pub fn interface(real: *Real) api.Interface {
        return .{ .context = real, .vtable = &.{
            .listen = listen,
            .accept = accept,
            .read = read,
            .write = write,
            .close = close,
            .connect = connect,
            .connected = connected,
            .file = submit_file,
            .watch = submit_watch,
            .build = submit_build,
            .cancel_build = cancel_build,
            .wait = wait,
            .log = log,
        } };
    }

    fn from(context: *anyopaque) *Real {
        return @ptrCast(@alignCast(context));
    }

    fn listen(context: *anyopaque, port: u16) api.Failure!void {
        const real = from(context);
        assert(real.server == null);
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        real.server = address.listen(real.options.io, .{ .reuse_address = true }) catch
            return error.System;
        assert(real.server != null);
    }

    fn accept_worker(real: *Real) void {
        const stream = real.server.?.accept(real.options.io) catch null;
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        assert(real.accept_state == .working);
        assert(real.accepted == null);
        real.accepted = stream;
        real.accept_state = .done;
        real.condition.broadcast(real.options.io);
    }

    fn accept(context: *anyopaque) api.Accept {
        const real = from(context);
        const io = real.options.io;
        real.mutex.lockUncancelable(io);
        defer real.mutex.unlock(io);
        assert(real.server != null);
        if (real.accept_state != .done) return .pending;
        real.accept_future.?.await(io);
        real.accept_future = null;
        real.accept_state = .empty;
        const stream = real.accepted orelse return .failed;
        real.accepted = null;
        for (&real.sockets, 0..) |*slot, index| {
            if (slot.used) continue;
            slot.used = true;
            slot.stream = stream;
            assert(slot.input.state == .empty and slot.output.state == .empty);
            return .{ .handle = @intCast(index) };
        }
        stream.close(io);
        return .failed;
    }

    fn read(context: *anyopaque, handle: u32, buffer: []u8) api.Transfer {
        const real = from(context);
        const socket = &real.sockets[handle];
        assert(socket.used and socket.stream != null);
        assert(buffer.len > 0 and buffer.len <= transfer_bytes_max);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        const slot = &socket.input;
        if (slot.state == .done) {
            slot.future.?.await(real.options.io);
            slot.future = null;
            slot.state = .empty;
            if (slot.result == .count) {
                const count = slot.result.count;
                assert(count <= buffer.len);
                @memcpy(buffer[0..count], slot.buffer[0..count]);
            }
            return slot.result;
        }
        if (slot.state != .empty) return .pending;
        slot.len = @intCast(buffer.len);
        slot.state = .working;
        slot.future = real.options.io.concurrent(transfer_worker, .{
            real, socket, false,
        }) catch {
            slot.state = .empty;
            return .failed;
        };
        return .pending;
    }

    fn write(context: *anyopaque, handle: u32, buffer: []const u8) api.Transfer {
        const real = from(context);
        const socket = &real.sockets[handle];
        assert(socket.used and socket.stream != null);
        assert(buffer.len > 0 and buffer.len <= transfer_bytes_max);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        const slot = &socket.output;
        if (slot.state == .done) {
            slot.future.?.await(real.options.io);
            slot.future = null;
            slot.state = .empty;
            return slot.result;
        }
        if (slot.state != .empty) return .pending;
        @memcpy(slot.buffer[0..buffer.len], buffer);
        slot.len = @intCast(buffer.len);
        slot.state = .working;
        slot.future = real.options.io.concurrent(transfer_worker, .{
            real, socket, true,
        }) catch {
            slot.state = .empty;
            return .failed;
        };
        return .pending;
    }

    fn transfer_worker(real: *Real, socket: *SocketSlot, writing: bool) void {
        const slot = if (writing) &socket.output else &socket.input;
        const io = real.options.io;
        const count = transfer(io, socket.stream.?, slot, writing);
        real.mutex.lockUncancelable(io);
        defer real.mutex.unlock(io);
        assert(slot.state == .working);
        assert(slot.len <= transfer_bytes_max);
        slot.result = count;
        slot.state = .done;
        real.condition.broadcast(io);
    }

    fn close(context: *anyopaque, handle: u32) void {
        const real = from(context);
        const slot = &real.sockets[handle];
        assert(handle < sockets_max);
        assert(slot.used);
        if (slot.connect_future) |*future| future.cancel(real.options.io);
        if (slot.input.future) |*future| future.cancel(real.options.io);
        if (slot.output.future) |*future| future.cancel(real.options.io);
        if (slot.stream) |stream| stream.close(real.options.io);
        slot.init();
    }

    fn connect(context: *anyopaque) api.Failure!u32 {
        const real = from(context);
        if (real.proxy == null) return error.InvalidConfig;
        for (&real.sockets, 0..) |*slot, index| {
            if (slot.used) continue;
            assert(slot.stream == null);
            slot.used = true;
            slot.connect_state = .working;
            slot.connect_future = real.options.io.concurrent(connect_worker, .{
                real, slot,
            }) catch {
                slot.init();
                return error.System;
            };
            assert(slot.connect_future != null);
            return @intCast(index);
        }
        return error.Busy;
    }

    fn connect_worker(real: *Real, slot: *SocketSlot) void {
        const stream = real.proxy.?.connect(real.options.io, .{ .mode = .stream }) catch null;
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        assert(slot.connect_state == .working);
        assert(slot.stream == null);
        slot.stream = stream;
        slot.connect_state = .done;
        real.condition.broadcast(real.options.io);
    }

    fn connected(context: *anyopaque, handle: u32) bool {
        const real = from(context);
        const slot = &real.sockets[handle];
        assert(slot.used and slot.connect_state == .done);
        slot.connect_future.?.await(real.options.io);
        slot.connect_future = null;
        slot.connect_state = .empty;
        assert(slot.connect_future == null);
        return slot.stream != null;
    }

    fn submit_file(context: *anyopaque, job: api.FileJob) api.Failure!void {
        const real = from(context);
        assert(job.index < api.snapshots_max);
        assert(job.buffer.len <= transfer_bytes_max);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        const slot = &real.jobs[job.index];
        if (slot.state != .empty) return error.Busy;
        slot.state = .pending;
        slot.job = job;
        real.condition.broadcast(real.options.io);
    }

    fn submit_watch(context: *anyopaque) api.Failure!void {
        const real = from(context);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        assert(!real.stopped);
        if (real.watch_state != .empty) return error.Busy;
        real.watch_state = .pending;
        real.condition.broadcast(real.options.io);
        assert(real.watch_state == .pending);
    }

    fn submit_build(context: *anyopaque) api.Failure!void {
        const real = from(context);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        assert(!real.stopped);
        if (real.build_state != .empty) return error.Busy;
        real.build_state = .working;
        real.build_future = real.options.io.concurrent(build_worker, .{real}) catch {
            real.build_state = .empty;
            return error.System;
        };
        assert(real.build_future != null);
    }

    fn build_worker(real: *Real) void {
        const result = child_io.run(real.options.io, real.options.config.build_cmd);
        real.mutex.lockUncancelable(real.options.io);
        defer real.mutex.unlock(real.options.io);
        assert(real.build_state == .working);
        assert(result.len <= api.output_bytes_max);
        real.build_result = result;
        real.build_state = .done;
        real.condition.broadcast(real.options.io);
    }

    fn cancel_build(context: *anyopaque) void {
        const real = from(context);
        if (real.build_future) |*future| future.cancel(real.options.io);
        real.build_future = null;
        assert(real.build_future == null);
    }

    fn file_worker(real: *Real) void {
        const io = real.options.io;
        assert(real.options.root.len > 0);
        for (0..std.math.maxInt(u64)) |_| {
            real.mutex.lockUncancelable(io);
            if (real.stopped) {
                real.mutex.unlock(io);
                return;
            }
            if (real.work_files()) continue;
            real.condition.waitUncancelable(io, &real.mutex);
            real.mutex.unlock(io);
        }
        @panic("file worker lifetime exhausted");
    }

    fn work_files(real: *Real) bool {
        const io = real.options.io;
        if (real.watch_state == .pending) {
            real.watch_state = .working;
            real.mutex.unlock(io);
            const result = real.watcher.poll(io, real.options.root, real.options.config);
            real.mutex.lockUncancelable(io);
            assert(real.watch_state == .working);
            real.watch_result = result;
            real.watch_state = .done;
            real.condition.broadcast(io);
            real.mutex.unlock(io);
            return true;
        }
        for (&real.jobs) |*slot| {
            if (slot.state != .pending) continue;
            assert(slot.job.index < api.snapshots_max);
            const job = slot.job;
            slot.state = .working;
            real.mutex.unlock(io);
            const result = files.perform(io, real.root, job, &slot.opened);
            real.mutex.lockUncancelable(io);
            assert(slot.state == .working);
            slot.result = result;
            slot.state = .done;
            real.condition.broadcast(io);
            real.mutex.unlock(io);
            return true;
        }
        return false;
    }

    fn completion(real: *Real) ?api.Event {
        assert(real.completion_cursor < api.snapshots_max + 2);
        const now = real.now_ms();
        for (0..api.snapshots_max + 2) |_| {
            const index = real.completion_cursor;
            real.completion_cursor = (index + 1) % (api.snapshots_max + 2);
            if (index < api.snapshots_max) {
                const slot = &real.jobs[index];
                if (slot.state != .done) continue;
                assert(slot.job.index == index);
                slot.state = .empty;
                return .{ .now_ms = now, .value = .{ .file = .{
                    .index = index,
                    .result = slot.result,
                } } };
            }
            if (index == api.snapshots_max and real.watch_state == .done) {
                real.watch_state = .empty;
                return .{ .now_ms = now, .value = .{ .changes = real.watch_result } };
            }
            if (index == api.snapshots_max + 1 and real.build_state == .done) {
                if (real.build_future) |*future| future.await(real.options.io);
                real.build_future = null;
                real.build_state = .empty;
                return .{ .now_ms = now, .value = .{ .build = real.build_result } };
            }
        }
        return null;
    }

    fn wait(
        context: *anyopaque,
        interests: []const api.Interest,
        deadline: u64,
        accept_enabled: bool,
    ) api.Failure!api.Event {
        const real = from(context);
        const io = real.options.io;
        assert(interests.len <= api.connections_max * 2 + 1);
        assert(real.server != null);
        real.mutex.lockUncancelable(io);
        defer real.mutex.unlock(io);
        if (accept_enabled and real.accept_state == .empty) {
            real.accept_state = .working;
            real.accept_future = io.concurrent(accept_worker, .{real}) catch {
                real.accept_state = .empty;
                return error.System;
            };
        }
        return real.wait_mailbox(interests, deadline, accept_enabled);
    }

    fn wait_mailbox(
        real: *Real,
        interests: []const api.Interest,
        deadline: u64,
        accept_enabled: bool,
    ) api.Failure!api.Event {
        assert(!accept_enabled or real.accept_state != .empty);
        assert(real.ready_cursor < api.connections_max * 2 + 2);
        const io = real.options.io;
        for (0..std.math.maxInt(u32)) |_| {
            if (process_io.stopping()) return .{ .now_ms = real.now_ms(), .value = .stop };
            if (real.completion()) |event| return event;
            if (real.ready_event(interests, accept_enabled)) |event| return event;
            const now = real.now_ms();
            if (now >= deadline) return .{ .now_ms = now, .value = .timer };
            real.condition.waitTimeout(io, &real.mutex, .{ .duration = .{
                .raw = .fromMilliseconds(@min(deadline - now, 50)),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.System,
            };
        }
        return error.System;
    }

    fn ready_event(real: *Real, interests: []const api.Interest, accepting: bool) ?api.Event {
        const count: u16 = @intCast(interests.len + 1);
        assert(count > 0);
        assert(count <= api.connections_max * 2 + 2);
        for (0..count) |_| {
            const index = real.ready_cursor % count;
            real.ready_cursor = (index + 1) % count;
            if (index == 0) {
                if (accepting and real.accept_state == .done) {
                    return .{ .now_ms = real.now_ms(), .value = .accept };
                }
                continue;
            }
            const interest = interests[index - 1];
            const slot = &real.sockets[interest.handle];
            if (slot.connect_state == .working) continue;
            const reading = interest.read and slot.input.state != .working;
            const writing = interest.write and slot.output.state != .working;
            if (!reading and !writing) continue;
            return .{ .now_ms = real.now_ms(), .value = .{ .ready = .{
                .token = interest.token,
                .read = reading,
                .write = writing,
                .closed = false,
            } } };
        }
        return null;
    }

    fn now_ms(real: *Real) u64 {
        return @intCast(@divTrunc(Io.Clock.awake.now(real.options.io).nanoseconds, 1000000));
    }

    fn log(context: *anyopaque, message: []const u8) api.Failure!void {
        const real = from(context);
        assert(message.len <= api.output_bytes_max + 64);
        assert(message.len > 0);
        var buffer: [api.output_bytes_max + 65]u8 = undefined;
        var output = Io.File.stderr().writer(real.options.io, &buffer);
        output.interface.writeAll(message) catch return error.System;
        output.interface.writeByte(10) catch return error.System;
        output.interface.flush() catch return error.System;
    }
};

fn transfer(io: Io, stream: Io.net.Stream, slot: *TransferSlot, writing: bool) api.Transfer {
    assert(slot.len > 0);
    assert(slot.len <= transfer_bytes_max);
    if (writing) {
        var writer = stream.writer(io, &.{});
        writer.interface.writeAll(slot.buffer[0..slot.len]) catch return .failed;
        return .{ .count = slot.len };
    }
    var vectors = [_][]u8{slot.buffer[0..slot.len]};
    const count = stream.read(io, &vectors) catch return .failed;
    return if (count == 0) .closed else .{ .count = @intCast(count) };
}

fn proxy_address(target: []const u8) api.Failure!Io.net.IpAddress {
    if (!std.mem.startsWith(u8, target, "http://")) return error.InvalidConfig;
    const host = std.mem.trimEnd(u8, target[7..], "/");
    if (std.mem.startsWith(u8, host, "localhost:")) {
        const port = std.fmt.parseInt(u16, host[10..], 10) catch return error.InvalidConfig;
        return .{ .ip4 = .loopback(port) };
    }
    var address = Io.net.IpAddress.parseLiteral(host) catch return error.InvalidConfig;
    if (address.getPort() == 0) address.setPort(80);
    assert(address.getPort() > 0);
    assert(address == .ip4 or address == .ip6);
    return address;
}
