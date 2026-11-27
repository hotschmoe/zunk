const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");

pub const handles_max: u32 = 34;
pub const clients_max: u32 = 40;
pub const backlog_max: u32 = 8;
pub const request_buffer_max: u32 = 8192;
pub const never_ms: u64 = std.math.maxInt(u64);
pub const quiet_steps_max: u32 = 4096;
pub const trace_records_max: u32 = 1 << 14;
pub const detail_bytes_max: u32 = 192;
pub const failure_variants: u32 = 8;

pub const Kind = enum(u8) {
    static_file,
    index_root,
    spa_fallback,
    favicon,
    missing_file,
    path_edge,
    big_file,
    traversal,
    bad_request,
    long_path,
    long_path_open,
    header_flood,
    header_edge,
    stalled_request,
    proxy,
    ws_reload,
    ws_bad_handshake,
};

pub const Error = enum(u8) {
    accept_failed,
    read_closed,
    read_failed,
    write_closed,
    write_failed,
    ready_closed,
    connect_error,
    connect_refused,
    file_open_missing,
    file_open_system,
    file_read_system,
    file_verify_changed,
    file_verify_system,
    watch_error,
    build_failed,
    build_crashed,
    build_cancelled,
    fault_listen,
    fault_file,
    fault_watch,
    fault_build,
    fault_wait,
    fault_log,
    fault_clock,
};

pub const Limit = enum(u8) {
    connection,
    uri,
    header,
    file,
    snapshot,
    ws_frame,
    pong_queue,
    output_truncated,
    watch_scan,
    path_edge_ok,
    header_edge_ok,
    build_busy,
};

pub const Timeout = enum(u8) {
    request_30s,
    response_30s,
    ws_frame_30s,
    proxy_30s,
    build_120s,
    debounce_coalesced,
    owner_gone,
};

pub const Counters = struct {
    kinds: [std.meta.fieldNames(Kind).len]u64 = @splat(0),
    errors: [std.meta.fieldNames(Error).len]u64 = @splat(0),
    limits: [std.meta.fieldNames(Limit).len]u64 = @splat(0),
    timeouts: [std.meta.fieldNames(Timeout).len]u64 = @splat(0),
    variants: [failure_variants]u64 = @splat(0),
    steps: u64 = 0,
    served: u64 = 0,
    publications: u64 = 0,
    reloads: u64 = 0,
    pongs: u64 = 0,
    builds_ok: u64 = 0,
    seeds: u64 = 0,

    pub fn kind(counters: *Counters, value: Kind) void {
        counters.kinds[@backingInt(value)] += 1;
    }

    pub fn error_hit(counters: *Counters, value: Error) void {
        counters.errors[@backingInt(value)] += 1;
    }

    pub fn limit(counters: *Counters, value: Limit) void {
        counters.limits[@backingInt(value)] += 1;
    }

    pub fn timeout(counters: *Counters, value: Timeout) void {
        counters.timeouts[@backingInt(value)] += 1;
    }

    pub fn variant(counters: *Counters, err: api.Failure) void {
        counters.variants[failure_index(err)] += 1;
    }

    pub fn merge(counters: *Counters, other: *const Counters) void {
        assert(@intFromPtr(counters) != @intFromPtr(other));
        inline for (.{ "kinds", "errors", "limits", "timeouts", "variants" }) |name| {
            for (&@field(counters, name), @field(other, name)) |*sum, value| sum.* += value;
        }
        inline for (.{
            "steps", "served", "publications", "reloads", "pongs", "builds_ok", "seeds",
        }) |name| @field(counters, name) += @field(other, name);
        assert(counters.steps >= other.steps);
    }
};

pub fn failure_index(err: api.Failure) u32 {
    const index: u32 = switch (err) {
        error.System => 0,
        error.NotFound => 1,
        error.Changed => 2,
        error.FileLimit => 3,
        error.PathLimit => 4,
        error.WatchLimit => 5,
        error.Busy => 6,
        error.InvalidConfig => 7,
    };
    assert(index < failure_variants);
    assert(failures_all[index] == err);
    return index;
}

const failures_all = [failure_variants]api.Failure{
    error.System,
    error.NotFound,
    error.Changed,
    error.FileLimit,
    error.PathLimit,
    error.WatchLimit,
    error.Busy,
    error.InvalidConfig,
};

pub fn failure_from(index: u32) api.Failure {
    return failures_all[index];
}

