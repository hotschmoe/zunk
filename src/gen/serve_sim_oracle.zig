const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");

const never_ms = types.never_ms;

pub const Observation = struct { ok: bool, source: bool, dist: bool };

pub const Oracle = struct {
    build_out: bool = false,
    build_start_ms: u64 = 0,
    cancel_called: bool = false,
    build_pending: bool = false,
    last_busy_ms: u64 = never_ms,
    exp_start_ms: u64 = never_ms,
    last_failed: bool = false,
    awaiting: bool = false,
    awaiting_seq: u64 = 0,
    watch_out: bool = false,
    watch_seq: u64 = 0,
    pubs: u32 = 0,
    builds: u32 = 0,
    tx_active: u32 = 0,
    last_full_ms: u64 = never_ms,
    changed_inject_ms: u64 = never_ms,
    stall_inject_ms: u64 = never_ms,
    system_inject_ms: u64 = never_ms,

    pub fn reset(o: *Oracle) void {
        o.* = .{};
    }

    pub fn build_call(o: *Oracle, v: *types.Verdict, now_ms: u64) void {
        assert(o.last_busy_ms == never_ms or o.last_busy_ms <= now_ms);
        if (o.build_out) v.fail(.build_contract, "build submitted while one is running", .{});
        if (o.exp_start_ms == never_ms) {
            v.fail(.debounce_early, "build at {d} with no observed source change", .{now_ms});
        } else if (now_ms < o.exp_start_ms) {
            v.fail(.debounce_early, "build at {d}, debounce ends {d}", .{ now_ms, o.exp_start_ms });
        } else if (now_ms > o.exp_start_ms) {
            v.fail(.debounce_late, "build at {d}, debounce ended {d}", .{ now_ms, o.exp_start_ms });
        }
        o.build_out = true;
        o.build_start_ms = now_ms;
        o.cancel_called = false;
        o.build_pending = false;
        o.exp_start_ms = never_ms;
        o.awaiting = false;
        o.last_busy_ms = now_ms;
        assert(o.build_out and o.exp_start_ms == never_ms);
    }

    pub fn cancel_call(o: *Oracle, v: *types.Verdict, now_ms: u64) void {
        assert(!o.build_out or o.build_start_ms <= now_ms);
        if (!o.build_out) {
            v.fail(.cancel_idle, "cancel_build with no build running at {d}", .{now_ms});
            return;
        }
        if (o.cancel_called) v.fail(.build_contract, "second cancel_build for one build", .{});
        const due = o.build_start_ms + api.build_timeout_ms;
        if (now_ms < due) {
            v.fail(.cancel_early, "cancel at {d}, build began {d}", .{ now_ms, o.build_start_ms });
        } else if (now_ms > due) {
            v.fail(.cancel_late, "cancel at {d}, due {d}", .{ now_ms, due });
        }
        o.cancel_called = true;
        assert(o.cancel_called and o.build_out);
    }

    pub fn on_wait(o: *Oracle, v: *types.Verdict, now_ms: u64) void {
        assert(o.last_busy_ms == never_ms or o.last_busy_ms <= now_ms);
        if (o.build_out) {
            o.last_busy_ms = now_ms;
            const due = o.build_start_ms + api.build_timeout_ms;
            if (!o.cancel_called and now_ms >= due) {
                v.fail(.cancel_late, "no cancel by {d}, began {d}", .{ now_ms, o.build_start_ms });
            }
        } else if (o.exp_start_ms != never_ms and now_ms >= o.exp_start_ms) {
            v.fail(.debounce_late, "no build by {d}, due {d}", .{ now_ms, o.exp_start_ms });
        }
        assert(!o.build_out or o.last_busy_ms == now_ms);
    }

    pub fn build_event(o: *Oracle, now_ms: u64, seq: u64, success: bool) void {
        assert(o.build_out);
        o.build_out = false;
        o.last_busy_ms = now_ms;
        o.builds += 1;
        const pending = o.build_pending;
        o.build_pending = false;
        o.last_failed = !success;
        o.awaiting = success and !pending;
        o.awaiting_seq = seq;
        if (pending) o.exp_start_ms = now_ms;
        assert(!o.build_out and !(o.awaiting and pending));
    }

    pub fn watch_call(o: *Oracle, v: *types.Verdict, seq: u64) void {
        assert(seq >= o.watch_seq);
        if (o.watch_out) v.fail(.watch_contract, "watch submitted while one is outstanding", .{});
        o.watch_out = true;
        o.watch_seq = seq;
        assert(o.watch_out);
    }

    pub fn watch_event(
        o: *Oracle,
        c: *types.Counters,
        now_ms: u64,
        obs: Observation,
    ) bool {
        assert(o.watch_out);
        o.watch_out = false;
        if (!obs.ok) return false;
        if (obs.source) {
            if (o.build_out) {
                o.build_pending = true;
            } else {
                if (o.exp_start_ms != never_ms) c.timeout(.debounce_coalesced);
                o.exp_start_ms = now_ms + api.debounce_ms;
            }
            o.awaiting = false;
            return false;
        }
        const fresh = o.watch_seq > o.awaiting_seq;
        const external = obs.dist and !o.build_out and !o.last_failed;
        const publish = if (o.awaiting) fresh else external;
        if (o.awaiting and fresh) o.awaiting = false;
        if (publish) o.pubs += 1;
        assert(!(o.awaiting and publish));
        return publish;
    }

    pub fn tx_begin(o: *Oracle, v: *types.Verdict, now_ms: u64) void {
        assert(o.last_full_ms == never_ms or o.last_full_ms <= now_ms);
        o.tx_active += 1;
        if (o.tx_active > api.snapshots_max) {
            v.fail(.snapshot_over, "{d} snapshots outstanding", .{o.tx_active});
        }
        if (o.tx_active >= api.snapshots_max) o.last_full_ms = now_ms;
        assert(o.tx_active > 0);
    }

    pub fn tx_end(o: *Oracle) void {
        assert(o.tx_active > 0);
        o.tx_active -= 1;
        assert(o.tx_active < api.snapshots_max);
    }

    pub fn build_busy_since(o: *const Oracle, since_ms: u64) bool {
        return o.build_out or (o.last_busy_ms != never_ms and o.last_busy_ms >= since_ms);
    }

    pub fn full_since(o: *const Oracle, since_ms: u64) bool {
        return o.tx_active >= api.snapshots_max or
            (o.last_full_ms != never_ms and o.last_full_ms >= since_ms);
    }

    pub fn idle(o: *const Oracle) bool {
        return !o.build_out and o.exp_start_ms == never_ms and !o.awaiting and o.tx_active == 0;
    }
};
