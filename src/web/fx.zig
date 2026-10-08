//! Host services: async browser work behind a poll-style API.
//!
//! `fetch`, file downloads, the file picker, `localStorage`, the clock, URL
//! query parameters, the clipboard, and paste / drag-and-drop of images and
//! files. The JS half is `src/gen/js/fx.js`; the protocol is in
//! docs/ARCHITECTURE.md ("Host services").
//!
//! The model in one paragraph: every request is a synchronous call that
//! returns at once (wasm copies nothing; JS copies what it needs from wasm
//! memory before returning). Every result — including unsolicited ones such
//! as a pasted image — is a *completion record* that JS queues. Wasm
//! collects them by calling `poll` once per frame; `poll` asks JS to hand
//! over at most `out.len` records, each allocated in wasm memory by the
//! exported `zunk_fx_alloc` and passed to the exported `zunk_fx_deliver`.
//! JS never calls into wasm at any other time.
//!
//! Lifetime: the slices inside a `Completion` stay valid until the next
//! `poll`, which frees the previous batch. Nothing else is retained, so a
//! frame loop that polls every frame never leaks.
//!
//! Ids: every request that expects a result takes a caller-chosen `id` that
//! comes back unchanged in the completion; unsolicited completions carry id 0.
//! Use ids >= 1.

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

/// Allocator for completion records (shared with the app on wasm).
const gpa = std.heap.page_allocator;

/// Completions `poll` can hand over per call.
pub const max_completions = 32;

/// Record kinds; the numbers are the `KIND` table in `js/fx.js`.
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

/// One result. `a`..`d` and `blobs` are per-kind (table in `js/fx.js`):
///
///   http          a = status (0: transport failure)        blobs: body, err
///   file_opened                                            blobs: name, mime, bytes
///   file_cancelled
///   downloaded    a = ok (0 / 1)
///   storage_value a = found (0 / 1)                        blobs: value
///   clock         a = UTC offset in minutes                blobs: unix ms (i64 LE, 8 bytes)
///   dropped       a = 0 file / 1 image / 2 text,           blobs: name, mime, bytes, thumb RGBA
///                 b, c = image width, height; d = thumb width
///   pasted_text                                            blobs: text
///   query_value   a = found (0 / 1)                        blobs: value
pub const Completion = struct {
    kind: Kind,
    id: u32,
    a: i32,
    b: i32,
    c: i32,
    d: i32,
    blobs: [4][]const u8,

    /// The unix time of a `clock` completion in milliseconds.
    pub fn unixMs(self: Completion) i64 {
        const raw = self.blobs[0];
        if (raw.len < 8) return 0;
        return std.mem.readInt(i64, raw[0..8], .little);
    }
};

// ── Requests ────────────────────────────────────────────────────────

pub const Method = enum(u32) { get, post, put, delete };

/// Start an HTTP request. `headers` is "Name: value" lines separated by
/// '\n' (see `encodeHeaders`). The result is a `http` completion; the body
/// is read from `body` at once, so it may be freed when this returns.
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

/// Offer `bytes` to the user as a file download. Result: `downloaded`.
pub fn download(id: u32, name: []const u8, mime: []const u8, bytes: []const u8) void {
    zunk_fx_download(id, name.ptr, @intCast(name.len), mime.ptr, @intCast(mime.len), bytes.ptr, @intCast(bytes.len));
}

/// Ask for a file (`accept` is the HTML `accept` list, e.g. ".json,image/*").
/// Result: `file_opened` or `file_cancelled`. Browsers open a picker only
/// from a user activation: if one is live the picker opens now, otherwise
/// it opens on the next pointer press or key press.
pub fn openFile(id: u32, accept: []const u8) void {
    zunk_fx_open_file(id, accept.ptr, @intCast(accept.len));
}

/// Read a `localStorage` key. Result: `storage_value`.
pub fn storageGet(id: u32, key: []const u8) void {
    zunk_fx_storage_get(id, key.ptr, @intCast(key.len));
}

/// Write a `localStorage` key; an empty value deletes it. No result.
pub fn storageSet(key: []const u8, value: []const u8) void {
    zunk_fx_storage_set(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len));
}

