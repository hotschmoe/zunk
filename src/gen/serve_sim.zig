const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");
const files = @import("serve_sim_files.zig");
const proxy = @import("serve_sim_proxy.zig");
const state = @import("serve_sim_state.zig");
const plan = @import("serve_sim_plan.zig");
const client = @import("serve_sim_client.zig");
const jobs_mod = @import("serve_sim_jobs.zig");

pub const never_ms = types.never_ms;
const Client = client.Client;
const Shared = state.Shared;

pub const FaultCall = enum(u8) { listen, file, watch, build, wait, log, clock };
pub const fault_calls: u32 = std.meta.fieldNames(FaultCall).len;
pub const Fault = struct { call: FaultCall, error_index: u32, countdown: u32 };
pub const Options = struct { seed: u64, steps: u32, fault: ?Fault = null };

const Socket = struct {
    used: bool = false,
    client: u8 = 0,
    upstream: bool = false,
};

const Candidate = struct {
    kind: enum(u8) { accept, ready, file, watch, build },
    index: u32 = 0,
    ready: api.Ready = undefined,
};

const candidates_max: u32 = types.handles_max + 8;
const passes_max: u32 = 1 << 20;

pub const Sim = struct {
    sh: Shared,
    clients: [types.clients_max]Client,
    sockets: [types.handles_max]Socket,
    cursor: u32,
    backlog: [types.backlog_max]u8,
    backlog_len: u32,
    jobs: jobs_mod.Jobs,
    spawn_at: u64,
    edit_at: u64,
    mutate_at: u64,
    fault: ?Fault,
    expected_exit: ?api.Failure,
    stopping: bool,
    quiet: bool,
    quiet_step: u32,
    steps_active: u32,
    listened: bool,
    last_read: ?u8,
    options: Options,

    pub fn begin(sim: *Sim, options: Options) api.Config {
        assert(options.steps > 0);
        var draw = types.Rng.init(types.splitmix(options.seed));
        const config: state.Config = .{
            .autoreload = !draw.chance(1, 8),
            .hmr = draw.chance(1, 2),
            .proxy = draw.chance(3, 4),
            .target = !draw.chance(1, 8),
            .port = @intCast(draw.between(1024, 65535)),
        };
        sim.sh.reset(options.seed, config);
        for (&sim.clients) |*c| c.phase = .free;
        sim.sockets = @splat(.{});
        sim.cursor = 0;
        sim.backlog_len = 0;
        sim.jobs.reset();
        const quick = options.fault != null;
        sim.spawn_at = sim.sh.rng.below(200);
        sim.edit_at = if (quick) sim.sh.rng.below(300) else sim.sh.rng.between(100, 3000);
        sim.mutate_at = sim.sh.rng.between(200, 4000);
        sim.fault = options.fault;
        sim.expected_exit = null;
        sim.stopping = false;
        sim.quiet = false;
        sim.quiet_step = 0;
        sim.steps_active = options.steps;
        sim.listened = false;
        sim.last_read = null;
        sim.options = options;
        assert(sim.sh.step == 0 and sim.backlog_len == 0);
        assert(!sim.stopping and sim.expected_exit == null);
        return .{
            .autoreload = config.autoreload,
            .port = config.port,
            .watch_sources = true,
            .proxy_prefix = if (config.proxy) state.proxy_prefix else null,
            .proxy_target = if (config.target) "http://127.0.0.1:9" else null,
            .hmr = config.hmr,
        };
    }

    pub fn interface(sim: *Sim) api.Interface {
        return .{ .context = sim, .vtable = &vtable };
    }

    pub fn finish(sim: *Sim, result: api.Failure!void) void {
        assert(sim.sh.verdict.step == 0 or sim.sh.verdict.step == sim.sh.step);
        const v = &sim.sh.verdict;
        if (result) |_| {
            if (sim.expected_exit) |want| {
                v.fail(.exit_unexpected, "loop returned, {s} was injected", .{@errorName(want)});
            }
        } else |err| {
            const want = sim.expected_exit orelse {
                return v.fail(.exit_unexpected, "loop failed with {s}", .{@errorName(err)});
            };
            if (err != want) {
                v.fail(.exit_unexpected, "loop returned {s}, injected {s}", .{
                    @errorName(err), @errorName(want),
                });
            }
        }
        for (&sim.sockets, 0..) |*slot, handle| {
            if (slot.used) v.fail(.connection_leaked, "handle {d} open after exit", .{handle});
        }
        sim.sh.verdict.step = sim.sh.step;
        sim.sh.verdict.now_ms = sim.sh.now_ms;
        assert(sim.sh.open_clients == 0 or sim.sh.verdict.failed != .none);
    }

    fn from(context: *anyopaque) *Sim {
        return @ptrCast(@alignCast(context));
    }

    fn fault_hit(sim: *Sim, call: FaultCall) ?api.Failure {
        const fault = &(sim.fault orelse return null);
        assert(sim.expected_exit == null);
        if (fault.call != call) return null;
        if (fault.countdown > 0) {
            fault.countdown -= 1;
            return null;
        }
        sim.fault = null;
        const picked = types.failure_from(fault.error_index % types.failure_variants);
        const err: api.Failure = if (call == .clock) error.System else picked;
        sim.expected_exit = err;
        sim.stopping = true;
        sim.sh.counters.variant(err);
        const hit: types.Error = switch (call) {
            .listen => .fault_listen,
            .file => .fault_file,
            .watch => .fault_watch,
            .build => .fault_build,
            .wait => .fault_wait,
            .log => .fault_log,
            .clock => .fault_clock,
        };
        sim.sh.counters.error_hit(hit);
        assert(sim.expected_exit != null and sim.stopping);
        return err;
    }

    fn socket(sim: *Sim, handle: u32, what: []const u8) ?*Socket {
        assert(what.len > 0);
        if (handle >= types.handles_max or !sim.sockets[handle].used) {
            sim.sh.fail(.handle_invalid, "{s} on closed handle {d}", .{ what, handle });
            return null;
        }
        assert(sim.sockets[handle].used);
        return &sim.sockets[handle];
    }

    fn alloc_handle(sim: *Sim) ?u32 {
        assert(sim.cursor <= types.handles_max);
        for (0..types.handles_max) |offset| {
            const handle: u32 = @intCast((sim.cursor + offset) % types.handles_max);
            if (sim.sockets[handle].used) continue;
            sim.cursor = handle + 1;
            assert(sim.cursor <= types.handles_max);
            return handle;
        }
        return null;
    }

    const vtable: api.Interface.VTable = .{
        .listen = listen,
        .accept = accept,
        .read = read,
        .write = write,
        .close = close,
        .connect = connect,
        .connected = connected,
        .file = file,
        .watch = watch,
        .build = build,
        .cancel_build = cancel_build,
        .wait = wait,
        .log = log,
    };

    fn listen(context: *anyopaque, port: u16) api.Failure!void {
        const sim = from(context);
        assert(port > 0);
        sim.sh.note(.listen, port, 0, 0);
        if (sim.fault_hit(.listen)) |err| return err;
        if (sim.listened or port != sim.sh.config.port) {
            sim.sh.fail(.interest_contract, "listen({d}) twice or on the wrong port", .{port});
        }
        sim.listened = true;
        assert(sim.listened);
    }

    fn accept(context: *anyopaque) api.Accept {
        const sim = from(context);
        const sh = &sim.sh;
        assert(sim.backlog_len <= types.backlog_max);
        if (sim.backlog_len == 0) return .pending;
        const index = sim.backlog[0];
        sim.backlog_len -= 1;
        const rest = sim.backlog[1..][0..sim.backlog_len];
        std.mem.copyForwards(u8, sim.backlog[0..sim.backlog_len], rest);
        const c = &sim.clients[index];
        assert(c.phase == .backlog);
        if (sh.rng.chance(1, 40)) {
            sh.counters.error_hit(.accept_failed);
            c.phase = .free;
            sh.note(.accept, index, 0, 1);
            return .failed;
        }
        const handle = sim.alloc_handle() orelse {
            c.phase = .free;
            sh.counters.error_hit(.accept_failed);
            return .failed;
        };
        sim.sockets[handle] = .{ .used = true, .client = index, .upstream = false };
        c.handle = handle;
        c.phase = .open;
        c.sock_open = true;
        c.accept_ms = sh.now_ms;
        c.accept_seq = sh.seq;
        c.reset_ms = sh.now_ms;
        c.open_before = sh.open_clients;
        c.refused = c.open_before >= api.connections_max;
        c.pubs_at_accept = sh.oracle.pubs;
        if (c.disconnect == .fin_at or c.disconnect == .rst_at) {
            c.disc_at = sh.now_ms + c.disc_delay_ms;
        }
        sh.open_clients += 1;
        if (sh.open_clients > api.connections_max + 1) {
            sh.verdict.fail(.refusal_wrong, "{d} connections accepted at once", .{sh.open_clients});
        }
        sh.note(.accept, index, handle, @intFromBool(c.refused));
        assert(c.sock_open and sim.sockets[handle].used);
        return .{ .handle = handle };
    }

    fn read(context: *anyopaque, handle: u32, buffer: []u8) api.Transfer {
        const sim = from(context);
        const s = sim.socket(handle, "read") orelse return .failed;
        assert(s.client < types.clients_max);
        const c = &sim.clients[s.client];
        if (buffer.len == 0 or buffer.len > 65536) {
            sim.sh.verdict.fail(.transfer_bounds, "read of {d} bytes", .{buffer.len});
            return .failed;
        }
        const result = if (s.upstream)
            sim.read_upstream(c, buffer)
        else
            sim.read_client(s.client, buffer);
        const code: u32 = switch (result) {
            .pending => 0,
            .count => |count| count,
            .closed => 1 << 30,
            .failed => 2 << 30,
        };
        sim.sh.note(.read, handle, code, @intFromBool(s.upstream));
        if (result == .count) assert(result.count <= buffer.len);
        return result;
    }

    fn read_client(sim: *Sim, index: u8, buffer: []u8) api.Transfer {
        assert(index < types.clients_max);
        const c = &sim.clients[index];
        sim.last_read = index;
        assert(c.sock_open);
        return c.read_bytes(&sim.sh, buffer);
    }

    fn read_upstream(sim: *Sim, c: *Client, buffer: []u8) api.Transfer {
        assert(c.up_open);
        const sh = &sim.sh;
        const up = &c.up;
        if (up.state != .live or !up.connected_called) {
            sh.verdict.fail(.connected_early, "read on an upstream that is not connected", .{});
            return .failed;
        }
        if (up.available() > 0) {
            const count = up.read(buffer, sh.cap());
            assert(count > 0 and count <= buffer.len);
            return .{ .count = count };
        }
        if (!up.finished()) return .pending;
        c.close_due = true;
        if (up.end == .eof) {
            up.eof_seen = true;
            sh.counters.error_hit(.read_closed);
            return .closed;
        }
        sh.counters.error_hit(.read_failed);
        return .failed;
    }

    fn write(context: *anyopaque, handle: u32, bytes: []const u8) api.Transfer {
        const sim = from(context);
        const s = sim.socket(handle, "write") orelse return .failed;
        assert(s.client < types.clients_max);
        const c = &sim.clients[s.client];
        if (bytes.len == 0 or bytes.len > 65536) {
            sim.sh.verdict.fail(.transfer_bounds, "write of {d} bytes", .{bytes.len});
            return .failed;
        }
        const result = if (s.upstream)
            sim.write_upstream(c, bytes)
        else
            c.write_bytes(&sim.sh, bytes);
        const code: u32 = switch (result) {
            .pending => 0,
            .count => |count| count,
            .closed => 1 << 30,
            .failed => 2 << 30,
        };
        sim.sh.note(.write, handle, code, @intFromBool(s.upstream));
        if (result == .count) assert(result.count <= bytes.len);
        return result;
    }

    fn write_upstream(sim: *Sim, c: *Client, bytes: []const u8) api.Transfer {
        assert(c.up_open and bytes.len > 0);
        const sh = &sim.sh;
        const up = &c.up;
        if (up.state != .live or !up.connected_called) {
            sh.verdict.fail(.connected_early, "write on an upstream that is not connected", .{});
            return .failed;
        }
        if (sh.rng.chance(1, 80)) {
            c.close_due = true;
            sh.counters.error_hit(.write_failed);
            return .failed;
        }
        const count = up.accept_write(&sh.rng, sh.now_ms, bytes, c.req[0..c.req_len]) orelse {
            sh.verdict.fail(.proxy_wrong, "bytes sent upstream differ from the request", .{});
            return .failed;
        };
        assert(count > 0 and count <= bytes.len);
        return .{ .count = count };
    }

    fn close(context: *anyopaque, handle: u32) void {
        const sim = from(context);
        assert(sim.sh.open_clients <= api.connections_max + 1);
        if (handle >= types.handles_max or !sim.sockets[handle].used) {
            sim.sh.verdict.fail(.close_twice, "close of handle {d}, which is not open", .{handle});
            return;
        }
        const s = &sim.sockets[handle];
        const c = &sim.clients[s.client];
        sim.sh.note(.close, handle, c.number, @intFromBool(s.upstream));
        if (s.upstream) {
            c.up.state = .none;
            c.up_open = false;
            if (!c.sock_open) c.phase = .free;
        } else if (sim.stopping) {
            c.sock_open = false;
            sim.sh.open_clients -= 1;
            if (!c.up_open) c.phase = .free;
        } else c.on_close(&sim.sh);
        s.used = false;
        assert(!sim.sockets[handle].used);
    }

    fn connect(context: *anyopaque) api.Failure!u32 {
        const sim = from(context);
        const sh = &sim.sh;
        assert(sim.listened or sh.verdict.failed != .none);
        const index = sim.last_read orelse {
            sh.verdict.fail(.connect_unowned, "connect before any request was read", .{});
            return error.Busy;
        };
        const c = &sim.clients[index];
        const proxied = c.kind == .proxy and c.sock_open and !c.up_open and c.req_read == c.req_len;
        if (!proxied) {
            sh.verdict.fail(.connect_unowned, "connect for a {s} client", .{@tagName(c.kind)});
            return error.Busy;
        }
        sh.note(.connect, index, 0, 0);
        var failure: ?api.Failure = null;
        if (!sh.config.target) failure = error.InvalidConfig else if (sh.rng.chance(1, 12)) {
            failure = types.failure_from(sh.rng.below(types.failure_variants));
        }
        if (failure) |err| {
            c.up_error = true;
            sh.counters.variant(err);
            sh.counters.error_hit(.connect_error);
            return err;
        }
        const handle = sim.alloc_handle() orelse {
            c.up_error = true;
            sh.counters.variant(error.Busy);
            return error.Busy;
        };
        const roll = sh.rng.below(100);
        const behavior: proxy.Behavior = if (roll < 70)
            .accept
        else if (roll < 85)
            .refuse
        else
            .stall;
        sim.sockets[handle] = .{ .used = true, .client = index, .upstream = true };
        c.up.begin(&sh.rng, sh.now_ms, behavior, handle);
        c.up_open = true;
        assert(c.up_open and sim.sockets[handle].upstream);
        return handle;
    }

    fn connected(context: *anyopaque, handle: u32) bool {
        const sim = from(context);
        const s = sim.socket(handle, "connected") orelse return false;
        assert(s.client < types.clients_max);
        const c = &sim.clients[s.client];
        const done = c.up.state == .live or c.up.state == .refused;
        if (!s.upstream or c.up.connected_called or !done) {
            sim.sh.fail(.connected_early, "connected({d}) early or twice", .{handle});
            return false;
        }
        c.up.connected_called = true;
        const live = c.up.state == .live;
        if (!live) {
            c.up.refused_seen = true;
            sim.sh.counters.error_hit(.connect_refused);
        }
        sim.sh.note(.connected, handle, @intFromBool(live), 0);
        assert(c.up.connected_called);
        return live;
    }

    fn file(context: *anyopaque, job: api.FileJob) api.Failure!void {
        const sim = from(context);
        assert(job.path.len <= api.path_bytes_max);
        sim.sh.note(.file, job.index, @backingInt(job.operation), 0);
        if (sim.fault_hit(.file)) |err| return err;
        sim.jobs.submit_file(&sim.sh, job);
        assert(sim.sh.verdict.failed != .none or sim.jobs.slots[job.index].outstanding);
    }

    fn watch(context: *anyopaque) api.Failure!void {
        const sim = from(context);
        assert(sim.listened);
        sim.sh.note(.watch, 0, 0, 0);
        if (sim.fault_hit(.watch)) |err| return err;
        sim.jobs.submit_watch(&sim.sh);
        assert(sim.sh.oracle.watch_out);
    }

    fn build(context: *anyopaque) api.Failure!void {
        const sim = from(context);
        assert(sim.listened);
        sim.sh.note(.build, 0, 0, 0);
        if (sim.fault_hit(.build)) |err| return err;
        sim.jobs.submit_build(&sim.sh);
        assert(sim.sh.oracle.build_out);
    }

    fn cancel_build(context: *anyopaque) void {
        const sim = from(context);
        assert(sim.listened);
        sim.sh.note(.cancel_build, 0, 0, 0);
        sim.jobs.cancel_build(&sim.sh);
        assert(!sim.sh.oracle.build_out or sim.jobs.build_due_ms != never_ms);
    }

    fn log(context: *anyopaque, message: []const u8) api.Failure!void {
        const sim = from(context);
        assert(sim.listened);
        if (message.len == 0 or message.len > api.output_bytes_max + 64) {
            sim.sh.verdict.fail(.log_contract, "log message of {d} bytes", .{message.len});
        }
        var hash: u64 = 0;
        for (message) |byte| hash = types.mix(hash, byte);
        sim.sh.note(.log, @intCast(message.len), @truncate(hash), 0);
        assert(sim.sh.seq > 0);
        if (sim.fault_hit(.log)) |err| return err;
    }

    fn wait(
        context: *anyopaque,
        interests: []const api.Interest,
        deadline: u64,
        accept_enabled: bool,
    ) api.Failure!api.Event {
        const sim = from(context);
        const sh = &sim.sh;
        assert(sim.listened and deadline >= sh.now_ms);
        assert(interests.len <= api.connections_max * 2 + 1);
        sh.dispatch += 1;
        sh.step += 1;
        sh.counters.steps += 1;
        const ahead: u32 = @truncate(deadline - sh.now_ms);
        sh.note(.wait, @intCast(interests.len), ahead, @intFromBool(accept_enabled));
        if (sim.fault_hit(.wait)) |err| return err;
        if (sim.fault_hit(.clock)) |_| {
            return .{ .now_ms = std.math.maxInt(u64) - 5, .value = .timer };
        }
        sim.validate(interests);
        if (sim.verdict_stop() or sim.settle()) {
            sim.stopping = true;
            return .{ .now_ms = sh.now_ms, .value = .stop };
        }
        return sim.next_event(interests, deadline, accept_enabled);
    }

    fn verdict_stop(sim: *const Sim) bool {
        return sim.sh.verdict.failed != .none;
    }

    fn validate(sim: *Sim, interests: []const api.Interest) void {
        const sh = &sim.sh;
        const v = &sh.verdict;
        sh.oracle.on_wait(v, sh.now_ms);
        var seen: u64 = 0;
        if (interests.len > api.connections_max * 2 + 1) {
            v.fail(.interest_contract, "{d} interests", .{interests.len});
        }
        for (interests) |interest| {
            const s = sim.socket(interest.handle, "interest") orelse continue;
            const bit = @as(u64, 1) << @intCast(interest.handle);
            if (seen & bit != 0) v.fail(.interest_contract, "handle {d} twice", .{interest.handle});
            seen |= bit;
            const upstream_token = interest.token > api.connections_max;
            if (upstream_token != s.upstream) {
                v.fail(.interest_contract, "token {d} on handle {d}", .{
                    interest.token, interest.handle,
                });
            }
            if (!s.upstream) sim.clients[s.client].update_interest(sh, interest);
        }
        for (&sim.clients) |*c| {
            if (c.phase != .open or !c.sock_open) continue;
            if (seen & (@as(u64, 1) << @intCast(c.handle)) == 0) {
                v.fail(.interest_contract, "open {s} client {d} not in interests", .{
                    @tagName(c.kind), c.number,
                });
            }
            c.check_deadline(sh);
        }
        sim.check_snapshots();
        assert(sh.oracle.tx_active <= api.snapshots_max or v.failed != .none);
        assert(seen != 0 or interests.len == 0 or v.failed != .none);
    }

    fn check_snapshots(sim: *Sim) void {
        const sh = &sim.sh;
        assert(sh.oracle.last_full_ms == never_ms or sh.oracle.last_full_ms <= sh.now_ms);
        var lower: u32 = 0;
        var upper: u32 = 0;
        for (&sim.clients) |*c| {
            if (c.phase != .open or !c.sock_open or !c.check.file) continue;
            if (c.rx.status == 200) lower += 1;
            if (c.rx.status == 200 or (c.rx.status == 0 and c.w_prev)) upper += 1;
        }
        const active = sh.oracle.tx_active;
        if (lower + active > api.snapshots_max) {
            sh.fail(.snapshot_over, "{d} snapshots held: {d} in IO, {d} serving", .{
                lower + active, active, lower,
            });
        }
        if (upper + active >= api.snapshots_max) sh.oracle.last_full_ms = sh.now_ms;
        assert(lower <= upper);
    }

    fn settle(sim: *Sim) bool {
        const sh = &sim.sh;
        assert(sim.quiet or sh.step <= sim.steps_active + 1 or sh.step == 1);
        if (sh.step > sim.steps_active and !sim.quiet) {
            sim.quiet = true;
            sim.quiet_step = sh.step;
            for (&sim.clients) |*c| {
                if (c.phase != .free) c.go_quiet();
            }
        }
        if (!sim.quiet) return false;
        if (sim.quiescent()) {
            for (&sim.clients) |*c| {
                if (c.phase == .open) c.final_check(sh);
            }
            return true;
        }
        if (sh.step - sim.quiet_step > types.quiet_steps_max) {
            sim.fail_not_quiet();
            return true;
        }
        assert(sh.step - sim.quiet_step <= types.quiet_steps_max);
        return false;
    }

    fn fail_not_quiet(sim: *Sim) void {
        assert(sim.quiet);
        const o = &sim.sh.oracle;
        for (&sim.clients) |*c| {
            if (c.phase == .free or client_idle(c)) continue;
            return sim.sh.fail(.not_quiet, "stuck {s} client {d} ({s}) up {any} due {any}", .{
                @tagName(c.kind), c.number, @tagName(c.phase), c.up_open, c.close_due,
            });
        }
        sim.sh.fail(.not_quiet, "not quiet: {s} build {any} exp {d} awaiting {any} tx {d}", .{
            sim.blocker(), o.build_out, o.exp_start_ms, o.awaiting, o.tx_active,
        });
        assert(sim.sh.verdict.failed != .none);
    }

    fn client_idle(c: *const Client) bool {
        return c.is_ws() and c.joined and !c.w_prev and !c.up_open and !c.close_due;
    }

    fn quiescent(sim: *const Sim) bool {
        return sim.blocker().len == 0;
    }

    fn blocker(sim: *const Sim) []const u8 {
        assert(sim.quiet);
        assert(sim.backlog_len <= types.backlog_max);
        if (sim.backlog_len != 0) return "backlog";
        if (!sim.sh.oracle.idle()) return "oracle";
        for (&sim.jobs.slots) |*slot| {
            if (slot.outstanding or slot.active) return "file job";
        }
        for (&sim.clients) |*c| {
            if (c.phase == .free) continue;
            if (c.phase == .backlog) return "client in backlog";
            if (c.up_open or c.close_due) return "upstream or close due";
            if (!c.is_ws() or !c.joined or c.w_prev or c.gone != .no) return @tagName(c.kind);
        }
        return "";
    }

    fn next_event(
        sim: *Sim,
        interests: []const api.Interest,
        deadline: u64,
        accept_enabled: bool,
    ) api.Event {
        const sh = &sim.sh;
        assert(interests.len <= api.connections_max * 2 + 1);
        for (0..4096) |_| {
            sim.run_world();
            var found: [candidates_max]Candidate = undefined;
            const count = sim.collect(interests, accept_enabled, &found);
            if (count > 0) return sim.deliver(found[sh.rng.below(count)]);
            var next = @min(sim.next_world_ms(), deadline);
            if (next <= sh.now_ms) return .{ .now_ms = sh.now_ms, .value = .timer };
            if (next > sh.now_ms + 1 and sh.rng.chance(1, 16)) {
                const span: u32 = @intCast(@min(next - sh.now_ms, 100000));
                next = sh.now_ms + 1 + sh.rng.below(span);
            }
            sh.now_ms = next;
            const early = sh.rng.chance(1, 16);
            if (next == deadline or early) return .{ .now_ms = next, .value = .timer };
        }
        sh.verdict.fail(.not_quiet, "no event after 4096 passes at {d}", .{sh.now_ms});
        assert(sh.verdict.failed != .none);
        return .{ .now_ms = sh.now_ms, .value = .stop };
    }

    fn collect(
        sim: *Sim,
        interests: []const api.Interest,
        accept_enabled: bool,
        out: *[candidates_max]Candidate,
    ) u32 {
        const sh = &sim.sh;
        assert(interests.len <= api.connections_max * 2 + 1);
        var count: u32 = 0;
        if (accept_enabled and sim.backlog_len > 0) {
            out[count] = .{ .kind = .accept };
            count += 1;
        }
        for (interests) |interest| {
            const s = sim.socket(interest.handle, "interest") orelse continue;
            const c = &sim.clients[s.client];
            const ready = if (s.upstream)
                sim.upstream_ready(c, interest)
            else
                c.readiness(sh, interest);
            if (ready) |value| {
                out[count] = .{ .kind = .ready, .ready = value, .index = s.client };
                count += 1;
            }
        }
        for (&sim.jobs.slots, 0..) |*slot, index| {
            if (slot.outstanding and slot.due_ms <= sh.now_ms) {
                out[count] = .{ .kind = .file, .index = @intCast(index) };
                count += 1;
            }
        }
        if (sim.jobs.watch_due_ms <= sh.now_ms) {
            out[count] = .{ .kind = .watch };
            count += 1;
        }
        if (sim.jobs.build_due_ms <= sh.now_ms) {
            out[count] = .{ .kind = .build };
            count += 1;
        }
        assert(count <= candidates_max);
        return count;
    }

    fn upstream_ready(sim: *Sim, c: *Client, interest: api.Interest) ?api.Ready {
        assert(c.up_open);
        const sh = &sim.sh;
        const up = &c.up;
        up.poll(sh.now_ms);
        var can_read = false;
        var can_write = false;
        switch (up.state) {
            .refused => can_write = interest.write or interest.read,
            .live => {
                can_write = interest.write;
                can_read = interest.read and (up.available() > 0 or up.finished());
            },
            else => return null,
        }
        const spurious = interest.read and !can_read and up.state == .live;
        if (spurious and sh.rng.chance(1, 24)) can_read = true;
        if (!can_read and !can_write) return null;
        assert(can_read or can_write);
        const closed = up.state == .refused and sh.rng.chance(1, 3);
        return .{ .token = interest.token, .read = can_read, .write = can_write, .closed = closed };
    }

    fn deliver(sim: *Sim, candidate: Candidate) api.Event {
        assert(candidate.kind != .file or candidate.index < api.snapshots_max);
        const sh = &sim.sh;
        const value: api.Event = switch (candidate.kind) {
            .accept => .{ .now_ms = sh.now_ms, .value = .accept },
            .ready => blk: {
                if (candidate.ready.closed and candidate.ready.token <= api.connections_max) {
                    sim.clients[candidate.index].close_due = true;
                    sh.counters.error_hit(.ready_closed);
                }
                break :blk .{ .now_ms = sh.now_ms, .value = .{ .ready = candidate.ready } };
            },
            .file => sim.jobs.deliver_file(sh, @intCast(candidate.index)),
            .watch => sim.jobs.deliver_watch(sh),
            .build => sim.jobs.deliver_build(sh),
        };
        sh.note(.wait, @backingInt(candidate.kind), candidate.index, 1);
        assert(value.now_ms == sh.now_ms);
        return value;
    }

    fn run_world(sim: *Sim) void {
        const sh = &sim.sh;
        assert(sh.now_ms != never_ms);
        for (0..passes_max) |_| {
            var moved = false;
            if (!sim.quiet) moved = sim.generate();
            for (&sim.clients) |*c| {
                if (c.phase == .free) continue;
                if (c.next_ms() <= sh.now_ms) {
                    c.act(sh);
                    moved = true;
                }
                if (c.up_open and sim.tick_upstream(c)) moved = true;
            }
            if (!moved) return;
        }
        sh.verdict.fail(.not_quiet, "world did not settle at {d}", .{sh.now_ms});
        assert(sh.verdict.failed != .none);
    }

    fn tick_upstream(sim: *Sim, c: *Client) bool {
        assert(c.up_open);
        const sh = &sim.sh;
        const up = &c.up;
        const before = up.state;
        up.poll(sh.now_ms);
        if (up.state != before) return true;
        if (up.state != .live or up.next_ms > sh.now_ms) return false;
        up.produce(&sh.rng, sh.now_ms);
        assert(up.next_ms == never_ms or up.next_ms >= sh.now_ms);
        return true;
    }

    fn generate(sim: *Sim) bool {
        assert(!sim.quiet);
        const sh = &sim.sh;
        var moved = false;
        if (sim.spawn_at <= sh.now_ms) {
            const burst: u32 = if (sh.rng.chance(1, 15)) 18 else 1;
            for (0..burst) |_| sim.spawn_one();
            const quiet_gap = sh.rng.chance(1, 8);
            sim.spawn_at = sh.now_ms + (if (quiet_gap)
                sh.rng.between(1500, 8000)
            else
                sh.rng.between(50, 1500));
            moved = true;
        }
        if (sim.jobs.edit_soon > 0 and sim.edit_at > sh.now_ms + 100) {
            sim.edit_at = sh.now_ms + sh.rng.below(40);
        }
        if (sim.edit_at <= sh.now_ms) {
            sim.jobs.source_dirty = true;
            sh.note(.edit, 0, 0, 0);
            const burst = sim.jobs.edit_soon > 0 or sh.rng.chance(1, 3);
            sim.jobs.edit_soon -|= 1;
            const gap = if (burst) sh.rng.between(10, 70) else sh.rng.between(2000, 60000);
            sim.edit_at = sh.now_ms + gap;
            moved = true;
        }
        if (sim.mutate_at <= sh.now_ms) {
            const id = sh.tree.mutate(&sh.rng, sh.now_ms);
            sh.note(.mutate, id, 0, 0);
            if (id == files.wasm_id) sim.jobs.dist_wasm = true;
            if (id == files.index_id) sim.jobs.dist_other = true;
            sim.mutate_at = sh.now_ms + sh.rng.between(200, 6000);
            moved = true;
        }
        assert(sim.spawn_at > sh.now_ms and sim.mutate_at > sh.now_ms);
        return moved;
    }

    fn spawn_one(sim: *Sim) void {
        assert(!sim.quiet);
        const sh = &sim.sh;
        assert(sim.backlog_len <= types.backlog_max);
        if (sim.backlog_len >= types.backlog_max) return;
        for (&sim.clients, 0..) |*c, index| {
            if (c.phase != .free) continue;
            const first = sh.serial == 0 and sh.config.autoreload;
            const kind: types.Kind = if (first) .ws_reload else plan.choose_kind(sh);
            plan.spawn(c, sh, kind, if (first) .stalled else null);
            sim.backlog[sim.backlog_len] = @intCast(index);
            sim.backlog_len += 1;
            sh.note(.spawn, c.number, @backingInt(kind), 1);
            return;
        }
    }

    fn next_world_ms(sim: *const Sim) u64 {
        assert(sim.sh.now_ms != never_ms);
        var next = sim.jobs.next_ms();
        if (!sim.quiet) next = @min(next, @min(sim.spawn_at, @min(sim.edit_at, sim.mutate_at)));
        for (&sim.clients) |*c| {
            if (c.phase == .free) continue;
            next = @min(next, c.next_ms());
            if (c.up_open) next = @min(next, c.up.next_time());
        }
        assert(next > sim.sh.now_ms);
        return next;
    }
};
