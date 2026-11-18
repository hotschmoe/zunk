const std = @import("std");

extern "env" fn zunk_fx_pump(max: u32) void;
extern "env" fn zunk_fx_http(
    id: u32,
    method: u32,
    url_ptr: [*]const u8,
    url_len: u32,
    headers_ptr: [*]const u8,
    headers_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
    timeout_ms: u32,
) void;
extern "env" fn zunk_fx_download(
    id: u32,
    name_ptr: [*]const u8,
    name_len: u32,
    mime_ptr: [*]const u8,
    mime_len: u32,
    bytes_ptr: [*]const u8,
    bytes_len: u32,
) void;
extern "env" fn zunk_fx_open_file(id: u32, accept_ptr: [*]const u8, accept_len: u32) void;
extern "env" fn zunk_fx_storage_get(id: u32, key_ptr: [*]const u8, key_len: u32) void;
extern "env" fn zunk_fx_storage_set(key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32) void;
extern "env" fn zunk_fx_clock(id: u32) void;
extern "env" fn zunk_fx_query_param(id: u32, name_ptr: [*]const u8, name_len: u32) void;
extern "env" fn zunk_fx_clipboard_write(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_fx_clipboard_write_image(ptr: [*]const u8, len: u32) void;

const gpa = std.heap.page_allocator;

pub const max_completions = 32;

// Record kind numbers must match the KIND table in js/fx.js.
pub const Kind = enum(u32) {
    http = 1,
    file_opened = 2,
    file_cancelled = 3,
    downloaded = 4,
    storage_value = 5,
    clock = 6,
    dropped = 7,
    pasted_text = 8,
    query_value = 9,
};

pub const Completion = struct {
    kind: Kind,
    id: u32,
    a: i32,
    b: i32,
    c: i32,
    d: i32,
    blobs: [4][]const u8,

    pub fn unixMs(self: Completion) i64 {
        const raw = self.blobs[0];
        if (raw.len < 8) return 0;
        return std.mem.readInt(i64, raw[0..8], .little);
    }
};

pub const Method = enum(u32) { get, post, put, delete };

pub fn http(id: u32, method: Method, url: []const u8, headers: []const u8, body: []const u8, timeout_ms: u32) void {
    zunk_fx_http(
        id,
        @backingInt(method),
        url.ptr,
        @intCast(url.len),
        headers.ptr,
        @intCast(headers.len),
        body.ptr,
        @intCast(body.len),
        timeout_ms,
    );
}

pub fn download(id: u32, name: []const u8, mime: []const u8, bytes: []const u8) void {
    zunk_fx_download(id, name.ptr, @intCast(name.len), mime.ptr, @intCast(mime.len), bytes.ptr, @intCast(bytes.len));
}

pub fn openFile(id: u32, accept: []const u8) void {
    zunk_fx_open_file(id, accept.ptr, @intCast(accept.len));
}

pub fn storageGet(id: u32, key: []const u8) void {
    zunk_fx_storage_get(id, key.ptr, @intCast(key.len));
}

pub fn storageSet(key: []const u8, value: []const u8) void {
    zunk_fx_storage_set(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len));
}

pub fn clock(id: u32) void {
    zunk_fx_clock(id);
}

pub fn queryParam(id: u32, name: []const u8) void {
    zunk_fx_query_param(id, name.ptr, @intCast(name.len));
}

pub fn clipboardWrite(text: []const u8) void {
    zunk_fx_clipboard_write(text.ptr, @intCast(text.len));
}

pub fn clipboardWriteImage(png: []const u8) void {
    zunk_fx_clipboard_write_image(png.ptr, @intCast(png.len));
}

pub fn encodeHeaders(allocator: std.mem.Allocator, headers: anytype) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (headers) |h| {
        if (!validHeader(h.name, h.value)) continue;
        try out.appendSlice(allocator, h.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, h.value);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn validHeader(name: []const u8, value: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.findAny(u8, name, ":\r\n") != null) return false;
    return std.mem.findAny(u8, value, "\r\n") == null;
}

const Batch = struct {
    raw: [max_completions][]u8 = undefined,
    len: usize = 0,

    fn release(self: *Batch) void {
        for (self.raw[0..self.len]) |r| gpa.free(r);
        self.len = 0;
    }
};

var inbox: Batch = .{};
var held: Batch = .{};

pub fn poll(out: []Completion) usize {
    held.release();
    const cap = @min(out.len, max_completions);
    if (cap == 0) return 0;
    zunk_fx_pump(@intCast(cap));
    return drain(out[0..cap]);
}

fn drain(out: []Completion) usize {
    var n: usize = 0;
    for (inbox.raw[0..inbox.len]) |raw| {
        if (n < out.len) if (decode(raw)) |c| {
            out[n] = c;
            held.raw[held.len] = raw;
            held.len += 1;
            n += 1;
            continue;
        };
        gpa.free(raw); // malformed, or more than the caller asked for
    }
    inbox.len = 0;
    return n;
}

const header_len = 40;

// Record layout: js/fx.js.
fn decode(raw: []const u8) ?Completion {
    if (raw.len < header_len) return null;
    const kind = std.enums.fromInt(Kind, std.mem.readInt(u32, raw[0..4], .little)) orelse return null;
    var c: Completion = .{
        .kind = kind,
        .id = std.mem.readInt(u32, raw[4..8], .little),
        .a = std.mem.readInt(i32, raw[8..12], .little),
        .b = std.mem.readInt(i32, raw[12..16], .little),
        .c = std.mem.readInt(i32, raw[16..20], .little),
        .d = std.mem.readInt(i32, raw[20..24], .little),
        .blobs = undefined,
    };
    var off: usize = header_len;
    for (&c.blobs, 0..) |*blob, i| {
        const len = std.mem.readInt(u32, raw[24 + 4 * i ..][0..4], .little);
        if (len > raw.len - off) return null;
        blob.* = raw[off..][0..len];
        off += len;
    }
    return c;
}

pub export fn zunk_fx_alloc(len: u32) ?[*]u8 {
    const raw = gpa.alloc(u8, len) catch return null;
    return raw.ptr;
}

pub export fn zunk_fx_deliver(ptr: [*]u8, len: u32) void {
    if (inbox.len == inbox.raw.len) return gpa.free(ptr[0..len]);
    inbox.raw[inbox.len] = ptr[0..len];
    inbox.len += 1;
}
