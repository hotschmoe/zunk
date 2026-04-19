const std = @import("std");
const rich = @import("rich_zig");

const wa = @import("gen/wasm_analyze.zig");
const js_gen = @import("gen/js_gen.zig");
const dev_server = @import("gen/serve.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var console = rich.Console.init(gpa, io, init.minimal.environ);
    defer console.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try printUsage(&console);
        return;
    }

    const cmd = args[1];
    const rest: []const []const u8 = @ptrCast(args[2..]);

    if (std.mem.eql(u8, cmd, "build")) {
        try buildCommand(gpa, io, rest, false, &console);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try buildCommand(gpa, io, rest, true, &console);
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        try deployCommand(gpa, io, rest, &console);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try initCommand(io, rest, &console);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try doctorCommand(gpa, io, &console);
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
    try console.print("    [green]init[/]       Scaffold a new zunk project");
    try console.print("    [green]doctor[/]     Check environment and project health");
    try console.print("    [green]help[/]       Show this help");
    try console.print("    [green]version[/]    Show version");
    try console.print("");
    try console.print("  [bold]Options:[/]");
    try console.print("    [yellow]--wasm[/] <path>         Path to a pre-compiled .wasm file");
    try console.print("    [yellow]--output-dir[/] <path>   Output directory (default: dist)");
    try console.print("    [yellow]--port[/] <num>          Server port for 'run' (default: 8080)");
    try console.print("    [yellow]--no-watch[/]             Disable source watching for 'run'");
    try console.print("    [yellow]--hmr[/]                  Hot-swap WASM on wasm-only rebuilds (opt-in; full reload fallback)");
    try console.print("    [yellow]--proxy[/] <prefix=url>  Proxy requests (e.g. --proxy /api=http://localhost:3000)");
    try console.print("    [yellow]--bridge-dep[/] <path>    Include a dep-provided bridge.js (repeatable; typically wired by installApp)");
    try console.print("    [yellow]--verbose[/] / [yellow]-v[/]        Show all resolutions in build report");
    try console.print("    [yellow]--report-json[/]          Output build report as JSON");
    try console.print("    [yellow]--force[/]                Bypass build cache");
    try console.print("");
}

const max_bridge_deps = 32;

const BuildArgs = struct {
    wasm_path: ?[]const u8 = null,
    output_dir: []const u8 = "dist",
    port: u16 = 8080,
    watch: bool = true,
    proxy: ?[]const u8 = null,
    verbose: bool = false,
    json_report: bool = false,
    force: bool = false,
    hmr: bool = false,
    bridge_deps_buf: [max_bridge_deps][]const u8 = undefined,
    bridge_deps_len: usize = 0,

    fn bridgeDeps(self: *const BuildArgs) []const []const u8 {
        return self.bridge_deps_buf[0..self.bridge_deps_len];
    }
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
        } else if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, args[i], "--report-json")) {
            result.json_report = true;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, args[i], "--hmr")) {
            result.hmr = true;
        } else if (std.mem.eql(u8, args[i], "--proxy") and i + 1 < args.len) {
            result.proxy = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bridge-dep") and i + 1 < args.len) {
            if (result.bridge_deps_len < max_bridge_deps) {
                result.bridge_deps_buf[result.bridge_deps_len] = args[i + 1];
                result.bridge_deps_len += 1;
            }
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
    const eq_pos = std.mem.findScalar(u8, proxy_arg, '=') orelse return .{};
    return .{
        .prefix = proxy_arg[0..eq_pos],
        .target = proxy_arg[eq_pos + 1 ..],
    };
}

const bridge_js_paths = [_][]const u8{ "bridge.js", "js/bridge.js" };