pub const Failed = enum(u8) {
    none,
    handle_invalid,
    transfer_bounds,
    close_twice,
    connect_unowned,
    connected_early,
    file_contract,
    build_contract,
    watch_contract,
    cancel_idle,
    log_contract,
    interest_contract,
    connection_leaked,
    left_open,
    response_malformed,
    response_wrong,
    response_incomplete,
    file_bytes_wrong,
    refusal_wrong,
    snapshot_over,
    timeout_early,
    timeout_late,
    cancel_early,
    cancel_late,
    debounce_early,
    debounce_late,
    reload_extra,
    reload_missing,
    status_wrong,
    pong_wrong,
    proxy_wrong,
    websocket_wrong,
    not_quiet,
    exit_unexpected,
    trace_mismatch,
};

pub const Verdict = struct {
    failed: Failed = .none,
    step: u32 = 0,
    now_ms: u64 = 0,
    detail: [detail_bytes_max]u8 = undefined,
    detail_len: u8 = 0,

    pub fn fail(verdict: *Verdict, kind: Failed, comptime format: []const u8, args: anytype) void {
        assert(kind != .none);
        if (verdict.failed != .none) return;
        verdict.failed = kind;
        const message = std.fmt.bufPrint(&verdict.detail, format, args) catch verdict.detail[0..0];
        verdict.detail_len = @intCast(message.len);
        assert(verdict.detail_len <= detail_bytes_max);
    }

    pub fn text(verdict: *const Verdict) []const u8 {
        assert(verdict.detail_len <= detail_bytes_max);
        assert(verdict.failed != .none or verdict.detail_len == 0);
        return verdict.detail[0..verdict.detail_len];
    }
};

pub const Rng = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Rng {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn below(rng: *Rng, limit: u32) u32 {
        assert(limit > 0);
        const value = rng.prng.random().uintLessThan(u32, limit);
        assert(value < limit);
        return value;
    }

    pub fn between(rng: *Rng, low: u32, high: u32) u32 {
        assert(low <= high);
        const value = low + rng.below(high - low + 1);
        assert(value >= low and value <= high);
        return value;
    }

    pub fn chance(rng: *Rng, numerator: u32, denominator: u32) bool {
        assert(numerator <= denominator);
        assert(denominator > 0);
        return rng.below(denominator) < numerator;
    }

    pub fn word(rng: *Rng) u64 {
        return rng.prng.random().int(u64);
    }
};

pub fn mix(state: u64, value: u64) u64 {
    var result = (state ^ value) *% 0x9e3779b97f4a7c15;
    result ^= result >> 32;
    assert(result != 0 or state == value);
    assert(result == 0 or state != value);
    return result;
}

fn scramble(z: u64, shift: u6, factor: u64) u64 {
    return (z ^ (z >> shift)) *% factor;
}

fn finalize(z: u64) u64 {
    return z ^ (z >> 31);
}

pub fn splitmix(value: u64) u64 {
    return finalize(scramble(
        scramble(value +% 0x9e3779b97f4a7c15, 30, 0xbf58476d1ce4e5b9),
        27,
        0x94d049bb133111eb,
    ));
}

pub const Tag = enum(u8) {
    listen,
    accept,
    read,
    write,
    close,
    connect,
    connected,
    file,
    watch,
    build,
    cancel_build,
    wait,
    log,
    spawn,
    mutate,
    edit,
    verdict,
};

pub const Record = struct {
    now_ms: u64,
    a: u32,
    b: u32,
    tag: Tag,
    c: u8,
};

pub const Trace = struct {
    records: [trace_records_max]Record = undefined,
    count: u64 = 0,
    hash: u64 = 0,

    pub fn reset(trace: *Trace) void {
        trace.count = 0;
        trace.hash = 0x243f6a8885a308d3;
        assert(trace.count == 0);
        assert(trace.hash != 0);
    }

    pub fn push(trace: *Trace, now_ms: u64, tag: Tag, a: u32, b: u32, c: u8) void {
        const record: Record = .{ .now_ms = now_ms, .a = a, .b = b, .tag = tag, .c = c };
        const slot: usize = @intCast(trace.count % trace_records_max);
        trace.records[slot] = record;
        trace.count += 1;
        assert(trace.records[slot].tag == tag);
        var state = mix(trace.hash, now_ms);
        state = mix(state, (@as(u64, a) << 32) | b);
        state = mix(state, (@as(u64, @backingInt(tag)) << 8) | c);
        trace.hash = state;
        assert(trace.count > 0);
    }

    pub fn first_index(trace: *const Trace) u64 {
        return trace.count -| trace_records_max;
    }
};
