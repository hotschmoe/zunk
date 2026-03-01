const std = @import("std");
const rich = @import("rich_zig");

const wa = @import("gen/wasm_analyze.zig");
const js_gen = @import("gen/js_gen.zig");
const dev_server = @import("gen/serve.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var console = rich.Console.init(allocator);
    defer console.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(&console);
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "build")) {
        try buildCommand(allocator, args[2..], false, &console);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try buildCommand(allocator, args[2..], true, &console);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage(&console);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try console.print("[bold cyan]zunk[/] 0.1.0");
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{cmd}) catch "unknown command";
        try console.printStyled(msg, rich.Style.empty.bold().foreground(rich.Color.red));
        try printUsage(&console);
    }
}

fn printUsage(console: *rich.Console) !void {
    try console.print("");
    try console.print("  [bold cyan]zunk[/] -- build tool for Zig WASM applications");
    try console.print("");
    try console.print("  [bold]Usage:[/] zunk <command> \\[options]");
    try console.print("");
    try console.print("  [bold]Commands:[/]");
    try console.print("    [green]build[/]      Compile .wasm, analyze, generate JS + HTML");
    try console.print("    [green]run[/]        Build + serve on localhost");
    try console.print("    [green]help[/]       Show this help");
    try console.print("    [green]version[/]    Show version");
    try console.print("");
    try console.print("  [bold]Options:[/]");
    try console.print("    [yellow]--wasm[/] <path>         Path to a pre-compiled .wasm file");
    try console.print("    [yellow]--output-dir[/] <path>   Output directory (default: dist)");
    try console.print("    [yellow]--port[/] <num>          Server port for 'run' (default: 8080)");
    try console.print("    [yellow]--no-watch[/]             Disable source watching for 'run'");
    try console.print("    [yellow]--proxy[/] <prefix=url>  Proxy requests (e.g. --proxy /api=http://localhost:3000)");
    try console.print("");
}

const BuildArgs = struct {
    wasm_path: ?[]const u8 = null,
    output_dir: []const u8 = "dist",
    port: u16 = 8080,
    watch: bool = true,
    proxy: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, args[i], "--no-watch")) {
            result.watch = false;
        } else if (std.mem.eql(u8, args[i], "--proxy") and i + 1 < args.len) {
            result.proxy = args[i + 1];
            i += 1;
        }
    }
    return result;
}

const ProxyConfig = struct {
    prefix: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

fn parseProxy(arg: ?[]const u8) ProxyConfig {
    const proxy_arg = arg orelse return .{};
    const eq_pos = std.mem.indexOfScalar(u8, proxy_arg, '=') orelse return .{};
    return .{
        .prefix = proxy_arg[0..eq_pos],
        .target = proxy_arg[eq_pos + 1 ..],
    };
}

fn buildCommand(allocator: std.mem.Allocator, args: []const []const u8, do_serve: bool, console: *rich.Console) !void {
    const parsed = parseBuildArgs(args);
    const wasm_path = parsed.wasm_path orelse {
        try console.print("[bold red]error:[/] --wasm <path> required (auto-compile not yet implemented)");
        return;
    };

    const wasm = std.fs.cwd().readFileAlloc(allocator, wasm_path, 10 * 1024 * 1024) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not read '{s}': {}", .{ wasm_path, err }) catch "error: could not read wasm file";
        try console.printStyled(msg, rich.Style.empty.foreground(rich.Color.red));
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

    std.fs.cwd().makePath(parsed.output_dir) catch {};
    var out_dir = try std.fs.cwd().openDir(parsed.output_dir, .{});
    defer out_dir.close();

    try out_dir.writeFile(.{ .sub_path = "index.html", .data = result.html });
    try out_dir.writeFile(.{ .sub_path = "app.js", .data = result.js });
    try out_dir.writeFile(.{ .sub_path = wasm_basename, .data = wasm });

    copyAssets(allocator, out_dir, console);

    try console.print("");
    const report_panel = rich.Panel.fromText(allocator, result.report)
        .withTitle("Build Report")
        .withBorderStyle(rich.Style.empty.foreground(rich.Color.cyan));
    try console.printRenderable(report_panel);

    var complete_buf: [256]u8 = undefined;
    const complete_msg = std.fmt.bufPrint(&complete_buf, "Build complete: {s}/", .{parsed.output_dir}) catch "Build complete";
    try console.printStyled(complete_msg, rich.Style.empty.bold().foreground(rich.Color.green));

    if (do_serve) {
        try console.print("");

        const proxy = parseProxy(parsed.proxy);

        try dev_server.serve(allocator, parsed.output_dir, parsed.port, .{
            .autoreload = true,
            .port = parsed.port,
            .watch_sources = parsed.watch,
            .proxy_prefix = proxy.prefix,
            .proxy_target = proxy.target,
        }, console);
    }
}

fn copyAssets(allocator: std.mem.Allocator, out_dir: std.fs.Dir, console: *rich.Console) void {
    var src_assets = std.fs.cwd().openDir("src/assets", .{ .iterate = true }) catch return;
    defer src_assets.close();

    out_dir.makePath("assets") catch return;
    var dest_assets = out_dir.openDir("assets", .{}) catch return;
    defer dest_assets.close();

    var walker = src_assets.walk(allocator) catch return;
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const data = src_assets.readFileAlloc(allocator, entry.path, 50 * 1024 * 1024) catch continue;
        defer allocator.free(data);
        if (std.fs.path.dirname(entry.path)) |dir| {
            dest_assets.makePath(dir) catch continue;
        }
        dest_assets.writeFile(.{ .sub_path = entry.path, .data = data }) catch continue;
        count += 1;
    }

    if (count > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied {d} asset(s) to output", .{count}) catch return;
        console.printStyled(msg, rich.Style.empty.foreground(rich.Color.cyan)) catch {};
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
