//! IME bridge: composition (preedit) and committed text from the browser's
//! input method, via a visually hidden `<textarea>` that holds keyboard focus
//! while the app has a focused text field. The JS half is `src/gen/js/ime.js`
//! (the wire format and the double-insertion rules are documented there).
//!
//! Frame loop: call `setActive(true)` while a text field has focus, `setSpot`
//! when the caret moves (so the candidate window opens next to it), and `poll`
//! once per frame to drain events. Printable keys never come through here: they
//! stay on the `zunk.web.input` typed-text path.

const std = @import("std");

extern "env" fn zunk_ime_set_active(active: u32) void;
extern "env" fn zunk_ime_set_spot(x: f32, y: f32, h: f32) void;
extern "env" fn zunk_ime_poll(ptr: [*]u8, cap: u32) u32;

pub const Kind = enum(u32) {
    /// A composition began (preedit is empty until the first `update`).
    start = 1,
    /// The preedit text changed; `cursor` is the caret inside it, in bytes.
    update = 2,
    /// Text to insert. After a composition this is its result (empty = the
    /// composition was cancelled); outside one it is plain inserted text.
    commit = 3,
};

/// One event. `text` aliases the buffer given to `poll`.
pub const Event = struct {
    kind: Kind,
    cursor: usize,
    text: []const u8,
};

/// Focus the hidden field (true) or release it (false). Idempotent.
pub fn setActive(active: bool) void {
    zunk_ime_set_active(@intFromBool(active));
}

/// Anchor the IME window: top-left of the caret's line in canvas-relative CSS
/// px, and the line height.
pub fn setSpot(x: f32, y: f32, line_h: f32) void {
    zunk_ime_set_spot(x, y, line_h);
}

/// Drain queued events into `out`, copying their text into `scratch`. Stops
/// early when `out` or `scratch` is full (the rest stay queued). Returns the
/// number of events.
pub fn poll(out: []Event, scratch: []u8) usize {
    const written = zunk_ime_poll(scratch.ptr, @intCast(scratch.len));
    return decode(scratch[0..written], out);
}

/// Parse the records `poll` received (layout in `js/ime.js`).
pub fn decode(raw: []const u8, out: []Event) usize {
    var off: usize = 0;
    var n: usize = 0;
    while (off + 12 <= raw.len and n < out.len) {
        const kind = std.mem.readInt(u32, raw[off..][0..4], .little);
        const cursor = std.mem.readInt(u32, raw[off + 4 ..][0..4], .little);
        const len = std.mem.readInt(u32, raw[off + 8 ..][0..4], .little);
        const padded = (len + 3) & ~@as(u32, 3);
        if (off + 12 + padded > raw.len) break;
        const k = std.enums.fromInt(Kind, kind) orelse {
            off += 12 + padded;
            continue;
        };
        out[n] = .{ .kind = k, .cursor = cursor, .text = raw[off + 12 ..][0..len] };
        n += 1;
        off += 12 + padded;
    }
    return n;
}

test "decode: start, update with a cursor, commit; unknown kinds are skipped" {
    var raw: [64]u8 = undefined;
    var w: usize = 0;
    const put = struct {
        fn rec(buf: []u8, at: *usize, kind: u32, cursor: u32, text: []const u8) void {
            std.mem.writeInt(u32, buf[at.*..][0..4], kind, .little);
            std.mem.writeInt(u32, buf[at.* + 4 ..][0..4], cursor, .little);
            std.mem.writeInt(u32, buf[at.* + 8 ..][0..4], @intCast(text.len), .little);
            @memcpy(buf[at.* + 12 ..][0..text.len], text);
            at.* += 12 + ((text.len + 3) & ~@as(usize, 3));
        }
    }.rec;
    put(&raw, &w, 1, 0, "");
    put(&raw, &w, 9, 0, "x"); // unknown
    put(&raw, &w, 2, 3, "\u{3042}"); // あ, caret after it
    put(&raw, &w, 3, 0, "\u{3042}\u{3044}");
    var ev: [8]Event = undefined;
    const n = decode(raw[0..w], &ev);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Kind.start, ev[0].kind);
    try std.testing.expectEqual(Kind.update, ev[1].kind);
    try std.testing.expectEqual(@as(usize, 3), ev[1].cursor);
    try std.testing.expectEqualStrings("\u{3042}", ev[1].text);
    try std.testing.expectEqualStrings("\u{3042}\u{3044}", ev[2].text);
}

test "decode: a truncated record is dropped, not read out of bounds" {
    var raw: [14]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], 3, .little);
    std.mem.writeInt(u32, raw[8..12], 100, .little);
    var ev: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), decode(&raw, &ev));
}
