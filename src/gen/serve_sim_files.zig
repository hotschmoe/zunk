const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const types = @import("serve_sim_types.zig");

pub const files_max: u8 = 10;
pub const header_bytes: u32 = 16;
pub const clean_max: u32 = 64;
pub const index_id: u8 = 0;
pub const empty_id: u8 = 7;
pub const huge_id: u8 = 8;
pub const gone_id: u8 = 9;
pub const wasm_id: u8 = 4;

pub const Class = enum(u8) {
    html_body,
    html_plain,
    script,
    binary,
    stylesheet,
    json,
    empty,
    huge,
};

pub const Entry = struct {
    name: []const u8,
    class: Class,
    size_min: u32,
    size_span: u32,
    mutable: bool,
    deletable: bool,
    exists: bool = true,
    inode: u32 = 1,
    version: u32 = 1,
    last_mutation_ms: u64 = types.never_ms,
    last_missing_ms: u64 = types.never_ms,
};

pub const Stamp = struct { id: u8, inode: u32, version: u32, size: u32 };

pub const Handle = struct {
    open: bool = false,
    id: u8 = 0,
    inode: u32 = 0,
    version: u32 = 0,
    size: u32 = 0,
    dirty: bool = false,
};

fn stamp_key(id: u8, inode: u32, version: u32) u64 {
    return types.splitmix(types.splitmix(id) ^ types.splitmix(@as(u64, inode) +% 0x100) ^
        types.splitmix(@as(u64, version) +% 0x10000));
}

fn tag_position(key: u64) u32 {
    return 32 + @as(u32, @intCast((key >> 8) % 24));
}

pub fn injects(class: Class) bool {
    return class == .html_body or class == .html_plain;
}

pub fn byte_at(stamp: Stamp, class: Class, position: u32) u8 {
    assert(class != .huge and class != .empty);
    assert(position < stamp.size);
    if (position < header_bytes) {
        const fields = [4]u32{ stamp.id, stamp.inode, stamp.version, stamp.size };
        const shift: u5 = @intCast(8 * (position % 4));
        return @truncate(fields[position / 4] >> shift);
    }
    const key = stamp_key(stamp.id, stamp.inode, stamp.version);
    if (class == .html_body) {
        const at = tag_position(key);
        if (position >= at and position < at + 7) return "</body>"[position - at];
    }
    const word = types.splitmix(key ^ (position >> 3));
    const raw: u8 = @truncate(word >> @intCast(8 * (position & 7)));
    return if (injects(class)) 'a' + raw % 26 else raw;
}

pub fn fill(stamp: Stamp, class: Class, offset: u32, out: []u8) void {
    assert(offset + out.len <= stamp.size);
    for (out, 0..) |*byte, index| {
        byte.* = byte_at(stamp, class, offset + @as(u32, @intCast(index)));
    }
    assert(out.len == 0 or out[0] == byte_at(stamp, class, offset));
}

pub fn inject_position(stamp: Stamp, class: Class) u32 {
    assert(injects(class));
    const at = if (class == .html_plain)
        stamp.size
    else
        tag_position(stamp_key(stamp.id, stamp.inode, stamp.version));
    assert(at >= 32 and at <= stamp.size);
    return at;
}

pub fn expected_byte(stamp: Stamp, class: Class, script: []const u8, position: u32) u8 {
    assert(position < stamp.size + script.len);
    assert(stamp.size > 0);
    if (!injects(class)) return byte_at(stamp, class, position);
    const at = inject_position(stamp, class);
    if (position < at) return byte_at(stamp, class, position);
    if (position < at + script.len) return script[position - at];
    return byte_at(stamp, class, position - @as(u32, @intCast(script.len)));
}

pub fn mime_for(name: []const u8) []const u8 {
    assert(name.len > 0);
    const extensions = [_][]const u8{ ".html", ".js", ".wasm", ".css", ".json" };
    const types_list = [_][]const u8{
        "text/html", "application/javascript", "application/wasm",
        "text/css",  "application/json",
    };
    assert(extensions.len == types_list.len);
    for (extensions, types_list) |extension, mime| {
        if (std.mem.endsWith(u8, name, extension)) return mime;
    }
    return "application/octet-stream";
}

