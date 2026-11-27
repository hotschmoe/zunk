const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const http = @import("serve_http.zig");
const types = @import("serve_sim_types.zig");
const files = @import("serve_sim_files.zig");
const oracle = @import("serve_sim_oracle.zig");

pub const proxy_prefix = "/api";

pub const Config = struct {
    autoreload: bool,
    hmr: bool,
    proxy: bool,
    target: bool,
    port: u16,
};

pub const Shared = struct {
    rng: types.Rng,
    now_ms: u64 = 0,
    seq: u64 = 0,
    dispatch: u64 = 0,
    step: u32 = 0,
    verdict: types.Verdict = .{},
    counters: types.Counters = .{},
    trace: types.Trace = .{},
    tree: files.Tree = undefined,
    oracle: oracle.Oracle = .{},
    config: Config,
    script_bytes: [http.script_bytes_max]u8 = undefined,
    script_len: u16 = 0,
    open_clients: u32 = 0,
    serial: u32 = 0,

    pub fn reset(shared: *Shared, seed: u64, config: Config) void {
        shared.rng = types.Rng.init(seed);
        shared.now_ms = 0;
        shared.seq = 0;
        shared.dispatch = 0;
        shared.step = 0;
        shared.verdict = .{};
        shared.counters = .{};
        shared.trace.reset();
        shared.tree.init(&shared.rng);
        shared.oracle.reset();
        shared.config = config;
        const reload = http.reload_script(&shared.script_bytes, config.port);
        shared.script_len = @intCast(reload.len);
        shared.open_clients = 0;
        shared.serial = 0;
        assert(shared.script_len > 0 and shared.script_len <= http.script_bytes_max);
        assert(shared.verdict.failed == .none);
    }

    pub fn script(shared: *const Shared) []const u8 {
        assert(shared.script_len > 0);
        assert(shared.script_len <= http.script_bytes_max);
        return shared.script_bytes[0..shared.script_len];
    }

    pub fn note(shared: *Shared, tag: types.Tag, a: u32, b: u32, c: u8) void {
        assert(shared.seq < std.math.maxInt(u64));
        shared.seq += 1;
        shared.trace.push(shared.now_ms, tag, a, b, c);
        assert(shared.seq > 0);
    }

    pub fn fail(
        shared: *Shared,
        kind: types.Failed,
        comptime format: []const u8,
        args: anytype,
    ) void {
        assert(kind != .none);
        shared.verdict.fail(kind, format, args);
        assert(shared.verdict.failed != .none);
    }

    pub fn cap(shared: *Shared) u32 {
        return switch (shared.rng.below(8)) {
            0 => 1,
            1 => shared.rng.between(2, 16),
            2 => shared.rng.between(17, 300),
            else => 65536,
        };
    }
};
