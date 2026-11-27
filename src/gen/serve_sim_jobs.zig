const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");
const files = @import("serve_sim_files.zig");
const state = @import("serve_sim_state.zig");
const oracle = @import("serve_sim_oracle.zig");

const never_ms = types.never_ms;
const Shared = state.Shared;

pub const BuildKind = enum(u8) { success, failed, failed_empty, crashed, truncated, hang };

pub const FileSlot = struct {
    active: bool = false,
    outstanding: bool = false,
    handle_open: bool = false,
    job: api.FileJob = undefined,
    due_ms: u64 = never_ms,
};

fn end_tx(sh: *Shared, slot: *FileSlot) void {
    assert(slot.active);
    slot.active = false;
    slot.handle_open = false;
    sh.oracle.tx_end();
    assert(!slot.active and !slot.handle_open);
}

pub const Jobs = struct {
    slots: [api.snapshots_max]FileSlot = @splat(.{}),
    watch_due_ms: u64 = never_ms,
    build_due_ms: u64 = never_ms,
    build_kind: BuildKind = .success,
    build_cancelled: bool = false,
    source_dirty: bool = false,
    dist_wasm: bool = false,
    dist_other: bool = false,
    edit_soon: u32 = 0,

    pub fn reset(jobs: *Jobs) void {
        jobs.* = .{};
    }

    pub fn next_ms(jobs: *const Jobs) u64 {
        assert(!jobs.build_cancelled or jobs.build_due_ms != never_ms);
        var next = @min(jobs.watch_due_ms, jobs.build_due_ms);
        for (&jobs.slots) |*slot| {
            assert(!slot.outstanding or slot.due_ms != never_ms);
            if (slot.outstanding) next = @min(next, slot.due_ms);
        }
        return next;
    }

    fn delay(sh: *Shared, stall: bool) u64 {
        const roll = sh.rng.below(1000);
        const value: u64 = if (stall and roll < 4)
            sh.rng.between(31000, 40000)
        else if (roll < 700)
            sh.rng.below(4)
        else if (roll < 960)
            sh.rng.between(4, 200)
        else
            sh.rng.between(200, 3000);
        if (value > api.connection_timeout_ms) sh.oracle.stall_inject_ms = sh.now_ms;
        assert(value < 40001);
        assert(stall or value <= 3000);
        return value;
    }

    pub fn submit_file(jobs: *Jobs, sh: *Shared, job: api.FileJob) void {
        assert(job.buffer.len <= 65536);
        const v = &sh.verdict;
        if (job.index >= api.snapshots_max) {
            return v.fail(.file_contract, "file index {d}", .{job.index});
        }
        const slot = &jobs.slots[job.index];
        if (slot.outstanding) {
            return v.fail(.file_contract, "file index {d} has a job in flight", .{job.index});
        }
        const reading = job.operation == .read;
        if (reading and job.buffer.len == 0) v.fail(.file_contract, "empty read buffer", .{});
        switch (job.operation) {
            .open => {
                if (slot.handle_open or slot.active) {
                    v.fail(.file_contract, "open over a live snapshot {d}", .{job.index});
                }
                slot.active = true;
                sh.oracle.tx_begin(v, sh.now_ms);
            },
            else => if (!slot.handle_open) {
                v.fail(.file_contract, "{s} without a handle", .{@tagName(job.operation)});
            },
        }
        slot.job = job;
        assert(job.index < api.snapshots_max);
        slot.outstanding = true;
        slot.due_ms = sh.now_ms + delay(sh, job.operation == .open);
        assert(slot.outstanding and slot.due_ms >= sh.now_ms);
    }

    pub fn deliver_file(jobs: *Jobs, sh: *Shared, index: u16) api.Event {
        const slot = &jobs.slots[index];
        assert(slot.outstanding and slot.due_ms <= sh.now_ms);
        slot.outstanding = false;
        slot.due_ms = never_ms;
        const job = slot.job;
        assert(job.index == index);
        const value: api.Failure!api.FileValue = switch (job.operation) {
            .open => jobs.file_open(sh, index, job),
            .read => jobs.file_read(sh, index, job),
            .verify_close => jobs.file_verify(sh, index),
            .close => closed: {
                sh.tree.close(index);
                end_tx(sh, slot);
                break :closed .closed;
            },
        };
        if (value) |_| {} else |err| sh.counters.variant(err);
        assert(!slot.outstanding);
        return .{ .now_ms = sh.now_ms, .value = .{ .file = .{ .index = index, .result = value } } };
    }

    fn file_open(jobs: *Jobs, sh: *Shared, index: u16, job: api.FileJob) api.Failure!api.FileValue {
        const slot = &jobs.slots[index];
        assert(slot.active and !slot.handle_open);
        const injected: ?api.Failure = if (sh.rng.chance(1, 50)) error.System else null;
        const result: api.Failure!api.Metadata = if (injected) |err|
            err
        else
            sh.tree.open(index, job.path.slice());
        if (result) |metadata| {
            slot.handle_open = true;
            return .{ .opened = metadata };
        } else |err| {
            end_tx(sh, slot);
            if (injected != null) {
                sh.counters.error_hit(.file_open_system);
                sh.oracle.system_inject_ms = sh.now_ms;
            } else sh.counters.error_hit(.file_open_missing);
            return err;
        }
    }

    fn file_read(jobs: *Jobs, sh: *Shared, index: u16, job: api.FileJob) api.Failure!api.FileValue {
        assert(jobs.slots[index].handle_open);
        if (sh.rng.chance(1, 80)) {
            sh.counters.error_hit(.file_read_system);
            sh.oracle.system_inject_ms = sh.now_ms;
            return error.System;
        }
        const size: u32 = @intCast(job.buffer.len);
        const limit = if (sh.rng.chance(7, 10)) size else sh.rng.between(1, size);
        const count = sh.tree.read(index, job.offset, job.buffer, limit);
        if (sh.rng.chance(1, 60)) sh.tree.mutate_id(&sh.rng, sh.tree.handles[index].id, sh.now_ms);
        assert(count <= job.buffer.len);
        return .{ .read = count };
    }

    fn file_verify(jobs: *Jobs, sh: *Shared, index: u16) api.Failure!api.FileValue {
        const slot = &jobs.slots[index];
        assert(slot.handle_open and slot.active);
        defer end_tx(sh, slot);
        if (sh.rng.chance(1, 80)) {
            sh.tree.close(index);
            sh.counters.error_hit(.file_verify_system);
            sh.oracle.system_inject_ms = sh.now_ms;
            return error.System;
        }
        if (sh.rng.chance(1, 200)) {
            sh.tree.close(index);
            sh.counters.error_hit(.file_verify_changed);
            sh.oracle.changed_inject_ms = sh.now_ms;
            return error.Changed;
        }
        const result = sh.tree.verify(index);
        if (result) |_| {} else |_| sh.counters.error_hit(.file_verify_changed);
        return result;
    }

    pub fn submit_watch(jobs: *Jobs, sh: *Shared) void {
        assert(jobs.watch_due_ms == never_ms);
        sh.oracle.watch_call(&sh.verdict, sh.seq);
        const slow = sh.rng.chance(1, 3);
        jobs.watch_due_ms = sh.now_ms + (if (slow) sh.rng.between(100, 450) else sh.rng.below(30));
        if (sh.oracle.exp_start_ms != never_ms and sh.rng.chance(3, 4)) {
            jobs.watch_due_ms = sh.now_ms + sh.rng.below(40);
            jobs.source_dirty = true;
        }
        assert(jobs.watch_due_ms != never_ms);
    }

    pub fn deliver_watch(jobs: *Jobs, sh: *Shared) api.Event {
        assert(jobs.watch_due_ms <= sh.now_ms);
        assert(sh.oracle.watch_out);
        jobs.watch_due_ms = never_ms;
        if (sh.rng.chance(1, 25)) {
            const err = types.failure_from(sh.rng.below(types.failure_variants));
            sh.counters.variant(err);
            sh.counters.error_hit(.watch_error);
            if (err == error.WatchLimit or err == error.PathLimit) sh.counters.limit(.watch_scan);
            const failed: oracle.Observation = .{ .ok = false, .source = false, .dist = false };
            _ = sh.oracle.watch_event(&sh.counters, sh.now_ms, failed);
            return .{ .now_ms = sh.now_ms, .value = .{ .changes = err } };
        }
        const changes: api.Changes = .{
            .source = jobs.source_dirty,
            .dist = jobs.dist_wasm or jobs.dist_other,
            .wasm_only = jobs.dist_wasm and !jobs.dist_other,
            .wasm = api.Path.init("app.wasm") catch @panic("path bound"),
        };
        jobs.source_dirty = false;
        jobs.dist_wasm = false;
        jobs.dist_other = false;
        const published = sh.oracle.watch_event(&sh.counters, sh.now_ms, .{
            .ok = true,
            .source = changes.source,
            .dist = changes.dist,
        });
        if (published) sh.counters.publications += 1;
        assert(!sh.oracle.watch_out and !jobs.source_dirty);
        return .{ .now_ms = sh.now_ms, .value = .{ .changes = changes } };
    }

    pub fn submit_build(jobs: *Jobs, sh: *Shared) void {
        assert(jobs.build_due_ms == never_ms);
        sh.oracle.build_call(&sh.verdict, sh.now_ms);
        const roll = sh.rng.below(100);
        jobs.build_kind = if (roll < 56)
            .success
        else if (roll < 71)
            .failed
        else if (roll < 75)
            .failed_empty
        else if (roll < 81)
            .crashed
        else if (roll < 85)
            .truncated
        else if (roll < 90)
            .hang
        else
            .success;
        jobs.build_cancelled = false;
        const length = sh.rng.below(100);
        const duration: u64 = if (length < 80)
            sh.rng.between(5, 800)
        else if (length < 95)
            sh.rng.between(800, 20000)
        else
            sh.rng.between(20000, 119000);
        if (jobs.watch_due_ms != never_ms and sh.rng.chance(1, 2)) {
            jobs.watch_due_ms = @max(jobs.watch_due_ms, sh.now_ms + sh.rng.between(200, 400));
        }
        const watch_gap = jobs.watch_due_ms -| sh.now_ms;
        const aligned = jobs.watch_due_ms != never_ms and watch_gap > 150 and sh.rng.chance(2, 3);
        const finish = if (aligned) watch_gap - sh.rng.between(60, 100) else duration;
        jobs.build_due_ms = if (jobs.build_kind == .hang) never_ms else sh.now_ms + finish;
        const limit = sh.now_ms + api.build_timeout_ms;
        assert(jobs.build_due_ms == never_ms or jobs.build_due_ms < limit);
    }

    pub fn cancel_build(jobs: *Jobs, sh: *Shared) void {
        assert(!sh.oracle.build_out or sh.oracle.build_start_ms <= sh.now_ms);
        sh.oracle.cancel_call(&sh.verdict, sh.now_ms);
        sh.counters.timeout(.build_120s);
        if (!sh.oracle.build_out or jobs.build_cancelled) return;
        jobs.build_cancelled = true;
        jobs.build_due_ms = sh.now_ms + sh.rng.below(500);
        assert(jobs.build_due_ms >= sh.now_ms);
    }

    pub fn deliver_build(jobs: *Jobs, sh: *Shared) api.Event {
        assert(jobs.build_due_ms <= sh.now_ms);
        jobs.build_due_ms = never_ms;
        var result: api.BuildResult = .{};
        const kind = jobs.build_kind;
        const cancelled = jobs.build_cancelled;
        result.success = kind == .success or kind == .truncated;
        if (cancelled) result.success = false;
        result.cancelled = cancelled;
        result.io_failed = kind == .crashed and !cancelled;
        const length: u32 = switch (kind) {
            .failed_empty, .crashed => 0,
            .truncated => api.output_bytes_max,
            .success => sh.rng.below(300),
            else => sh.rng.between(1, 2000),
        };
        result.truncated = kind == .truncated and !cancelled;
        result.len = if (cancelled) 0 else length;
        for (result.output[0..result.len], 0..) |*byte, offset| {
            byte.* = 'a' + @as(u8, @intCast((offset * 7 + @backingInt(kind)) % 26));
        }
        jobs.finish_build(sh, result);
        jobs.build_cancelled = false;
        assert(jobs.build_due_ms == never_ms and !sh.oracle.build_out);
        return .{ .now_ms = sh.now_ms, .value = .{ .build = result } };
    }

    fn finish_build(jobs: *Jobs, sh: *Shared, result: api.BuildResult) void {
        assert(sh.oracle.build_out and result.len <= api.output_bytes_max);
        sh.oracle.build_event(sh.now_ms, sh.seq, result.success);
        const counters = &sh.counters;
        if (result.success) {
            counters.builds_ok += 1;
            sh.tree.rewrite(files.wasm_id, sh.now_ms);
            sh.tree.rewrite(files.index_id, sh.now_ms);
            jobs.dist_wasm = true;
            jobs.dist_other = sh.rng.chance(1, 2);
            jobs.edit_soon = if (sh.rng.chance(3, 4)) 2 else 0;
        } else if (result.cancelled) {
            counters.error_hit(.build_cancelled);
        } else if (result.io_failed) {
            counters.error_hit(.build_crashed);
        } else counters.error_hit(.build_failed);
        if (result.truncated) counters.limit(.output_truncated);
        assert(!sh.oracle.build_out);
    }
};
