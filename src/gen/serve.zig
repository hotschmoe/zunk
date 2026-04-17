const std = @import("std");
const webzocket = @import("webzocket");
const rich = @import("rich_zig");

const net = std.Io.net;
const Io = std.Io;

const default_favicon = @embedFile("favicon.ico");

// Raw handle type for WS registry (tracks active WebSocket connections across threads).
// Using the socket handle directly keeps the registry cheap -- we only need identity
// and the ability to write frames out of a shared `Io`.
const SockHandle = std.posix.fd_t;

fn reloadScript(port: u16) [reload_script_max]u8 {
    var buf: [reload_script_max]u8 = undefined;
    const len = (std.fmt.bufPrint(&buf,
        \\<script>
        \\(function(){{
        \\const ws=new WebSocket('ws://'+location.hostname+':{d}/__zunk_ws');
        \\ws.onmessage=e=>{{
        \\  if(e.data==='reload')location.reload();
        \\  if(e.data==='clear'){{const o=document.getElementById('zunk-err');if(o)o.remove();}}
        \\  if(e.data.startsWith('error:')){{
        \\    let o=document.getElementById('zunk-err');
        \\    if(!o){{o=document.createElement('pre');o.id='zunk-err';
        \\    o.style.cssText='position:fixed;top:0;left:0;right:0;bottom:0;z-index:99999;background:rgba(0,0,0,0.92);color:#ff6b6b;padding:2rem;margin:0;overflow:auto;font:14px/1.6 monospace;white-space:pre-wrap;';
        \\    document.body.appendChild(o);}}
        \\    o.textContent='BUILD ERROR\n\n'+e.data.slice(6);
        \\  }}
        \\}};
        \\ws.onclose=()=>setTimeout(()=>location.reload(),2000);
        \\}})();
        \\</script>
    , .{port}) catch unreachable).len;
    @memset(buf[len..], 0);
    return buf;
}

const reload_script_max = 768;

pub const ServeConfig = struct {
    autoreload: bool = true,
    port: u16 = 8080,
    watch_sources: bool = true,
    watch_paths: []const []const u8 = &.{"src"},
    watch_files: []const []const u8 = &.{ "build.zig", "build.zig.zon" },
    build_cmd: []const []const u8 = &.{ "zig", "build" },
    proxy_prefix: ?[]const u8 = null,
    proxy_target: ?[]const u8 = null,
};

/// A WebSocket connection registered for broadcasts. The stream is shared across
/// threads (the connection thread parks in a read loop, the watcher threads push
/// `reload` / `clear` / `error:` frames), so the mutex protects the slot list itself.
const WsSlot = struct {
    id: SockHandle,
    stream: net.Stream,
};

const WsRegistry = struct {
    mutex: Io.Mutex = .init,
    slots: [16]?WsSlot = .{null} ** 16,

    fn add(self: *WsRegistry, io: Io, stream: net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .id = stream.socket.handle, .stream = stream };
                return;
            }
        }
    }

    fn remove(self: *WsRegistry, io: Io, id: SockHandle) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*slot| {
            if (slot.* != null and slot.*.?.id == id) {
                slot.* = null;
                return;
            }
        }
    }

    fn broadcast(self: *WsRegistry, io: Io, msg: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*slot| {
            if (slot.*) |ws| {
                wsWriteText(io, ws.stream, msg) catch {
                    slot.* = null;
                };
            }
        }
    }
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir_path: []const u8,
    port: u16,
    config: ServeConfig,
    console: *rich.Console,
) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root_dir_path, .{});
    defer root_dir.close(io);

    var ws_reg = WsRegistry{};

    if (config.autoreload) {
        spawnDetached(watcherThread, .{ io, root_dir_path, &ws_reg, console }, "file watcher", console);
    }

    if (config.autoreload and config.watch_sources) {
        spawnDetached(sourceWatcherThread, .{ allocator, io, &config, &ws_reg, console }, "source watcher", console);
    }

    const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = addr.listen(io, .{}) catch |err| {
        if (err == error.AddressInUse) {
            logErr("error: port {d} is already in use", .{port}, console);
        }
        return err;
    };
    defer server.deinit(io);

    var banner_buf: [512]u8 = undefined;
    const banner_content = std.fmt.bufPrint(&banner_buf, "http://127.0.0.1:{d}{s}{s}", .{
        port,
        if (config.autoreload) "\nlive reload enabled" else "",
        if (config.watch_sources) "\nsource watching enabled" else "",
    }) catch "";

    const banner = rich.Panel.fromText(allocator, banner_content)
        .withTitle("zunk dev server")
        .withBorderStyle(rich.Style.empty.foreground(rich.Color.green));
    try console.printRenderable(banner);
    try console.print("[dim]Press Ctrl+C to stop.[/]");
    try console.print("");

    while (true) {
        const stream = server.accept(io) catch |err| {
            logErr("accept error: {}", .{err}, console);
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionThread, .{ allocator, io, stream, root_dir, &ws_reg, &config, console });
        if (thread) |t| t.detach() else |_| stream.close(io);
    }
}

