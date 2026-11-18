const std = @import("std");

pub const Span = struct {
    source: []const u8,
    source_content: []const u8,
    start_byte: usize,
    end_byte: usize,
};

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
    end_line: u32,
};

fn writeMappings(
    w: *std.Io.Writer,
    generated_js: []const u8,
    spans: []const Span,
) !void {
    var sections_buf: [64]Section = undefined;
    std.debug.assert(spans.len <= sections_buf.len);
    var sections = sections_buf[0..spans.len];

    var total_lines: u32 = 0;
    {
        var i: usize = 0;
        while (i < generated_js.len) : (i += 1) {
            if (generated_js[i] == '\n') total_lines += 1;
        }
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

    var last_source_idx: i32 = 0;
    var last_src_line: i32 = 0;

    var line: u32 = 0;
    while (line < total_lines) : (line += 1) {
        if (line > 0) try w.writeByte(';');

        const section = findSection(sections, line) orelse continue;

        const src_idx: i32 = @intCast(section.source_index);
        const rel_src_line: i32 = @intCast(line - section.start_line);

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
    // Source map v3 uses signed base64 VLQ with five data bits per digit.
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