const BuildContext = struct {
    wasm: []const u8,
    analysis: wa.Analysis,
    wasm_basename: []const u8,
    bridge_chunks: []js_gen.BridgeJsChunk,

    fn deinit(self: *BuildContext, allocator: std.mem.Allocator) void {
        allocator.free(self.wasm);
        self.analysis.deinit(allocator);
        for (self.bridge_chunks) |c| {
            allocator.free(c.origin);
            allocator.free(c.source);
        }
        allocator.free(self.bridge_chunks);
    }
};

fn prepareBuild(allocator: std.mem.Allocator, io: std.Io, parsed: BuildArgs, console: *rich.Console) !?BuildContext {
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

    const wasm = std.Io.Dir.cwd().readFileAlloc(io, wasm_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not read '{s}': {}", .{ wasm_path, err }) catch "error: could not read wasm file";
        try console.printStyled(msg, rich.Style.empty.foreground(rich.Color.red));
        return null;
    };
    errdefer allocator.free(wasm);

    var analysis = try wa.analyze(allocator, wasm);
    errdefer analysis.deinit(allocator);

    const bridge_chunks = try collectBridgeChunks(allocator, io, parsed.bridgeDeps(), console);
    errdefer {
        for (bridge_chunks) |c| {
            allocator.free(c.origin);
            allocator.free(c.source);
        }
        allocator.free(bridge_chunks);
    }

    return .{
        .wasm = wasm,
        .analysis = analysis,
        .wasm_basename = std.Io.Dir.path.basename(wasm_path),
        .bridge_chunks = bridge_chunks,
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

fn openOutputDir(io: std.Io, parsed: BuildArgs) !std.Io.Dir {
    std.Io.Dir.cwd().createDirPath(io, parsed.output_dir) catch {};
    return std.Io.Dir.cwd().openDir(io, parsed.output_dir, .{});
}

fn printReport(console: *rich.Console, allocator: std.mem.Allocator, report: []const u8, title: []const u8, json_mode: bool) !void {
    if (json_mode) {
        try console.print(report);
        return;
    }
    try console.print("");
    const panel = rich.Panel.fromText(allocator, report)
        .withTitle(title)
        .withBorderStyle(rich.Style.empty.foreground(rich.Color.cyan));
    try console.printRenderable(panel);
}

fn buildCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, do_serve: bool, console: *rich.Console) !void {
    const parsed = parseBuildArgs(args);

    // Compute fingerprint once (used for both cache check and write)
    const source_fp: ?i128 = if (parsed.wasm_path) |wasm_path| computeSourceFingerprint(io, wasm_path, parsed.bridgeDeps()) else null;

    // Cache check (non-serve mode only)
    if (!do_serve and !parsed.force) {
        if (source_fp) |fp| {
            if (readCacheFingerprint(io, parsed.output_dir)) |cached| {
                if (fp == cached) {
                    try console.printStyled("Build is up to date (use --force to rebuild)", rich.Style.empty.bold().foreground(rich.Color.green));
                    return;
                }
            }
        }
    }

    var ctx = try prepareBuild(allocator, io, parsed, console) orelse return;
    defer ctx.deinit(allocator);

    var result = try js_gen.generate(allocator, &ctx.analysis, .{
        .wasm_filename = ctx.wasm_basename,
        .bridge_js_chunks = ctx.bridge_chunks,
        .verbose_report = parsed.verbose,
        .json_report = parsed.json_report,
    });
    defer result.deinit(allocator);

    var out_dir = try openOutputDir(io, parsed);
    defer out_dir.close(io);

    try out_dir.writeFile(io, .{ .sub_path = "index.html", .data = result.html });

    // JS + optional sourceMappingURL trailer + optional .js.map sidecar.
    const final_js = if (result.js_map.len != 0)
        try std.fmt.allocPrint(allocator, "{s}\n//# sourceMappingURL=app.js.map\n", .{result.js})
    else
        try allocator.dupe(u8, result.js);
    defer allocator.free(final_js);
    try out_dir.writeFile(io, .{ .sub_path = "app.js", .data = final_js });
    if (result.js_map.len != 0) {
        try out_dir.writeFile(io, .{ .sub_path = "app.js.map", .data = result.js_map });
    }

    try out_dir.writeFile(io, .{ .sub_path = ctx.wasm_basename, .data = ctx.wasm });

    copyAssets(allocator, io, out_dir, console);
    try printReport(console, allocator, result.report, "Build Report", parsed.json_report);

    if (!do_serve) {
        if (source_fp) |fp| writeCacheFingerprint(io, parsed.output_dir, fp);
    }

    if (!parsed.json_report) {
        var complete_buf: [256]u8 = undefined;
        const complete_msg = std.fmt.bufPrint(&complete_buf, "Build complete: {s}/", .{parsed.output_dir}) catch "Build complete";
        try console.printStyled(complete_msg, rich.Style.empty.bold().foreground(rich.Color.green));
    }

    if (do_serve) {
        try console.print("");

        const proxy = parseProxy(parsed.proxy);

        try dev_server.serve(allocator, io, parsed.output_dir, parsed.port, .{
            .autoreload = true,
            .port = parsed.port,
            .watch_sources = parsed.watch,
            .proxy_prefix = proxy.prefix,
            .proxy_target = proxy.target,
            .hmr = parsed.hmr,
        }, console);
    }
}

fn deployCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, console: *rich.Console) !void {
    const parsed = parseBuildArgs(args);

    const source_fp: ?i128 = if (parsed.wasm_path) |wasm_path| computeSourceFingerprint(io, wasm_path, parsed.bridgeDeps()) else null;

    if (!parsed.force) {
        if (source_fp) |fp| {
            if (readCacheFingerprint(io, parsed.output_dir)) |cached| {
                if (fp == cached) {
                    try console.printStyled("Deploy is up to date (use --force to rebuild)", rich.Style.empty.bold().foreground(rich.Color.green));
                    return;
                }
            }
        }
    }

    var ctx = try prepareBuild(allocator, io, parsed, console) orelse return;
    defer ctx.deinit(allocator);

    // Content-hashed WASM filename
    const wasm_fp = contentFingerprint(ctx.wasm);
    const wasm_ext = std.Io.Dir.path.extension(ctx.wasm_basename);
    const wasm_stem = ctx.wasm_basename[0 .. ctx.wasm_basename.len - wasm_ext.len];
    const hashed_wasm_name = try std.fmt.allocPrint(allocator, "{s}-{s}.wasm", .{ wasm_stem, &wasm_fp });
    defer allocator.free(hashed_wasm_name);

    // Generate JS (only needs hashed wasm name -- JS content is independent of its own filename)
    var result = try js_gen.generate(allocator, &ctx.analysis, .{
        .wasm_filename = hashed_wasm_name,
        .bridge_js_chunks = ctx.bridge_chunks,
        .verbose_report = parsed.verbose,
        .json_report = parsed.json_report,
    });
    defer result.deinit(allocator);

    // Content-hashed JS filename is derived from result.js BEFORE the
    // sourceMappingURL trailer so the hash is stable regardless of map
    // emission. SRI, however, must cover the exact bytes served, so it is
    // computed against `final_js` below.
    const js_fp = contentFingerprint(result.js);
    const hashed_js_name = try std.fmt.allocPrint(allocator, "app-{s}.js", .{&js_fp});
    defer allocator.free(hashed_js_name);

    const hashed_map_name = try std.fmt.allocPrint(allocator, "{s}.map", .{hashed_js_name});
    defer allocator.free(hashed_map_name);

    const final_js = if (result.js_map.len != 0)
        try std.fmt.allocPrint(allocator, "{s}\n//# sourceMappingURL={s}\n", .{ result.js, hashed_map_name })
    else
        try allocator.dupe(u8, result.js);
    defer allocator.free(final_js);

    const sri = try computeSri(final_js, allocator);
    defer allocator.free(sri);

    // Generate deploy HTML directly (avoids a redundant second full generation pass)
    var html_aw: std.Io.Writer.Allocating = .init(allocator);
    defer html_aw.deinit();
    try js_gen.generateHtml(&html_aw.writer, &ctx.analysis, .{
        .wasm_filename = hashed_wasm_name,
        .bridge_js_chunks = ctx.bridge_chunks,
        .js_filename = hashed_js_name,
        .wasm_preload = true,
        .js_integrity = sri,
    }, result.categories);
    const deploy_html = try html_aw.toOwnedSlice();
    defer allocator.free(deploy_html);

    // Write output
    var out_dir = try openOutputDir(io, parsed);
    defer out_dir.close(io);

    try out_dir.writeFile(io, .{ .sub_path = "index.html", .data = deploy_html });
    try out_dir.writeFile(io, .{ .sub_path = hashed_js_name, .data = final_js });
    if (result.js_map.len != 0) {
        try out_dir.writeFile(io, .{ .sub_path = hashed_map_name, .data = result.js_map });
    }
    try out_dir.writeFile(io, .{ .sub_path = hashed_wasm_name, .data = ctx.wasm });

    copyAssets(allocator, io, out_dir, console);
    try printReport(console, allocator, result.report, "Deploy Report", parsed.json_report);

    if (source_fp) |fp| writeCacheFingerprint(io, parsed.output_dir, fp);

    if (!parsed.json_report) {
        try console.print("");
        try console.printStyled("Deploy artifacts:", rich.Style.empty.bold().foreground(rich.Color.green));
        {
            var pbuf: [256]u8 = undefined;
            const m1 = std.fmt.bufPrint(&pbuf, "  {s}/index.html", .{parsed.output_dir}) catch "";
            try console.print(m1);
            const m2 = std.fmt.bufPrint(&pbuf, "  {s}/{s}", .{ parsed.output_dir, hashed_js_name }) catch "";
            try console.print(m2);
            if (result.js_map.len != 0) {
                const m_map = std.fmt.bufPrint(&pbuf, "  {s}/{s}", .{ parsed.output_dir, hashed_map_name }) catch "";
                try console.print(m_map);
            }
            const m3 = std.fmt.bufPrint(&pbuf, "  {s}/{s}", .{ parsed.output_dir, hashed_wasm_name }) catch "";
            try console.print(m3);
        }

        try console.print("");
        var complete_buf: [256]u8 = undefined;
        const complete_msg = std.fmt.bufPrint(&complete_buf, "Deploy build complete: {s}/", .{parsed.output_dir}) catch "Deploy complete";
        try console.printStyled(complete_msg, rich.Style.empty.bold().foreground(rich.Color.green));
    }
}