fn connectionThread(
    allocator: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    root_dir: std.Io.Dir,
    ws_reg: *WsRegistry,
    config: *const ServeConfig,
    console: *rich.Console,
) void {
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // Read whatever the client sent in their first packet. We don't try to
    // parse HTTP framing -- the dev server only handles simple GET requests
    // that fit in a single TCP segment (no body). 4096 bytes is generous.
    r.fillMore() catch return;
    const request_bytes = r.buffered();
    if (request_bytes.len == 0) return;

    if (config.autoreload and isWsUpgrade(request_bytes)) {
        wsHandshake(io, stream, request_bytes) catch return;
        r.tossBuffered();
        ws_reg.add(io, stream);
        wsReadLoop(&reader);
        ws_reg.remove(io, stream.socket.handle);
        return;
    }

    handleHttpRequest(allocator, io, stream, root_dir, request_bytes, config, console) catch |err| {
        logErr("request error: {}", .{err}, console);
    };
}

fn handleHttpRequest(
    allocator: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    root_dir: std.Io.Dir,
    request: []const u8,
    config: *const ServeConfig,
    console: *rich.Console,
) !void {
    const path = parsePath(request) orelse return;

    if (config.proxy_prefix) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            proxyRequest(allocator, io, stream, request, path, config.proxy_target.?, console) catch |err| {
                logErr("proxy error: {}", .{err}, console);
                sendResponse(io, stream, "502 Bad Gateway", "text/plain", "Bad Gateway") catch {};
            };
            return;
        }
    }

    if (std.mem.find(u8, path, "..") != null) {
        try sendResponse(io, stream, "403 Forbidden", "text/plain", "Forbidden");
        return;
    }

    const rel_path = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];

    const file_data = root_dir.readFileAlloc(io, rel_path, allocator, .limited(50 * 1024 * 1024)) catch {
        if (std.mem.eql(u8, rel_path, "favicon.ico")) {
            try sendResponse(io, stream, "200 OK", "image/x-icon", default_favicon);
            return;
        }
        if (std.Io.Dir.path.extension(rel_path).len == 0) {
            const fallback = root_dir.readFileAlloc(io, "index.html", allocator, .limited(50 * 1024 * 1024)) catch {
                try sendResponse(io, stream, "404 Not Found", "text/plain", "Not Found");
                return;
            };
            defer allocator.free(fallback);
            try sendHtmlWithReload(allocator, io, stream, fallback, config);
            return;
        }
        try sendResponse(io, stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer allocator.free(file_data);

    logDim("{s} -> {s}", .{ path, rel_path }, console);

    const mime = mimeType(rel_path);
    if (config.autoreload and std.mem.eql(u8, mime, "text/html")) {
        try sendHtmlWithReload(allocator, io, stream, file_data, config);
    } else {
        try sendResponse(io, stream, "200 OK", mime, file_data);
    }
}

fn sendHtmlWithReload(
    allocator: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    html: []const u8,
    config: *const ServeConfig,
) !void {
    const script_buf = reloadScript(config.port);
    const script = std.mem.sliceTo(&script_buf, 0);

    const body = try allocator.alloc(u8, html.len + script.len);
    defer allocator.free(body);

    if (std.mem.find(u8, html, "</body>")) |pos| {
        @memcpy(body[0..pos], html[0..pos]);
        @memcpy(body[pos..][0..script.len], script);
        @memcpy(body[pos + script.len ..], html[pos..]);
    } else {
        @memcpy(body[0..html.len], html);
        @memcpy(body[html.len..], script);
    }
    try sendResponse(io, stream, "200 OK", "text/html", body);
}

fn isWsUpgrade(request: []const u8) bool {
    const path = parsePath(request) orelse return false;
    if (!std.mem.eql(u8, path, "/__zunk_ws")) return false;
    return findHeader(request, "Upgrade") != null;
}

fn findHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, request, "\r\n");
    while (iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            return std.mem.trimStart(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

fn wsHandshake(io: Io, stream: net.Stream, request: []const u8) !void {
    const key = findHeader(request, "Sec-WebSocket-Key") orelse return error.MissingHeader;
    var reply_buf: [256]u8 = undefined;
    const reply = try webzocket.Handshake.createReply(key, null, false, &reply_buf);
    try streamWriteAll(io, stream, reply);
}

fn wsWriteText(io: Io, stream: net.Stream, msg: []const u8) !void {
    if (msg.len <= 125) {
        var buf: [2 + 125]u8 = undefined;
        const header = webzocket.proto.writeFrameHeader(&buf, .text, msg.len, false);
        @memcpy(buf[header.len..][0..msg.len], msg);
        try streamWriteAll(io, stream, buf[0 .. header.len + msg.len]);
    } else {
        var header_buf: [14]u8 = undefined;
        const header = webzocket.proto.writeFrameHeader(&header_buf, .text, msg.len, false);
        try streamWriteAll(io, stream, header_buf[0..header.len]);
        try streamWriteAll(io, stream, msg);
    }
}

/// Parks until the peer closes. We don't parse client-to-server frames -- the
/// dev client never sends any. A close frame or EOF drops out of the loop.
fn wsReadLoop(reader: *net.Stream.Reader) void {
    const r = &reader.interface;
    while (true) {
        r.fillMore() catch return;
        const chunk = r.buffered();
        if (chunk.len == 0) return;
        if (chunk[0] == @intFromEnum(webzocket.OpCode.close)) return;
        r.tossBuffered();
    }
}

fn watcherThread(io: Io, root_dir_path: []const u8, ws_reg: *WsRegistry, console: *rich.Console) void {
    var last_fingerprint: i128 = 0;
    _ = pollDirChanged(io, root_dir_path, &last_fingerprint);
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(500), .awake) catch return;
        if (pollDirChanged(io, root_dir_path, &last_fingerprint)) {
            logWarn("reload: dist/ changed, notifying browsers", .{}, console);
            ws_reg.broadcast(io, "reload");
        }
    }
}

