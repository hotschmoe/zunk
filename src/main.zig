const std = @import("std");
const zunk = @import("zunk");

const wa = zunk.gen.wasm_analyze;
const js_gen = zunk.gen.js_gen;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "run")) {
        try buildCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        std.debug.print("zunk 0.1.0\n", .{});
    } else {
        std.debug.print("unknown command: {s}\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zunk <command> [options]
        \\
        \\Commands:
        \\  build    Compile .zig to .wasm, analyze, generate JS + HTML
        \\  run      Build + serve with live reload
        \\  help     Show this help
        \\  version  Show version
        \\
        \\Options:
        \\  --wasm <path>   Path to a pre-compiled .wasm file
        \\
    , .{});
}

fn buildCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const wasm_path = parseWasmPath(args) orelse {
        std.debug.print("error: --wasm <path> required (auto-compile not yet implemented)\n", .{});
        return;
    };

    const wasm = std.fs.cwd().readFileAlloc(allocator, wasm_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("error: could not read '{s}': {}\n", .{ wasm_path, err });
        return;
    };
    defer allocator.free(wasm);

    var analysis = try wa.analyze(allocator, wasm);
    defer analysis.deinit(allocator);

    const wasm_basename = std.fs.path.basename(wasm_path);

    var result = try js_gen.generate(allocator, &analysis, .{
        .wasm_filename = wasm_basename,
    });
    defer result.deinit(allocator);

    const dist_wasm_path = try std.fmt.allocPrint(allocator, "dist/{s}", .{wasm_basename});
    defer allocator.free(dist_wasm_path);

    std.fs.cwd().makePath("dist") catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = "dist/index.html", .data = result.html });
    try std.fs.cwd().writeFile(.{ .sub_path = "dist/app.js", .data = result.js });
    try std.fs.cwd().writeFile(.{ .sub_path = dist_wasm_path, .data = wasm });

    std.debug.print("{s}", .{result.report});
    std.debug.print("\nBuild complete: dist/\n", .{});
}

fn parseWasmPath(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--wasm") and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

test {
    @import("std").testing.refAllDecls(@This());
}
