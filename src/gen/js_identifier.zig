const std = @import("std");
const assert = @import("../assert.zig").assert;

const Range = struct { first: u32, last: u32 };
const search_steps_max: u8 = 11;

pub fn is_plain(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));
    if (name.len == 0) return false;
    var position: u32 = 0;
    for (0..name.len) |index| {
        if (position == name.len) break;
        const value = codepoint(name, &position) orelse return false;
        if (value == '$' or value == '_') continue;
        if (contains(value, &start_ranges)) continue;
        if (index == 0) return false;
        if (value == 0x200c or value == 0x200d) continue;
        if (!contains(value, &continue_ranges)) return false;
    }
    assert(position == name.len);
    return !is_reserved(name);
}

fn codepoint(bytes: []const u8, position: *u32) ?u21 {
    assert(position.* < bytes.len);
    const length = std.unicode.utf8ByteSequenceLength(bytes[position.*]) catch return null;
    if (length > bytes.len - position.*) return null;
    const value = std.unicode.utf8Decode(bytes[position.*..][0..length]) catch return null;
    position.* += length;
    assert(position.* <= bytes.len);
    return value;
}

fn contains(value: u21, ranges: []const Range) bool {
    assert(value <= 0x10ffff);
    assert(ranges.len > 0 and ranges.len <= 1024);
    var lower: u32 = 0;
    var upper: u32 = @intCast(ranges.len);
    for (0..search_steps_max) |_| {
        if (lower == upper) return false;
        const middle = lower + (upper - lower) / 2;
        const range = ranges[middle];
        if (value < range.first) {
            upper = middle;
        } else if (value > range.last) {
            lower = middle + 1;
        } else return true;
    }
    assert(lower == upper);
    return false;
}

fn is_reserved(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= std.math.maxInt(u32));
    const reserved = [_][]const u8{
        "await",
        "break",
        "case",
        "catch",
        "class",
        "const",
        "continue",
        "debugger",
        "default",
        "delete",
        "do",
        "else",
        "enum",
        "export",
        "extends",
        "false",
        "finally",
        "for",
        "function",
        "if",
        "implements",
        "import",
        "in",
        "instanceof",
        "interface",
        "let",
        "new",
        "null",
        "package",
        "private",
        "protected",
        "public",
        "return",
        "static",
        "super",
        "switch",
        "this",
        "throw",
        "true",
        "try",
        "typeof",
        "var",
        "void",
        "while",
        "with",
        "yield",
    };
    for (reserved) |word| if (std.mem.eql(u8, name, word)) return true;
    return false;
}

fn decode_ranges(comptime encoded: []const u8, comptime count: u16) [count]Range {
    @setEvalBranchQuota(1000000);
    assert(encoded.len > 0);
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch @compileError("invalid identifier data");
    var bytes: [size]u8 = undefined;
    decoder.decode(&bytes, encoded) catch @compileError("invalid identifier data");
    var position: u32 = 0;
    var previous: u32 = 0;
    var ranges: [count]Range = undefined;
    for (&ranges) |*range| {
        const first = previous + integer(&bytes, &position);
        const last = first + integer(&bytes, &position);
        assert(last <= 0x10ffff);
        range.* = .{ .first = first, .last = last };
        previous = last + 1;
    }
    assert(position == bytes.len);
    return ranges;
}

fn integer(bytes: []const u8, position: *u32) u32 {
    assert(position.* < bytes.len);
    var result: u32 = 0;
    for (0..4) |index| {
        assert(position.* < bytes.len);
        const byte = bytes[position.*];
        position.* += 1;
        result |= @as(u32, byte & 127) << @as(u5, @intCast(index * 7));
        if (byte < 128) return result;
    }
    assert(false);
    return 0;
}

const start_ranges = decode_ranges(start_data, 684);
const continue_ranges = decode_ranges(continue_data, 400);

// Unicode 17.0 ID_Start and ID_Continue: https://tc39.es/ecma262/#prod-IdentifierStart
const start_data =
    "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";

const continue_data =
    "MAklAFcAyARvFwD7AQSJAiwBAAEBAQEBAEgKMB4GAGUGAgUCAQEDAgkXAB4aWwoPCSEICQAYAwEIAQIB" ++
    "BCsCOwgqFwEgNgIBEQEGCgECCRECOAABBgIBAgIJAAoBAgkOAAICOAABBAQBAgIDABQLAwALAjgAAQcB" ++
    "AgECFAECCQoFAQI4AAEGAgECAgcCCgECCRIAOwQDAgEDCQAOCRAENwABBgECAQMHAQsBAgkRAjgAAQYB" ++
    "AgEDBwELAQIJAwAMAzcBAQYBAgEDCQAKAQIJEQJGAAQFAQABBwYJAgE9AAIGDAcBCVcAAggLBgEJPgEG" ++
    "CQsAAQABAAQBMRMBAQUKASMJAGQTAQkMAwQCAQICBgMDDQsBDr8FAgkIoAcDHAIdAR4BQB8JAAIJIQIB" ++
    "Co8BAHYLBAsKCYABCjwEOQkBHAIKBgkWDQEeAgsUBC8QCwkRCAwCHgwCCSwNMBMICQYJdgIBFAQABgAC" ++
    "AsYBP4wEATEBEwB7DAQAAwv+FwKNAQBgH6oEBWkBYACk6gEJRQAECSABUAGQAgADAAQAFwQEAFMBMhEK" ++
    "CQYRDQocBxkMLAMvDQ8JCwAKCS8NDAAIAQIJIQIyAAECAgEFAQEAKQQFAewBBwEBAgmkngEA4QUPEA8D" ++
    "ARgCwAEJJQAlAJcFAOIBAJUBBKUCCdcKAgEBBQMoAgQApQEBvQQDCAkGCR8EvQIBTQVGCjEDegI1Dh8K" ++
    "AgEKAy0KBwAtCQYCJA0BCQUBLAAMAjANCAMBC1ILBgACAJ0BCwUJBgM3AQEGAgECAgkACgECBgMEQwgB" ++
    "AAIAAQMBBAEADgFSEQkJBABREwwJ1QEGAggbAVIQDwlRDAgJBhM5DgQJ8gEOpQEJRgUBAQIDAQABAQwJ" ++
    "dwYCBgMAHAkoBgEDCAAJCi4PxgEHiAEJNQcBBxAJOBUBDXoFAwABAQEGAQAICTAEAQEBBAgJNgmJAgMJ" ++
    "AQEAMAYDBA0K5SkABg7IWRumEglWCSYEOwYZCZYECdUDAAE2BwNRAAsBq5kBAdEgCYYELQIWngQEAwUI" ++
    "BwIGHgOUAQKJCzGABDYEMQgADgAWBAEO0AoGARACBgEBAQRkAKABBgkJ5AIAPQ3yAw30AQEBCegBAAIA" ++
    "BwEFANoDBm0GBQmWJQmGijDvAQ==";