fn pollDirChanged(io: Io, root_dir_path: []const u8, last_fingerprint: *i128) bool {
    var dir = std.Io.Dir.cwd().openDir(io, root_dir_path, .{}) catch return false;
    defer dir.close(io);

    var fingerprint: i128 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    if (fingerprint != last_fingerprint.*) {
        last_fingerprint.* = fingerprint;
        return true;
    }
    return false;
}

fn sourceWatcherThread(allocator: std.mem.Allocator, io: Io, config: *const ServeConfig, ws_reg: *WsRegistry, console: *rich.Console) void {
    var last_fingerprint: i128 = 0;
    _ = pollSourceChanged(io, config, &last_fingerprint);
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(500), .awake) catch return;
        if (pollSourceChanged(io, config, &last_fingerprint)) {
            io.sleep(Io.Duration.fromMilliseconds(100), .awake) catch return;
            console.printStyled("watch: source changed, rebuilding...", rich.Style.empty.bold().foreground(rich.Color.cyan)) catch {};
            runBuild(allocator, io, config, ws_reg, console);
        }
    }
}

fn runBuild(allocator: std.mem.Allocator, io: Io, config: *const ServeConfig, ws_reg: *WsRegistry, console: *rich.Console) void {
    const result = std.process.run(allocator, io, .{
        .argv = config.build_cmd,
    }) catch |err| {
        logErr("build: failed to run: {}", .{err}, console);
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (success) {
        console.printStyled("build: success", rich.Style.empty.bold().foreground(rich.Color.green)) catch {};
        ws_reg.broadcast(io, "clear");
        return;
    }

    console.printStyled("build: failed", rich.Style.empty.bold().foreground(rich.Color.red)) catch {};
    const err_text = result.stderr;
    if (err_text.len == 0) return;

    const max_err_len = 60000;
    const truncated = err_text[0..@min(err_text.len, max_err_len)];
    const prefix = "error:";
    const msg = allocator.alloc(u8, prefix.len + truncated.len) catch return;
    defer allocator.free(msg);
    @memcpy(msg[0..prefix.len], prefix);
    @memcpy(msg[prefix.len..], truncated);
    ws_reg.broadcast(io, msg);
}

fn pollSourceChanged(io: Io, config: *const ServeConfig, last_fingerprint: *i128) bool {
    var fingerprint: i128 = 0;

    for (config.watch_paths) |watch_path| {
        pollDirRecursive(io, watch_path, &fingerprint);
    }

    for (config.watch_files) |file_path| {
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        fingerprint +%= @intCast(stat.mtime.nanoseconds);
    }

    if (fingerprint != last_fingerprint.*) {
        last_fingerprint.* = fingerprint;
        return true;
    }
    return false;
}

fn pollDirRecursive(io: Io, dir_path: []const u8, fingerprint: *i128) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            pollDirRecursive(io, sub_path, fingerprint);
        } else if (entry.kind == .file) {
            const file = dir.openFile(io, entry.name, .{}) catch continue;
            defer file.close(io);
            const stat = file.stat(io) catch continue;
            fingerprint.* +%= @intCast(stat.mtime.nanoseconds);
        }
    }
}