/// Ask for the wall clock. Result: `clock`.
pub fn clock(id: u32) void {
    zunk_fx_clock(id);
}

/// Read a URL query parameter (`?name=value`). Result: `query_value`.
pub fn queryParam(id: u32, name: []const u8) void {
    zunk_fx_query_param(id, name.ptr, @intCast(name.len));
}

/// Write text to the clipboard (`navigator.clipboard.writeText`, with an
/// `execCommand('copy')` fallback). No result.
pub fn clipboardWrite(text: []const u8) void {
    zunk_fx_clipboard_write(text.ptr, @intCast(text.len));
}

/// Write a PNG image to the clipboard (`navigator.clipboard.write` with an
/// `image/png` `ClipboardItem`). Browsers require a user activation and a
/// secure context; a refusal is logged. No result.
pub fn clipboardWriteImage(png: []const u8) void {
    zunk_fx_clipboard_write_image(png.ptr, @intCast(png.len));
}

/// Encode headers as "Name: value\n" lines for `http`. `headers` is any
/// slice of structs with `name` and `value` string fields. A header whose
/// name or value contains a line break, or whose name contains ':' or is
/// empty, is skipped (it could not be told apart from another header).
/// Caller frees the result.
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

// ── Completions ─────────────────────────────────────────────────────

const Batch = struct {
    raw: [max_completions][]u8 = undefined,
    len: usize = 0,

    fn release(self: *Batch) void {
        for (self.raw[0..self.len]) |r| gpa.free(r);
        self.len = 0;
    }
};

/// Records JS delivered since the last drain, and the previous batch (still
/// referenced by the completions the caller holds). JS calls into wasm
/// through `zunk_fx_deliver`, which has no context pointer, so this is
/// module state.
var inbox: Batch = .{};
var held: Batch = .{};

/// Collect the completions that arrived since the last call into `out` and
/// return how many. Frees the previous batch first: slices of earlier
/// completions are invalid after this call.
pub fn poll(out: []Completion) usize {
    held.release();
    const cap = @min(out.len, max_completions);
    if (cap == 0) return 0;
    zunk_fx_pump(@intCast(cap));
    return drain(out[0..cap]);
}

/// Move delivered records into `out`. Split from `poll` so tests can feed
/// `zunk_fx_deliver` directly.
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

/// Parse one completion record (layout in `js/fx.js`). Null if it is
/// malformed. The blobs alias `raw`.
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

/// JS: allocate `len` bytes in wasm memory for one completion record.
/// Returns 0 when memory is exhausted. JS must re-read `memory.buffer`
/// afterwards (the allocation may have grown memory).
pub export fn zunk_fx_alloc(len: u32) ?[*]u8 {
    const raw = gpa.alloc(u8, len) catch return null;
    return raw.ptr;
}

/// JS: a record written at `ptr` (from `zunk_fx_alloc`) is complete. Ownership
/// passes to the inbox; `poll` frees it.
pub export fn zunk_fx_deliver(ptr: [*]u8, len: u32) void {
    if (inbox.len == inbox.raw.len) return gpa.free(ptr[0..len]);
    inbox.raw[inbox.len] = ptr[0..len];
    inbox.len += 1;
}

// ── Tests ───────────────────────────────────────────────────────────

/// Build a record the way `push()` in js/fx.js does.
fn testRecord(kind: u32, id: u32, ints: [4]i32, blobs: [4][]const u8) []u8 {
    var total: usize = header_len;
    for (blobs) |b| total += b.len;
    const rec = zunk_fx_alloc(@intCast(total)).?[0..total];
    std.mem.writeInt(u32, rec[0..4], kind, .little);
    std.mem.writeInt(u32, rec[4..8], id, .little);
    for (ints, 0..) |v, i| std.mem.writeInt(i32, rec[8 + 4 * i ..][0..4], v, .little);
    var off: usize = header_len;
    for (blobs, 0..) |b, i| {
        std.mem.writeInt(u32, rec[24 + 4 * i ..][0..4], @intCast(b.len), .little);
        @memcpy(rec[off..][0..b.len], b);
        off += b.len;
    }
    return rec;
}

fn testDeliver(rec: []u8) void {
    zunk_fx_deliver(rec.ptr, @intCast(rec.len));
}