fn metadata(id: u8, inode: u32, version: u32, size: u32) api.Metadata {
    assert(inode > 0 and version > 0);
    const modified: i128 = @as(i128, version) * 1_000_003 + @as(i128, inode) * 17;
    assert(modified > 0);
    return .{
        .size = size,
        .inode = (@as(u64, id) + 1) * 100000 + inode,
        .modified_ns = modified,
        .changed_ns = modified + 5,
    };
}

fn make(name: []const u8, class: Class, size_min: u32, size_span: u32, deletable: bool) Entry {
    assert(name.len > 0 and name.len <= api.path_bytes_max);
    assert(size_span == 0 or size_min >= 64);
    return .{
        .name = name,
        .class = class,
        .size_min = size_min,
        .size_span = size_span,
        .mutable = true,
        .deletable = deletable,
    };
}

pub const Tree = struct {
    entries: [files_max]Entry = undefined,
    handles: [api.snapshots_max]Handle = undefined,
    clean: [clean_max]Stamp = undefined,
    clean_count: u32 = 0,

    pub fn init(tree: *Tree, rng: *types.Rng) void {
        tree.entries = .{
            make("index.html", .html_body, 300, 1500, false),
            make("page.html", .html_plain, 200, 600, false),
            make("multi.html", .html_body, 70000, 90000, false),
            make("app.js", .script, 2000, 88000, false),
            make("app.wasm", .binary, 70000, 130000, false),
            make("style.css", .stylesheet, 100, 2900, false),
            make("data/blob.json", .json, 500, 3500, false),
            make("empty.txt", .empty, 0, 0, false),
            make("big.bin", .huge, 0, 0, false),
            make("gone.txt", .binary, 100, 1900, true),
        };
        tree.entries[huge_id].mutable = false;
        tree.entries[gone_id].exists = rng.chance(1, 2);
        for (&tree.handles) |*handle| handle.* = .{};
        tree.clean_count = 0;
        assert(tree.entries[index_id].exists);
        assert(tree.entries[huge_id].class == .huge);
    }

    pub fn find(tree: *const Tree, name: []const u8) ?u8 {
        assert(name.len <= api.path_bytes_max);
        for (&tree.entries, 0..) |*entry, id| {
            assert(entry.name.len > 0);
            if (std.mem.eql(u8, entry.name, name)) return @intCast(id);
        }
        return null;
    }

    pub fn size_of(tree: *const Tree, id: u8, inode: u32, version: u32) u32 {
        assert(id < files_max and version > 0);
        const entry = &tree.entries[id];
        if (entry.class == .huge) return api.file_bytes_max + 1;
        if (entry.size_span == 0) return entry.size_min;
        const key = stamp_key(id, inode, version);
        const size = entry.size_min + @as(u32, @intCast((key >> 16) % (entry.size_span + 1)));
        assert(size >= entry.size_min and size <= entry.size_min + entry.size_span);
        return size;
    }

    pub fn open(tree: *Tree, slot: u16, name: []const u8) api.Failure!api.Metadata {
        assert(slot < api.snapshots_max);
        assert(!tree.handles[slot].open);
        const id = tree.find(name) orelse return error.NotFound;
        const entry = &tree.entries[id];
        if (!entry.exists) return error.NotFound;
        const size = tree.size_of(id, entry.inode, entry.version);
        tree.handles[slot] = .{
            .open = true,
            .id = id,
            .inode = entry.inode,
            .version = entry.version,
            .size = size,
        };
        return metadata(id, entry.inode, entry.version, size);
    }

    pub fn read(tree: *Tree, slot: u16, offset: u32, buffer: []u8, limit: u32) u32 {
        assert(slot < api.snapshots_max and limit > 0);
        const handle = &tree.handles[slot];
        assert(handle.open);
        const entry = &tree.entries[handle.id];
        const live = entry.exists and entry.inode == handle.inode;
        const version = if (live) entry.version else handle.version;
        if (version != handle.version) handle.dirty = true;
        const size = if (live) tree.size_of(handle.id, handle.inode, version) else handle.size;
        if (offset >= size or entry.class == .empty) return 0;
        const count: u32 = @min(@as(u32, @intCast(buffer.len)), size - offset, limit);
        const stamp: Stamp = .{
            .id = handle.id,
            .inode = handle.inode,
            .version = version,
            .size = size,
        };
        fill(stamp, entry.class, offset, buffer[0..count]);
        assert(count > 0 and count <= limit);
        return count;
    }

    pub fn verify(tree: *Tree, slot: u16) api.Failure!api.FileValue {
        assert(slot < api.snapshots_max);
        const handle = &tree.handles[slot];
        assert(handle.open);
        handle.open = false;
        const entry = &tree.entries[handle.id];
        const live = entry.exists and entry.inode == handle.inode;
        const frozen = metadata(handle.id, handle.inode, handle.version, handle.size);
        const current_size = tree.size_of(handle.id, entry.inode, entry.version);
        const seen = if (live)
            metadata(handle.id, handle.inode, entry.version, current_size)
        else
            frozen;
        if (!entry.exists) {
            handle.dirty = true;
            return error.Changed;
        }
        const named = metadata(handle.id, entry.inode, entry.version, current_size);
        const same = live and entry.version == handle.version and !handle.dirty;
        if (same) tree.remember(.{
            .id = handle.id,
            .inode = handle.inode,
            .version = handle.version,
            .size = handle.size,
        });
        return .{ .verified = .{ .handle = seen, .path = named } };
    }

    pub fn close(tree: *Tree, slot: u16) void {
        assert(slot < api.snapshots_max);
        assert(tree.handles[slot].open);
        tree.handles[slot].open = false;
    }

    fn remember(tree: *Tree, stamp: Stamp) void {
        assert(stamp.id < files_max and stamp.size <= api.file_bytes_max);
        tree.clean[tree.clean_count % clean_max] = stamp;
        tree.clean_count += 1;
        assert(tree.clean_count > 0);
    }

    pub fn recent_clean(tree: *const Tree, stamp: Stamp) bool {
        assert(stamp.id < files_max);
        const count = @min(tree.clean_count, clean_max);
        assert(count <= clean_max);
        for (tree.clean[0..count]) |known| {
            if (known.id == stamp.id and known.inode == stamp.inode and
                known.version == stamp.version and known.size == stamp.size) return true;
        }
        return false;
    }

    pub fn mutate(tree: *Tree, rng: *types.Rng, now_ms: u64) u8 {
        var id: u8 = 0;
        for (0..64) |_| {
            id = @intCast(rng.below(files_max));
            if (tree.entries[id].mutable) break;
        }
        assert(tree.entries[id].mutable);
        tree.mutate_id(rng, id, now_ms);
        assert(tree.entries[id].last_mutation_ms == now_ms);
        return id;
    }

    pub fn mutate_id(tree: *Tree, rng: *types.Rng, id: u8, now_ms: u64) void {
        assert(id < files_max);
        const entry = &tree.entries[id];
        if (!entry.mutable) return;
        const roll = rng.below(100);
        if (!entry.exists) {
            entry.exists = true;
            entry.inode += 1;
            entry.version += 1;
            entry.last_missing_ms = now_ms;
        } else if (roll < 55 or (roll >= 80 and !entry.deletable)) {
            entry.version += 1;
        } else if (roll < 80) {
            entry.inode += 1;
            entry.version += 1;
        } else {
            entry.exists = false;
            entry.last_missing_ms = now_ms;
        }
        entry.last_mutation_ms = now_ms;
        assert(entry.last_mutation_ms == now_ms);
    }

    pub fn rewrite(tree: *Tree, id: u8, now_ms: u64) void {
        assert(id < files_max);
        const entry = &tree.entries[id];
        assert(entry.exists and entry.mutable);
        entry.version += 1;
        entry.last_mutation_ms = now_ms;
    }

    pub fn mutated_since(tree: *const Tree, id: u8, since_ms: u64) bool {
        assert(id < files_max);
        assert(since_ms != types.never_ms);
        const last = tree.entries[id].last_mutation_ms;
        return last != types.never_ms and last >= since_ms;
    }

    pub fn missing_since(tree: *const Tree, id: u8, since_ms: u64) bool {
        assert(id < files_max);
        assert(since_ms != types.never_ms);
        const entry = &tree.entries[id];
        if (!entry.exists) return true;
        return entry.last_missing_ms != types.never_ms and entry.last_missing_ms >= since_ms;
    }
};