/// Derive a short human-readable label for a dep-provided bridge.js.
/// Example: `.../zig-pkg/teak-0.1.0-HASH/bridge.js` -> `teak-0.1.0-HASH`.
/// The label is only used for banner comments in the merged JS, so being
/// verbose is fine -- debuggability > brevity.
fn depBridgeOrigin(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.path.dirname(path) orelse return allocator.dupe(u8, path);
    const base = std.Io.Dir.path.basename(dir);
    if (base.len == 0) return allocator.dupe(u8, path);
    return allocator.dupe(u8, base);
}

/// Builds the ordered list of bridge.js chunks passed to the generator.
/// Order: every `--bridge-dep` path, in CLI order, followed by the first
/// matching user project path (`bridge.js` then `js/bridge.js`). User-
/// provided chunks come last so they can override dep-provided symbols.
fn collectBridgeChunks(
    allocator: std.mem.Allocator,
    io: std.Io,
    bridge_dep_paths: []const []const u8,
    console: *rich.Console,
) ![]js_gen.BridgeJsChunk {
    var chunks: std.ArrayList(js_gen.BridgeJsChunk) = .empty;
    errdefer {
        for (chunks.items) |c| {
            allocator.free(c.origin);
            allocator.free(c.source);
        }
        chunks.deinit(allocator);
    }

    // Dep-provided chunks first.
    for (bridge_dep_paths) |dep_path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, dep_path, allocator, .limited(1 * 1024 * 1024)) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: --bridge-dep '{s}' could not be read: {}", .{ dep_path, err }) catch "error: --bridge-dep unreadable";
            console.printStyled(msg, rich.Style.empty.foreground(rich.Color.red)) catch {};
            return error.BridgeDepMissing;
        };
        errdefer allocator.free(source);

        const origin = try depBridgeOrigin(allocator, dep_path);
        errdefer allocator.free(origin);

        try chunks.append(allocator, .{ .origin = origin, .source = source });

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Found bridge.js from {s}", .{origin}) catch "Found dep bridge.js";
        console.printStyled(msg, rich.Style.empty.foreground(rich.Color.cyan)) catch {};
    }

    // User project bridge.js (first matching path wins, appended last so it overrides deps).
    for (bridge_js_paths) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 * 1024 * 1024)) catch continue;
        errdefer allocator.free(source);

        const origin = try allocator.dupe(u8, path);
        errdefer allocator.free(origin);

        try chunks.append(allocator, .{ .origin = origin, .source = source });

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Found {s}", .{path}) catch "Found bridge.js";
        console.printStyled(msg, rich.Style.empty.foreground(rich.Color.cyan)) catch {};
        break;
    }

    return try chunks.toOwnedSlice(allocator);
}

