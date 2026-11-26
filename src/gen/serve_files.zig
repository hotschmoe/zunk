const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const Io = std.Io;

pub const directories_max: u16 = 1024;
pub const entries_max: u32 = 65536;
pub fn perform(
    io: Io,
    root: Io.Dir,
    job: api.FileJob,
    opened: *?Io.File,
) api.Failure!api.FileValue {
    assert(job.index < api.snapshots_max);
    assert(job.offset <= api.file_bytes_max);
    switch (job.operation) {
        .open => return open(io, root, job.path, opened),
        .read => {
            assert(opened.* != null and job.buffer.len > 0);
            var vectors = [_][]u8{job.buffer};
            const count = opened.*.?.readPositional(
                io,
                &vectors,
                job.offset,
            ) catch return error.System;
            return .{ .read = @intCast(count) };
        },
        .verify_close => {
            assert(opened.* != null);
            defer close(io, opened);
            const handle = opened.*.?.stat(io) catch return error.System;
            const named = root.statFile(io, job.path.slice(), .{}) catch return error.Changed;
            if (handle.kind != .file or named.kind != .file) return error.Changed;
            return .{ .verified = .{ .handle = metadata(handle), .path = metadata(named) } };
        },
        .close => {
            close(io, opened);
            return .closed;
        },
    }
}

fn open(io: Io, root: Io.Dir, path: api.Path, opened: *?Io.File) api.Failure!api.FileValue {
    assert(opened.* == null);
    assert(path.len > 0);
    const file = root.openFile(io, path.slice(), .{ .allow_directory = false }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => error.NotFound,
            else => error.System,
        };
    };
    errdefer file.close(io);
    const stat = file.stat(io) catch return error.System;
    if (stat.kind != .file) return error.NotFound;
    opened.* = file;
    return .{ .opened = metadata(stat) };
}

fn metadata(stat: Io.File.Stat) api.Metadata {
    return .{
        .size = stat.size,
        .inode = @bitCast(stat.inode),
        .modified_ns = stat.mtime.nanoseconds,
        .changed_ns = stat.ctime.nanoseconds,
    };
}

pub fn close(io: Io, opened: *?Io.File) void {
    assert(opened.* != null);
    opened.*.?.close(io);
    opened.* = null;
    assert(opened.* == null);
}

const Fingerprint = struct { wasm: u64 = 0, other: u64 = 0, name: api.Path = .{} };

pub const Watcher = struct {
    paths: [directories_max]api.Path,
    source_previous: ?u64 = null,
    dist_previous: ?Fingerprint = null,
    paths_len: u16 = 0,
    entries: u32 = 0,

    pub fn init(watcher: *Watcher) void {
        watcher.source_previous = null;
        watcher.dist_previous = null;
        watcher.paths_len = 0;
        watcher.entries = 0;
        assert(watcher.source_previous == null and watcher.dist_previous == null);
        assert(watcher.paths_len == 0 and watcher.entries == 0);
    }

    pub fn poll(
        watcher: *Watcher,
        io: Io,
        root: []const u8,
        config: api.Config,
    ) api.Failure!api.Changes {
        assert(watcher.paths.len == directories_max);
        assert(config.watch_paths.len <= directories_max);
        var result: api.Changes = .{};
        var source_current: ?u64 = null;
        if (config.watch_sources) {
            const source = try watcher.source_fingerprint(io, config);
            source_current = source;
            if (watcher.source_previous) |previous| result.source = source != previous;
        }
        watcher.entries = 0;
        watcher.paths_len = 0;
        const dist = try watcher.directory(io, try api.Path.init(root), false);
        if (watcher.dist_previous) |previous| {
            const wasm_changed = previous.wasm != dist.wasm;
            const other_changed = previous.other != dist.other;
            result.dist = wasm_changed or other_changed;
            result.wasm_only = wasm_changed and !other_changed;
            result.wasm = dist.name;
        }
        watcher.dist_previous = dist;
        watcher.source_previous = source_current;
        return result;
    }

    fn source_fingerprint(watcher: *Watcher, io: Io, config: api.Config) api.Failure!u64 {
        watcher.entries = 0;
        watcher.paths_len = 0;
        for (config.watch_paths) |path| try watcher.queue(try api.Path.init(path));
        var fingerprint: u64 = 0;
        var index: u16 = 0;
        for (0..directories_max) |_| {
            if (index == watcher.paths_len) break;
            const current = watcher.paths[index];
            index += 1;
            const part = try watcher.directory(io, current, true);
            fingerprint +%= part.wasm +% part.other;
        }
        assert(index == watcher.paths_len);
        assert(watcher.paths_len <= directories_max);
        for (config.watch_files) |path| {
            if (path.len > api.path_bytes_max) return error.PathLimit;
            const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
                if (err == error.FileNotFound) continue;
                return error.System;
            };
            if (stat.kind != .file) return error.System;
            fingerprint +%= stamp(path, stat);
        }
        return fingerprint;
    }

    fn directory(
        watcher: *Watcher,
        io: Io,
        path: api.Path,
        recursive: bool,
    ) api.Failure!Fingerprint {
        assert(watcher.entries <= entries_max);
        assert(path.len <= api.path_bytes_max);
        const dir = Io.Dir.cwd().openDir(io, path.slice(), .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return .{};
            return error.System;
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        var fingerprint: Fingerprint = .{};
        for (0..entries_max + 1) |_| {
            const entry = (iterator.next(io) catch return error.System) orelse return fingerprint;
            if (watcher.entries == entries_max) return error.WatchLimit;
            watcher.entries += 1;
            var joined: api.Path = .{};
            const full = std.fmt.bufPrint(
                &joined.bytes,
                "{s}/{s}",
                .{ path.slice(), entry.name },
            ) catch return error.PathLimit;
            joined.len = @intCast(full.len);
            if (entry.kind == .directory and recursive) try watcher.queue(joined);
            if (entry.kind != .file) continue;
            const stat = dir.statFile(io, entry.name, .{}) catch return error.System;
            if (stat.kind != .file) return error.Changed;
            const value = stamp(full, stat);
            if (std.mem.endsWith(u8, entry.name, ".wasm")) {
                fingerprint.wasm +%= value;
                if (fingerprint.name.len == 0 or
                    std.mem.order(u8, entry.name, fingerprint.name.slice()) == .lt)
                {
                    fingerprint.name = try api.Path.init(entry.name);
                }
            } else fingerprint.other +%= value;
        }
        return error.WatchLimit;
    }

    fn queue(watcher: *Watcher, path: api.Path) api.Failure!void {
        assert(watcher.paths_len <= directories_max);
        if (watcher.paths_len == directories_max) return error.WatchLimit;
        watcher.paths[watcher.paths_len] = path;
        watcher.paths_len += 1;
        assert(watcher.paths_len > 0);
    }
};

fn stamp(path: []const u8, stat: Io.File.Stat) u64 {
    assert(path.len <= api.path_bytes_max);
    var hash = std.hash.Wyhash.init(0);
    hash.update(path);
    hash.update(std.mem.asBytes(&stat.inode));
    hash.update(std.mem.asBytes(&stat.size));
    hash.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    hash.update(std.mem.asBytes(&stat.ctime.nanoseconds));
    assert(stat.kind == .file);
    return hash.final();
}