fn spawnDetached(comptime func: anytype, args: anytype, label: []const u8, console: *rich.Console) void {
    const thread = std.Thread.spawn(.{}, func, args);
    if (thread) |t| t.detach() else |err| {
        logWarn("could not start {s}: {}", .{ label, err }, console);
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype, console: *rich.Console) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt[0..@min(fmt.len, buf.len)];
    console.printStyled(msg, rich.Style.empty.foreground(rich.Color.yellow)) catch {};
}

fn logErr(comptime fmt: []const u8, args: anytype, console: *rich.Console) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt[0..@min(fmt.len, buf.len)];
    console.printStyled(msg, rich.Style.empty.foreground(rich.Color.red)) catch {};
}

fn logDim(comptime fmt: []const u8, args: anytype, console: *rich.Console) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    console.printStyled(msg, rich.Style.empty.dim()) catch {};
}

/// Blocking write-all over a Stream. Creates a transient writer, writes, flushes.
fn streamWriteAll(io: Io, stream: net.Stream, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &buf);
    const w = &writer.interface;
    try reifyWriteErr(&writer, w.writeAll(data));
    try reifyWriteErr(&writer, w.flush());
}

/// Convert `error.WriteFailed` into the underlying transport error, silently
/// absorbing peer-disconnect cases so we don't spam logs on normal closes.
fn reifyWriteErr(writer: *net.Stream.Writer, result: anyerror!void) !void {
    result catch |err| switch (err) {
        error.WriteFailed => if (writer.err) |e| switch (e) {
            error.ConnectionResetByPeer, error.SocketUnconnected => {},
            else => return e,
        } else return error.WriteFailed,
        else => return err,
    };
}

fn parsePath(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const rest = request[4..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return rest[0..end];
}

fn mimeType(path: []const u8) []const u8 {
    const ext = std.Io.Dir.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".wgsl")) return "text/wgsl";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".mp3")) return "audio/mpeg";
    if (std.mem.eql(u8, ext, ".ogg")) return "audio/ogg";
    if (std.mem.eql(u8, ext, ".wav")) return "audio/wav";
    return "application/octet-stream";
}

fn proxyRequest(
    allocator: std.mem.Allocator,
    io: Io,
    client_stream: net.Stream,
    request: []const u8,
    path: []const u8,
    target: []const u8,
    console: *rich.Console,
) !void {
    const scheme_end = std.mem.find(u8, target, "://") orelse return error.InvalidAddress;
    const host_start = scheme_end + 3;
    const rest = target[host_start..];

    var host: []const u8 = rest;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        host = rest[0..colon];
        port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch 80;
    } else if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        host = rest[0..slash];
    }

    logDim("proxy: {s} -> {s}:{d}", .{ path, host, port }, console);

    const backend_addr = net.IpAddress.resolve(io, host, port) catch return error.ConnectionRefused;
    var backend = backend_addr.connect(io, .{ .mode = .stream }) catch return error.ConnectionRefused;
    defer backend.close(io);

    // Rewrite request path (strip any host-specific prefix handling the caller would want
    // -- dev server just forwards the path as-is).
    const first_line_end = std.mem.find(u8, request, "\r\n") orelse return error.InvalidRequest;
    var rewritten_aw: std.Io.Writer.Allocating = .init(allocator);
    defer rewritten_aw.deinit();

    const method_end = std.mem.indexOfScalar(u8, request[0..first_line_end], ' ') orelse return error.InvalidRequest;
    const method = request[0..method_end];
    const version_start = std.mem.lastIndexOfScalar(u8, request[0..first_line_end], ' ') orelse return error.InvalidRequest;
    const version = request[version_start..first_line_end];

    try rewritten_aw.writer.print("{s} {s}{s}\r\n", .{ method, path, version });
    try rewritten_aw.writer.writeAll(request[first_line_end + 2 ..]);

    try streamWriteAll(io, backend, rewritten_aw.written());

    // Shuttle response bytes backend -> client.
    var read_buf: [8192]u8 = undefined;
    var backend_reader = backend.reader(io, &read_buf);
    const r = &backend_reader.interface;
    while (true) {
        r.fillMore() catch break;
        const chunk = r.buffered();
        if (chunk.len == 0) break;
        streamWriteAll(io, client_stream, chunk) catch break;
        r.tossBuffered();
    }
}

fn sendResponse(io: Io, stream: net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Cross-Origin-Opener-Policy: same-origin\r\n" ++
            "Cross-Origin-Embedder-Policy: require-corp\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;
    try streamWriteAll(io, stream, header);
    try streamWriteAll(io, stream, body);
}
