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