test "completions round-trip through alloc / deliver / drain" {
    held.release();
    testDeliver(testRecord(@backingInt(Kind.http), 7, .{ 404, 0, 0, 0 }, .{ "not here", "", "", "" }));
    testDeliver(testRecord(@backingInt(Kind.dropped), 0, .{ 1, 1568, 900, 2 }, .{ "a.png", "image/png", "\x89PNG", "\x01\x02\x03\x04" }));

    var out: [4]Completion = undefined;
    const n = drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Kind.http, out[0].kind);
    try std.testing.expectEqual(@as(u32, 7), out[0].id);
    try std.testing.expectEqual(@as(i32, 404), out[0].a);
    try std.testing.expectEqualStrings("not here", out[0].blobs[0]);
    try std.testing.expectEqual(@as(usize, 0), out[0].blobs[1].len);
    try std.testing.expectEqual(Kind.dropped, out[1].kind);
    try std.testing.expectEqual(@as(i32, 1568), out[1].b);
    try std.testing.expectEqualStrings("image/png", out[1].blobs[1]);
    try std.testing.expectEqualStrings("\x01\x02\x03\x04", out[1].blobs[3]);

    held.release(); // what the next `poll` does; the testing allocator would flag a leak
    try std.testing.expectEqual(@as(usize, 0), inbox.len);
}

test "clock completions carry the unix time in blob 0" {
    var ms: [8]u8 = undefined;
    std.mem.writeInt(i64, &ms, 1_700_000_123_456, .little);
    held.release();
    testDeliver(testRecord(@backingInt(Kind.clock), 3, .{ 60, 0, 0, 0 }, .{ &ms, "", "", "" }));
    var out: [1]Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), drain(&out));
    try std.testing.expectEqual(@as(i64, 1_700_000_123_456), out[0].unixMs());
    try std.testing.expectEqual(@as(i32, 60), out[0].a);
    held.release();
}

test "malformed records and overflow are dropped without leaking" {
    held.release();
    // Too short for the header.
    testDeliver(zunk_fx_alloc(10).?[0..10]);
    // Unknown kind.
    testDeliver(testRecord(99, 1, .{ 0, 0, 0, 0 }, .{ "", "", "", "" }));
    // A blob length that runs past the end.
    const bad = testRecord(@backingInt(Kind.http), 1, .{ 0, 0, 0, 0 }, .{ "x", "", "", "" });
    std.mem.writeInt(u32, bad[24..28], 1000, .little);
    testDeliver(bad);
    // More than the caller has room for.
    testDeliver(testRecord(@backingInt(Kind.clock), 1, .{ 0, 0, 0, 0 }, .{ "", "", "", "" }));
    testDeliver(testRecord(@backingInt(Kind.clock), 2, .{ 0, 0, 0, 0 }, .{ "", "", "", "" }));

    var out: [1]Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), drain(&out));
    try std.testing.expectEqual(@as(u32, 1), out[0].id);
    held.release();
}

test "a full inbox frees the surplus delivery" {
    held.release();
    for (0..max_completions + 3) |i| testDeliver(testRecord(@backingInt(Kind.query_value), @intCast(i), .{ 0, 0, 0, 0 }, .{ "", "", "", "" }));
    try std.testing.expectEqual(@as(usize, max_completions), inbox.len);
    var out: [max_completions]Completion = undefined;
    try std.testing.expectEqual(@as(usize, max_completions), drain(&out));
    held.release();
}

test "encodeHeaders joins lines and skips headers that could smuggle another" {
    const H = struct { name: []const u8, value: []const u8 };
    const hs = [_]H{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-bad\nname", .value = "v" },
        .{ .name = "x-bad:name", .value = "v" },
        .{ .name = "x-evil", .value = "a\r\nInjected: 1" },
        .{ .name = "", .value = "v" },
        .{ .name = "x-api-key", .value = "k" },
    };
    const out = try encodeHeaders(std.testing.allocator, &hs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("content-type: application/json\nx-api-key: k\n", out);
}

test "Kind numbers match the KIND table in fx.js" {
    const js = @embedFile("../gen/js/fx.js");
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "{s}: {d}", .{ name, value });
        try std.testing.expect(std.mem.find(u8, js, needle) != null);
    }
}
