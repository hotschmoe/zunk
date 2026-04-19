const std = @import("std");

/// Source Map v3 generator.
///
/// Current scope (v1): emit one source per bridge.js chunk. Lines of the
/// generated JS that fall inside a chunk's span are mapped back to the
/// chunk's original source text, so a stack trace from a library-provided
/// bridge.js lands in readable code in devtools. Lines outside bridge spans
/// are left unmapped; browsers fall back to showing the generated JS as-is
/// for those regions, which is exactly what we want.
///
/// Category-level sections (one source per Web API category like canvas /
/// audio / webgpu) are a planned follow-up.
pub const Span = struct {
    /// Label shown in devtools (e.g. the bridge chunk's origin).
    source: []const u8,
    /// Original source content inlined into sourcesContent[].
    source_content: []const u8,
    /// Byte offset in the generated JS where this span's content begins.
    start_byte: usize,
    /// Byte offset in the generated JS where this span's content ends
    /// (exclusive). Must be >= start_byte.
    end_byte: usize,
};

/// Build a Source Map v3 JSON document for the given generated JS.
/// `spans` must be non-empty; caller handles the empty-map case (skip
/// emitting a .js.map entirely).
pub fn build(
    allocator: std.mem.Allocator,
    generated_js: []const u8,
    spans: []const Span,
) ![]const u8 {
    std.debug.assert(spans.len > 0);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"version\":3,\"sources\":[");
    for (spans, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeJsonEscaped(w, s.source);
        try w.writeByte('"');
    }
    try w.writeAll("],\"sourcesContent\":[");
    for (spans, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeJsonEscaped(w, s.source_content);
        try w.writeByte('"');
    }
    try w.writeAll("],\"mappings\":\"");
    try writeMappings(w, generated_js, spans);
    try w.writeAll("\"}");

    return aw.toOwnedSlice();
}

/// Count how many output lines a span occupies. A span that doesn't end
/// with '\n' still occupies a final partial line.
fn countLines(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = 0;
    for (text) |c| if (c == '\n') {
        n += 1;
    };
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

fn byteOffsetToLine(text: []const u8, offset: usize) u32 {
    var line: u32 = 0;
    for (text[0..offset]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

const Section = struct {
    source_index: u32,
    start_line: u32,
    /// exclusive
    end_line: u32,
};

fn writeMappings(
    w: *std.Io.Writer,
    generated_js: []const u8,
    spans: []const Span,
) !void {
    // Convert byte spans to line spans once, in source-index order.
    var sections_buf: [64]Section = undefined;
    std.debug.assert(spans.len <= sections_buf.len);
    var sections = sections_buf[0..spans.len];

    var total_lines: u32 = 0;
    {
        var i: usize = 0;
        while (i < generated_js.len) : (i += 1) {
            if (generated_js[i] == '\n') total_lines += 1;
        }
        // Trailing partial line without newline still counts.
        if (generated_js.len > 0 and generated_js[generated_js.len - 1] != '\n') total_lines += 1;
    }

    for (spans, 0..) |s, i| {
        const start = byteOffsetToLine(generated_js, s.start_byte);
        const span_line_count = countLines(generated_js[s.start_byte..s.end_byte]);
        sections[i] = .{
            .source_index = @intCast(i),
            .start_line = start,
            .end_line = start + span_line_count,
        };
    }

    // Emit mappings: one ';' between generated lines. For lines inside a
    // section, emit a single VLQ segment mapping gen col 0 -> source N,
    // relative line, col 0. For lines outside, emit nothing.
    var last_source_idx: i32 = 0;
    var last_src_line: i32 = 0;

    var line: u32 = 0;
    while (line < total_lines) : (line += 1) {
        if (line > 0) try w.writeByte(';');

        const section = findSection(sections, line) orelse continue;

        const src_idx: i32 = @intCast(section.source_index);
        const rel_src_line: i32 = @intCast(line - section.start_line);

        // Segment values: [col_in_gen, src_idx_delta, src_line_delta, src_col_delta]
        // col_in_gen is reset to 0 each line, so it's always 0.
        // src_col is always 0 in our line-granularity mapping.
        try encodeVlq(w, 0);
        try encodeVlq(w, src_idx - last_source_idx);
        try encodeVlq(w, rel_src_line - last_src_line);
        try encodeVlq(w, 0);

        last_source_idx = src_idx;
        last_src_line = rel_src_line;
    }
}

fn findSection(sections: []const Section, line: u32) ?*const Section {
    for (sections) |*s| {
        if (line >= s.start_line and line < s.end_line) return s;
    }
    return null;
}

const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encodeVlq(w: *std.Io.Writer, value: i32) !void {
    // Base64 VLQ (as specified by source map v3):
    // - Sign goes in the LSB of the unsigned representation.
    // - 5 data bits per base64 digit, continuation bit in the 6th.
    var v: u32 = if (value < 0)
        (@as(u32, @intCast(-value)) << 1) | 1
    else
        @as(u32, @intCast(value)) << 1;

    while (true) {
        var digit: u32 = v & 0b11111;
        v >>= 5;
        if (v != 0) digit |= 0b100000;
        try w.writeByte(base64_chars[digit]);
        if (v == 0) break;
    }
}

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
}

test "vlq zero" {
    var buf: [8]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try encodeVlq(&fw, 0);
    try std.testing.expectEqualStrings("A", fw.buffered());
}

test "vlq positive small" {
    var buf: [8]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try encodeVlq(&fw, 1);
    try std.testing.expectEqualStrings("C", fw.buffered());
}

test "vlq negative small" {
    var buf: [8]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try encodeVlq(&fw, -1);
    try std.testing.expectEqualStrings("D", fw.buffered());
}

test "vlq positive multi-digit" {
    // 16 -> bits 10000, shifted for sign = 100000 -> needs two digits.
    // 16 << 1 = 32 = 0b100000. Low 5 bits = 0, cont bit set -> g.
    // Then v = 1. Low 5 = 1, no cont -> B.
    var buf: [8]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try encodeVlq(&fw, 16);
    try std.testing.expectEqualStrings("gB", fw.buffered());
}

test "countLines basic" {
    try std.testing.expectEqual(@as(u32, 0), countLines(""));
    try std.testing.expectEqual(@as(u32, 1), countLines("foo"));
    try std.testing.expectEqual(@as(u32, 1), countLines("foo\n"));
    try std.testing.expectEqual(@as(u32, 2), countLines("foo\nbar"));
    try std.testing.expectEqual(@as(u32, 2), countLines("foo\nbar\n"));
    try std.testing.expectEqual(@as(u32, 3), countLines("foo\nbar\n\n"));
}

test "build single-span map" {
    const gpa = std.testing.allocator;
    // Generated JS has a banner line, then two bridge lines, then a closing line.
    const generated =
        \\// runtime line 0
        \\// --- bridge.js from teak ---
        \\teakFn1();
        \\teakFn2();
        \\// runtime trailing
    ;
    // Bridge content (verbatim chunk source).
    const bridge = "teakFn1();\nteakFn2();";
    const bridge_start = std.mem.indexOf(u8, generated, bridge).?;
    const bridge_end = bridge_start + bridge.len;

    const json = try build(gpa, generated, &.{.{
        .source = "teak/bridge.js",
        .source_content = bridge,
        .start_byte = bridge_start,
        .end_byte = bridge_end,
    }});
    defer gpa.free(json);

    // Must be valid JSON containing sources + sourcesContent + mappings.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "teak/bridge.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "teakFn1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mappings\":") != null);
}