fn copyAssets(allocator: std.mem.Allocator, io: std.Io, out_dir: std.Io.Dir, console: *rich.Console) void {
    var src_assets = std.Io.Dir.cwd().openDir(io, "src/assets", .{ .iterate = true }) catch return;
    defer src_assets.close(io);

    out_dir.createDirPath(io, "assets") catch return;
    var dest_assets = out_dir.openDir(io, "assets", .{}) catch return;
    defer dest_assets.close(io);

    var walker = src_assets.walk(allocator) catch return;
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const data = src_assets.readFileAlloc(io, entry.path, allocator, .limited(50 * 1024 * 1024)) catch continue;
        defer allocator.free(data);
        if (std.Io.Dir.path.dirname(entry.path)) |dir| {
            dest_assets.createDirPath(io, dir) catch continue;
        }
        dest_assets.writeFile(io, .{ .sub_path = entry.path, .data = data }) catch continue;
        count += 1;
    }

    if (count > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied {d} asset(s) to output", .{count}) catch return;
        console.printStyled(msg, rich.Style.empty.foreground(rich.Color.cyan)) catch {};
    }
}

// --- Build caching ---

fn computeSourceFingerprint(io: std.Io, wasm_path: []const u8, bridge_dep_paths: []const []const u8) i128 {
    var fingerprint: i128 = 0;

    // src/ directory recursive mtime sum
    pollDirRecursive(io, "src", &fingerprint);

    // build.zig and build.zig.zon
    const build_files = [_][]const u8{ "build.zig", "build.zig.zon" };
    for (build_files) |file_path| {
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    // WASM file itself
    {
        const file = std.Io.Dir.cwd().openFile(io, wasm_path, .{}) catch return fingerprint;
        defer file.close(io);
        const stat = file.stat(io) catch return fingerprint;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    // user project bridge.js (if present)
    for (bridge_js_paths) |bp| {
        const file = std.Io.Dir.cwd().openFile(io, bp, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    // dep-provided bridge.js files passed via --bridge-dep
    for (bridge_dep_paths) |bp| {
        const file = std.Io.Dir.cwd().openFile(io, bp, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    return fingerprint;
}

fn pollDirRecursive(io: std.Io, dir_path: []const u8, fingerprint: *i128) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            pollDirRecursive(io, sub_path, fingerprint);
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".zig")) {
                const file = dir.openFile(io, entry.name, .{}) catch continue;
                defer file.close(io);
                const stat = file.stat(io) catch continue;
                fingerprint.* +%= @intCast(stat.mtime.nanoseconds);
            }
        }
    }
}

const cache_filename = ".zunk_cache";

fn readCacheFingerprint(io: std.Io, output_dir: []const u8) ?i128 {
    var dir = std.Io.Dir.cwd().openDir(io, output_dir, .{}) catch return null;
    defer dir.close(io);
    const file = dir.openFile(io, cache_filename, .{}) catch return null;
    defer file.close(io);
    var buf: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    if (n != 16) return null;
    return std.mem.readInt(i128, &buf, .little);
}

fn writeCacheFingerprint(io: std.Io, output_dir: []const u8, fingerprint: i128) void {
    var dir = std.Io.Dir.cwd().openDir(io, output_dir, .{}) catch return;
    defer dir.close(io);
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(i128, &bytes, fingerprint, .little);
    dir.writeFile(io, .{ .sub_path = cache_filename, .data = &bytes }) catch {};
}

// --- Doctor command ---

const DoctorStatus = enum { ok, warn, fail };

const DoctorCheck = struct {
    name: []const u8,
    status: DoctorStatus,
    detail: []const u8,
};

fn doctorCommand(allocator: std.mem.Allocator, io: std.Io, console: *rich.Console) !void {
    var checks: [4]DoctorCheck = undefined;
    var check_count: usize = 0;

    // 1. Zig version. We copy the trimmed version into a static buffer because
    // `result.stdout` is freed before `checks` is printed below.
    var zig_ver_buf: [64]u8 = undefined;
    var zig_check = DoctorCheck{ .name = "zig version", .status = .fail, .detail = "not found" };
    if (std.process.run(allocator, io, .{ .argv = &.{ "zig", "version" } })) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const ver = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (ver.len > 0) {
            const n = @min(ver.len, zig_ver_buf.len);
            @memcpy(zig_ver_buf[0..n], ver[0..n]);
            zig_check.detail = zig_ver_buf[0..n];
            zig_check.status = if (checkZigVersion(zig_check.detail)) .ok else .fail;
        }
    } else |_| {}
    checks[check_count] = zig_check;
    check_count += 1;

    // 2. wasm32 target
    checks[check_count] = .{
        .name = "wasm32 target",
        .status = if (zig_check.status == .ok) .ok else .fail,
        .detail = if (zig_check.status == .ok) "available (bundled with zig)" else "requires zig",
    };
    check_count += 1;

    // 3. Project structure
    const project_files = [_]struct { name: []const u8, required: bool }{
        .{ .name = "build.zig", .required = true },
        .{ .name = "build.zig.zon", .required = true },
        .{ .name = "src/main.zig", .required = false },
    };
    var found_count: usize = 0;
    var missing_optional: ?[]const u8 = null;
    var missing_required = false;
    for (project_files) |pf| {
        if (std.Io.Dir.cwd().access(io, pf.name, .{})) |_| {
            found_count += 1;
        } else |_| {
            if (pf.required) {
                missing_required = true;
            } else {
                if (missing_optional == null) missing_optional = pf.name;
            }
        }
    }
    if (missing_required) {
        checks[check_count] = .{
            .name = "project structure",
            .status = .fail,
            .detail = "build.zig missing (run zunk init?)",
        };
    } else if (missing_optional) |name| {
        checks[check_count] = .{
            .name = "project structure",
            .status = .warn,
            .detail = name,
        };
    } else {
        checks[check_count] = .{
            .name = "project structure",
            .status = .ok,
            .detail = "all files present",
        };
    }
    check_count += 1;

    // 4. .gitignore specifically
    const gi_exists = if (std.Io.Dir.cwd().access(io, ".gitignore", .{})) |_| true else |_| false;
    checks[check_count] = .{
        .name = ".gitignore",
        .status = if (gi_exists) .ok else .warn,
        .detail = if (gi_exists) "present" else "missing (dist/ may be committed)",
    };
    check_count += 1;

    // Print results
    try console.print("");
    var ok_count: usize = 0;
    var warn_count: usize = 0;
    var fail_count: usize = 0;

    for (checks[0..check_count]) |check| {
        var buf: [512]u8 = undefined;
        const status_str = switch (check.status) {
            .ok => "[green][OK][/]  ",
            .warn => "[yellow][WARN][/]",
            .fail => "[red][FAIL][/]",
        };
        const msg = std.fmt.bufPrint(&buf, "  {s}  {s: <20} {s}", .{ status_str, check.name, check.detail }) catch continue;
        try console.print(msg);
        switch (check.status) {
            .ok => ok_count += 1,
            .warn => warn_count += 1,
            .fail => fail_count += 1,
        }
    }

    try console.print("");
    var summary_buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} passed, {d} warning(s), {d} error(s)", .{ ok_count, warn_count, fail_count }) catch "done";
    try console.printStyled(summary, rich.Style.empty.bold().foreground(
        if (fail_count > 0) rich.Color.red else if (warn_count > 0) rich.Color.yellow else rich.Color.green,
    ));
}

