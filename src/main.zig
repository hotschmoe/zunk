const std = @import("std");

const wa = @import("gen/wasm_analyze.zig");
const js_gen = @import("gen/js_gen.zig");
const dev_server = @import("gen/serve.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "build")) {
        try buildCommand(allocator, args[2..], false);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try buildCommand(allocator, args[2..], true);
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
        \\  build    Compile .wasm, analyze, generate JS + HTML
        \\  run      Build + serve on localhost
        \\  help     Show this help
        \\  version  Show version
        \\
        \\Options:
        \\  --wasm <path>         Path to a pre-compiled .wasm file
        \\  --output-dir <path>   Output directory (default: dist)
        \\  --port <num>          Server port for 'run' (default: 8080)
        \\
    , .{});
}

const BuildArgs = struct {
    wasm_path: ?[]const u8 = null,
    output_dir: []const u8 = "dist",
    port: u16 = 8080,
};

fn parseBuildArgs(args: []const []const u8) BuildArgs {
    var result = BuildArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--wasm") and i + 1 < args.len) {
            result.wasm_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            result.output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            result.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        }
    }
    return result;
}

fn buildCommand(allocator: std.mem.Allocator, args: []const []const u8, do_serve: bool) !void {
    const parsed = parseBuildArgs(args);
    const wasm_path = parsed.wasm_path orelse {
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
        .autoreload = do_serve,
        .autoreload_port = parsed.port,
    });
    defer result.deinit(allocator);

    std.fs.cwd().makePath(parsed.output_dir) catch {};
    var out_dir = try std.fs.cwd().openDir(parsed.output_dir, .{});
    defer out_dir.close();

    try out_dir.writeFile(.{ .sub_path = "index.html", .data = result.html });
    try out_dir.writeFile(.{ .sub_path = "app.js", .data = result.js });
    try out_dir.writeFile(.{ .sub_path = wasm_basename, .data = wasm });

    std.debug.print("{s}\nBuild complete: {s}/\n", .{ result.report, parsed.output_dir });

    if (do_serve) {
        try dev_server.serve(allocator, parsed.output_dir, parsed.port, true);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
