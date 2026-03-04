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
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        try deployCommand(allocator, args[2..], &console);
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
    try console.print("    [green]deploy[/]     Production build with hashed filenames + SRI");
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

const BuildContext = struct {
    wasm: []const u8,
    analysis: wa.Analysis,
    wasm_basename: []const u8,
    bridge_js: ?[]const u8,

    fn deinit(self: *BuildContext, allocator: std.mem.Allocator) void {
        allocator.free(self.wasm);
        self.analysis.deinit(allocator);
        if (self.bridge_js) |b| allocator.free(b);
    }
};

fn prepareBuild(allocator: std.mem.Allocator, parsed: BuildArgs, console: *rich.Console) !?BuildContext {
    const wasm_path = parsed.wasm_path orelse {
        try console.print("[bold red]error:[/] no --wasm path provided");
        try console.print("");
        try console.print("  [bold]Recommended:[/] use installApp() in your build.zig:");
        try console.print("    [cyan]const zunk = @import(\"zunk\");[/]");
        try console.print("    [cyan]zunk.installApp(b, zunk_dep, exe, .{});[/]");
        try console.print("");
        try console.print("  Then run: [green]zig build[/]        (build)");
        try console.print("            [green]zig build run[/]    (build + serve)");
        try console.print("");
        try console.print("  Or pass a .wasm file directly:");
        try console.print("    [yellow]zunk build --wasm path/to/app.wasm[/]");
        try console.print("    [yellow]zunk deploy --wasm path/to/app.wasm[/]");
        return null;
    };

    const wasm = std.fs.cwd().readFileAlloc(allocator, wasm_path, 10 * 1024 * 1024) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not read '{s}': {}", .{ wasm_path, err }) catch "error: could not read wasm file";
        try console.printStyled(msg, rich.Style.empty.foreground(rich.Color.red));
        return null;
    };
    errdefer allocator.free(wasm);

    var analysis = try wa.analyze(allocator, wasm);
    errdefer analysis.deinit(allocator);

    return .{
        .wasm = wasm,
        .analysis = analysis,
        .wasm_basename = std.fs.path.basename(wasm_path),
        .bridge_js = discoverBridgeJs(allocator, console),
    };
}

fn contentFingerprint(data: []const u8) [8]u8 {
    const hash = std.hash.XxHash3.hash(0, data);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, hash, .big);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return hex[0..8].*;
}

fn computeSri(data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const Sha384 = std.crypto.hash.sha2.Sha384;
    var sha_digest: [Sha384.digest_length]u8 = undefined;
    Sha384.hash(data, &sha_digest, .{});
    const b64_enc = std.base64.standard.Encoder;
    var b64_buf: [b64_enc.calcSize(Sha384.digest_length)]u8 = undefined;
    _ = b64_enc.encode(&b64_buf, &sha_digest);
    return std.fmt.allocPrint(allocator, "sha384-{s}", .{&b64_buf});
}

fn openOutputDir(parsed: BuildArgs) !std.fs.Dir {
    std.fs.cwd().makePath(parsed.output_dir) catch {};
    return std.fs.cwd().openDir(parsed.output_dir, .{});
}

fn printReport(console: *rich.Console, allocator: std.mem.Allocator, report: []const u8, title: []const u8) !void {
    try console.print("");
    const panel = rich.Panel.fromText(allocator, report)
        .withTitle(title)
        .withBorderStyle(rich.Style.empty.foreground(rich.Color.cyan));
    try console.printRenderable(panel);
}