fn checkZigVersion(ver_str: []const u8) bool {
    // Parse "0.16.0" or "0.16.0-dev.123+abc" -- we only need major.minor.patch
    var parts: [3]u16 = .{ 0, 0, 0 };
    var seg: usize = 0;
    var i: usize = 0;
    while (i < ver_str.len and seg < 3) : (i += 1) {
        if (ver_str[i] == '.' or ver_str[i] == '-' or ver_str[i] == '+') {
            if (ver_str[i] != '.') break;
            seg += 1;
        } else if (ver_str[i] >= '0' and ver_str[i] <= '9') {
            parts[seg] = parts[seg] * 10 + @as(u16, @intCast(ver_str[i] - '0'));
        } else break;
    }
    // Minimum: 0.16.0
    if (parts[0] > 0) return true;
    if (parts[1] >= 16) return true;
    return false;
}

// --- Init command ---

fn initCommand(io: std.Io, args: []const []const u8, console: *rich.Console) !void {
    var project_dir: ?[]const u8 = null;
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            project_dir = arg;
            break;
        }
    }

    const cwd = std.Io.Dir.cwd();

    if (project_dir) |dir_name| {
        cwd.createDirPath(io, dir_name) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[bold red]error:[/] could not create directory '{s}': {}", .{ dir_name, err }) catch "error creating directory";
            try console.print(msg);
            return;
        };
    }

    var base: std.Io.Dir = undefined;
    var owns_base = false;
    if (project_dir) |dir_name| {
        base = cwd.openDir(io, dir_name, .{}) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[bold red]error:[/] could not open '{s}': {}", .{ dir_name, err }) catch "error opening directory";
            try console.print(msg);
            return;
        };
        owns_base = true;
    } else {
        base = cwd;
    }
    defer if (owns_base) base.close(io);

    // Guard: abort if build.zig already exists
    if (base.access(io, "build.zig", .{})) |_| {
        try console.print("[bold red]error:[/] build.zig already exists -- this directory is already initialized");
        return;
    } else |_| {}

    const name = project_dir orelse "my-app";

    // build.zig
    base.writeFile(io, .{ .sub_path = "build.zig", .data = buildZigTemplate() }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[bold red]error:[/] could not write build.zig: {}", .{err}) catch "error writing build.zig";
        try console.print(msg);
        return;
    };

    // build.zig.zon
    base.writeFile(io, .{ .sub_path = "build.zig.zon", .data = buildZigZonTemplate() }) catch {};

    // src/main.zig
    base.createDirPath(io, "src") catch {};
    base.writeFile(io, .{ .sub_path = "src/main.zig", .data = mainZigTemplate() }) catch {};

    // .gitignore
    base.writeFile(io, .{ .sub_path = ".gitignore", .data = gitignoreTemplate() }) catch {};

    try console.print("");
    {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Project initialized: [bold green]{s}/[/]", .{name}) catch "Project initialized";
        try console.print(msg);
    }
    try console.print("  src/main.zig     -- your app");
    try console.print("  build.zig        -- build configuration");
    try console.print("  build.zig.zon    -- package manifest");
    try console.print("  .gitignore");
    try console.print("");
    try console.print("Next steps:");
    try console.print("  [green]zig build[/]        -- compile to WASM");
    try console.print("  [green]zig build run[/]    -- compile + serve on localhost");
    try console.print("");
}

fn buildZigTemplate() []const u8 {
    return
    \\const std = @import("std");
    \\const zunk = @import("zunk");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const optimize = b.option(
    \\        std.builtin.OptimizeMode,
    \\        "optimize",
    \\        "Optimization mode (default: ReleaseFast)",
    \\    ) orelse .ReleaseFast;
    \\
    \\    const wasm_target = b.resolveTargetQuery(.{
    \\        .cpu_arch = .wasm32,
    \\        .os_tag = .freestanding,
    \\        .abi = .none,
    \\    });
    \\
    \\    const zunk_dep = b.dependency("zunk", .{
    \\        .target = wasm_target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "app",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = wasm_target,
    \\            .optimize = optimize,
    \\            .imports = &.{
    \\                .{ .name = "zunk", .module = zunk_dep.module("zunk") },
    \\            },
    \\        }),
    \\    });
    \\
    \\    exe.rdynamic = true;
    \\    exe.entry = .disabled;
    \\    exe.export_memory = true;
    \\
    \\    zunk.installApp(b, zunk_dep, exe, .{});
    \\}
    \\
    ;
}

fn buildZigZonTemplate() []const u8 {
    return
    \\.{
    \\    .name = .app,
    \\    .version = "0.0.0",
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        // TODO: replace with git URL once zunk is published
    \\        .zunk = .{ .path = "../.." },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
    ;
}

fn mainZigTemplate() []const u8 {
    return
    \\const zunk = @import("zunk");
    \\const canvas = zunk.web.canvas;
    \\
    \\var ctx: canvas.Ctx2D = undefined;
    \\
    \\export fn init() void {
    \\    ctx = canvas.getContext2D("app");
    \\}
    \\
    \\export fn frame(_: f32) void {
    \\    const vp = zunk.web.input.getViewportSize();
    \\    const w: f32 = @floatFromInt(vp.w);
    \\    const h: f32 = @floatFromInt(vp.h);
    \\
    \\    canvas.setFillColor(ctx, .{ .r = 20, .g = 20, .b = 30 });
    \\    canvas.fillRect(ctx, 0, 0, w, h);
    \\
    \\    canvas.setFillColor(ctx, .{ .r = 100, .g = 200, .b = 120 });
    \\    canvas.fillRect(ctx, w / 2 - 50, h / 2 - 50, 100, 100);
    \\
    \\    canvas.setFillColor(ctx, .{ .r = 220, .g = 220, .b = 220 });
    \\    canvas.setFont(ctx, "20px monospace");
    \\    canvas.fillText(ctx, "hello, zunk!", w / 2 - 70, h / 2 + 80);
    \\}
    \\
    \\export fn resize(w: u32, h: u32) void {
    \\    canvas.setSize(ctx, w, h);
    \\}
    \\
    ;
}

fn gitignoreTemplate() []const u8 {
    return
    \\.zig-cache/
    \\zig-out/
    \\dist/
    \\.zunk_cache
    \\
    ;
}

test {
    @import("std").testing.refAllDecls(@This());
}