fn buildCommand(allocator: std.mem.Allocator, args: []const []const u8, do_serve: bool, console: *rich.Console) !void {
    const parsed = parseBuildArgs(args);
    var ctx = try prepareBuild(allocator, parsed, console) orelse return;
    defer ctx.deinit(allocator);

    var result = try js_gen.generate(allocator, &ctx.analysis, .{
        .wasm_filename = ctx.wasm_basename,
        .bridge_js = ctx.bridge_js,
    });
    defer result.deinit(allocator);

    var out_dir = try openOutputDir(parsed);
    defer out_dir.close();

    try out_dir.writeFile(.{ .sub_path = "index.html", .data = result.html });
    try out_dir.writeFile(.{ .sub_path = "app.js", .data = result.js });
    try out_dir.writeFile(.{ .sub_path = ctx.wasm_basename, .data = ctx.wasm });

    copyAssets(allocator, out_dir, console);
    try printReport(console, allocator, result.report, "Build Report");

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

fn deployCommand(allocator: std.mem.Allocator, args: []const []const u8, console: *rich.Console) !void {
    const parsed = parseBuildArgs(args);
    var ctx = try prepareBuild(allocator, parsed, console) orelse return;
    defer ctx.deinit(allocator);

    // Content-hashed WASM filename
    const wasm_fp = contentFingerprint(ctx.wasm);
    const wasm_ext = std.fs.path.extension(ctx.wasm_basename);
    const wasm_stem = ctx.wasm_basename[0 .. ctx.wasm_basename.len - wasm_ext.len];
    const hashed_wasm_name = try std.fmt.allocPrint(allocator, "{s}-{s}.wasm", .{ wasm_stem, &wasm_fp });
    defer allocator.free(hashed_wasm_name);

    // Generate JS (only needs hashed wasm name -- JS content is independent of its own filename)
    var result = try js_gen.generate(allocator, &ctx.analysis, .{
        .wasm_filename = hashed_wasm_name,
        .bridge_js = ctx.bridge_js,
    });
    defer result.deinit(allocator);

    // Content-hashed JS filename + SRI
    const js_fp = contentFingerprint(result.js);
    const hashed_js_name = try std.fmt.allocPrint(allocator, "app-{s}.js", .{&js_fp});
    defer allocator.free(hashed_js_name);

    const sri = try computeSri(result.js, allocator);
    defer allocator.free(sri);

    // Generate deploy HTML directly (avoids a redundant second full generation pass)
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try js_gen.generateHtml(html.writer(allocator), &ctx.analysis, .{
        .wasm_filename = hashed_wasm_name,
        .bridge_js = ctx.bridge_js,
        .js_filename = hashed_js_name,
        .wasm_preload = true,
        .js_integrity = sri,
    }, result.categories);
    const deploy_html = try html.toOwnedSlice(allocator);
    defer allocator.free(deploy_html);

    // Write output
    var out_dir = try openOutputDir(parsed);
    defer out_dir.close();

    try out_dir.writeFile(.{ .sub_path = "index.html", .data = deploy_html });
    try out_dir.writeFile(.{ .sub_path = hashed_js_name, .data = result.js });
    try out_dir.writeFile(.{ .sub_path = hashed_wasm_name, .data = ctx.wasm });

    copyAssets(allocator, out_dir, console);
    try printReport(console, allocator, result.report, "Deploy Report");

    try console.print("");
    try console.printStyled("Deploy artifacts:", rich.Style.empty.bold().foreground(rich.Color.green));
    {
        var pbuf: [256]u8 = undefined;
        const m1 = std.fmt.bufPrint(&pbuf, "  {s}/index.html", .{parsed.output_dir}) catch "";
        try console.print(m1);
        const m2 = std.fmt.bufPrint(&pbuf, "  {s}/{s}", .{ parsed.output_dir, hashed_js_name }) catch "";
        try console.print(m2);
        const m3 = std.fmt.bufPrint(&pbuf, "  {s}/{s}", .{ parsed.output_dir, hashed_wasm_name }) catch "";
        try console.print(m3);
    }

    try console.print("");
    var complete_buf: [256]u8 = undefined;
    const complete_msg = std.fmt.bufPrint(&complete_buf, "Deploy build complete: {s}/", .{parsed.output_dir}) catch "Deploy complete";
    try console.printStyled(complete_msg, rich.Style.empty.bold().foreground(rich.Color.green));
}

fn discoverBridgeJs(allocator: std.mem.Allocator, console: *rich.Console) ?[]const u8 {
    const paths = [_][]const u8{ "bridge.js", "js/bridge.js" };
    for (paths) |path| {
        if (std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024)) |contents| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Found {s}", .{path}) catch "Found bridge.js";
            console.printStyled(msg, rich.Style.empty.foreground(rich.Color.cyan)) catch {};
            return contents;
        } else |_| {}
    }
    return null;
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
