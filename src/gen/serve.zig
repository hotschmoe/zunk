const std = @import("std");
const webzocket = @import("webzocket");
const rich = @import("rich_zig");
const native_os = @import("builtin").os.tag;
const windows = std.os.windows;

const default_favicon = @embedFile("favicon.ico");

const Handle = std.net.Stream.Handle;

pub const ServeConfig = struct {
    autoreload: bool = true,
    watch_sources: bool = true,
    watch_paths: []const []const u8 = &.{"src"},
    watch_files: []const []const u8 = &.{ "build.zig", "build.zig.zon" },
    build_cmd: []const []const u8 = &.{ "zig", "build" },
    proxy_prefix: ?[]const u8 = null,
    proxy_target: ?[]const u8 = null,
};

const WsRegistry = struct {
    mutex: std.Thread.Mutex = .{},
    handles: [16]?Handle = .{null} ** 16,

    fn add(self: *WsRegistry, handle: Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.handles) |*slot| {
            if (slot.* == null) {
                slot.* = handle;
                return;
            }
        }
    }

    fn remove(self: *WsRegistry, handle: Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.handles) |*slot| {
            if (slot.* == handle) {
                slot.* = null;
                return;
            }
        }
    }

    fn broadcast(self: *WsRegistry, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.handles) |*slot| {
            if (slot.*) |handle| {
                wsWriteText(handle, msg) catch {
                    slot.* = null;
                };
            }
        }
    }
};

pub fn serve(allocator: std.mem.Allocator, root_dir_path: []const u8, port: u16, config: ServeConfig, console: *rich.Console) !void {
    var root_dir = try std.fs.cwd().openDir(root_dir_path, .{});
    defer root_dir.close();

    var ws_reg = WsRegistry{};

    if (config.autoreload) {
        spawnDetached(watcherThread, .{ root_dir_path, &ws_reg, console }, "file watcher", console);
    }

    if (config.autoreload and config.watch_sources) {
        spawnDetached(sourceWatcherThread, .{ allocator, &config, &ws_reg, console }, "source watcher", console);
    }

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        if (err == error.AddressInUse) {
            logErr("error: port {d} is already in use", .{port}, console);
        }
        return err;
    };
    defer server.deinit();

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
        const conn = server.accept() catch |err| {
            logErr("accept error: {}", .{err}, console);
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionThread, .{ allocator, conn.stream, root_dir, &ws_reg, &config, console });
        if (thread) |t| t.detach() else |_| conn.stream.close();
    }
}

fn connectionThread(allocator: std.mem.Allocator, stream: std.net.Stream, root_dir: std.fs.Dir, ws_reg: *WsRegistry, config: *const ServeConfig, console: *rich.Console) void {
    defer stream.close();

    var buf: [4096]u8 = undefined;
    const n = socketRead(stream.handle, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    if (config.autoreload and isWsUpgrade(request)) {
        wsHandshake(stream.handle, request) catch return;
        ws_reg.add(stream.handle);
        wsReadLoop(stream.handle);
        ws_reg.remove(stream.handle);
        return;
    }

    handleHttpRequest(allocator, stream, root_dir, request, config, console) catch |err| {
        logErr("request error: {}", .{err}, console);
    };
}

fn handleHttpRequest(allocator: std.mem.Allocator, stream: std.net.Stream, root_dir: std.fs.Dir, request: []const u8, config: *const ServeConfig, console: *rich.Console) !void {
    const path = parsePath(request) orelse return;

    if (config.proxy_prefix) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            proxyRequest(allocator, stream, request, path, config.proxy_target.?, console) catch |err| {
                logErr("proxy error: {}", .{err}, console);
                sendResponse(stream, "502 Bad Gateway", "text/plain", "Bad Gateway") catch {};
            };
            return;
        }
    }

    if (std.mem.indexOf(u8, path, "..") != null) {
        try sendResponse(stream, "403 Forbidden", "text/plain", "Forbidden");
        return;
    }

    const rel_path = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];

    const file_data = root_dir.readFileAlloc(allocator, rel_path, 50 * 1024 * 1024) catch {
        if (std.mem.eql(u8, rel_path, "favicon.ico")) {
            try sendResponse(stream, "200 OK", "image/x-icon", default_favicon);
            return;
        }
        if (std.fs.path.extension(rel_path).len == 0) {
            const fallback = root_dir.readFileAlloc(allocator, "index.html", 50 * 1024 * 1024) catch {
                try sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
                return;
            };
            defer allocator.free(fallback);
            try sendResponse(stream, "200 OK", "text/html", fallback);
            return;
        }
        try sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer allocator.free(file_data);

    logDim("{s} -> {s}", .{ path, rel_path }, console);

    const content_type = mimeType(rel_path);
    const ae = findHeader(request, "Accept-Encoding") orelse "";
    const accepts_gzip = std.mem.indexOf(u8, ae, "gzip") != null;

    if (accepts_gzip and file_data.len > 1024 and isCompressible(content_type)) {
        if (gzipCompress(allocator, file_data)) |compressed| {
            defer allocator.free(compressed);
            try sendCompressedResponse(stream, "200 OK", content_type, compressed);
            return;
        }
    }

    try sendResponse(stream, "200 OK", content_type, file_data);
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
            return std.mem.trimLeft(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

fn wsHandshake(handle: Handle, request: []const u8) !void {
    const key = findHeader(request, "Sec-WebSocket-Key") orelse return error.MissingHeader;
    var reply_buf: [256]u8 = undefined;
    const reply = try webzocket.Handshake.createReply(key, null, false, &reply_buf);
    try socketWrite(handle, reply);
}

fn wsWriteText(handle: Handle, msg: []const u8) !void {
    if (msg.len <= 125) {
        var buf: [2 + 125]u8 = undefined;
        const header = webzocket.proto.writeFrameHeader(&buf, .text, msg.len, false);
        @memcpy(buf[header.len..][0..msg.len], msg);
        try socketWrite(handle, buf[0 .. header.len + msg.len]);
    } else {
        var header_buf: [14]u8 = undefined;
        const header = webzocket.proto.writeFrameHeader(&header_buf, .text, msg.len, false);
        try socketWrite(handle, header_buf[0..header.len]);
        try socketWrite(handle, msg);
    }
}

fn wsReadLoop(handle: Handle) void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = socketRead(handle, &buf) catch return;
        if (n == 0) return;
        if (buf[0] == @intFromEnum(webzocket.OpCode.close)) return;
    }
}

fn watcherThread(root_dir_path: []const u8, ws_reg: *WsRegistry, console: *rich.Console) void {
    var last_fingerprint: i128 = 0;
    _ = pollDirChanged(root_dir_path, &last_fingerprint);
    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        if (pollDirChanged(root_dir_path, &last_fingerprint)) {
            logWarn("reload: dist/ changed, notifying browsers", .{}, console);
            ws_reg.broadcast("reload");
        }
    }
}

fn pollDirChanged(root_dir_path: []const u8, last_fingerprint: *i128) bool {
    var dir = std.fs.cwd().openDir(root_dir_path, .{}) catch return false;
    defer dir.close();

    var fingerprint: i128 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        fingerprint +%= stat.mtime;
    }

    if (fingerprint != last_fingerprint.*) {
        last_fingerprint.* = fingerprint;
        return true;
    }
    return false;
}

fn sourceWatcherThread(allocator: std.mem.Allocator, config: *const ServeConfig, ws_reg: *WsRegistry, console: *rich.Console) void {
    var last_fingerprint: i128 = 0;
    _ = pollSourceChanged(config, &last_fingerprint);
    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        if (pollSourceChanged(config, &last_fingerprint)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            console.printStyled("watch: source changed, rebuilding...", rich.Style.empty.bold().foreground(rich.Color.cyan)) catch {};
            runBuild(allocator, config, ws_reg, console);
        }
    }
}

fn runBuild(allocator: std.mem.Allocator, config: *const ServeConfig, ws_reg: *WsRegistry, console: *rich.Console) void {
    var child = std.process.Child.init(config.build_cmd, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.spawn() catch |err| {
        logErr("build: failed to spawn: {}", .{err}, console);
        return;
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 512 * 1024) catch {};

    const result = child.wait() catch |err| {
        logErr("build: wait failed: {}", .{err}, console);
        return;
    };

    const success = switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };

    if (success) {
        console.printStyled("build: success", rich.Style.empty.bold().foreground(rich.Color.green)) catch {};
        ws_reg.broadcast("clear");
        return;
    }

    console.printStyled("build: failed", rich.Style.empty.bold().foreground(rich.Color.red)) catch {};
    const err_text = stderr_buf.items;
    if (err_text.len == 0) return;

    const max_err_len = 60000;
    const truncated = err_text[0..@min(err_text.len, max_err_len)];
    const prefix = "error:";
    const msg = allocator.alloc(u8, prefix.len + truncated.len) catch return;
    defer allocator.free(msg);
    @memcpy(msg[0..prefix.len], prefix);
    @memcpy(msg[prefix.len..], truncated);
    ws_reg.broadcast(msg);
}

fn pollSourceChanged(config: *const ServeConfig, last_fingerprint: *i128) bool {
    var fingerprint: i128 = 0;

    for (config.watch_paths) |watch_path| {
        pollDirRecursive(watch_path, &fingerprint);
    }

    for (config.watch_files) |file_path| {
        const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        fingerprint +%= stat.mtime;
    }

    if (fingerprint != last_fingerprint.*) {
        last_fingerprint.* = fingerprint;
        return true;
    }
    return false;
}

fn pollDirRecursive(dir_path: []const u8, fingerprint: *i128) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            pollDirRecursive(sub_path, fingerprint);
        } else if (entry.kind == .file) {
            const file = dir.openFile(entry.name, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            fingerprint.* +%= stat.mtime;
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

fn socketRead(handle: Handle, buf: []u8) !usize {
    if (native_os == .windows) {
        const len: i32 = @intCast(buf.len);
        const rc = windows.ws2_32.recv(handle, buf.ptr, len, 0);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            return switch (windows.ws2_32.WSAGetLastError()) {
                .WSAECONNRESET => error.ConnectionResetByPeer,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
        return @intCast(rc);
    }
    return std.posix.read(handle, buf);
}

fn socketWrite(handle: Handle, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const chunk = data[sent..];
        if (native_os == .windows) {
            const len: i32 = @intCast(@min(chunk.len, std.math.maxInt(i32)));
            const rc = windows.ws2_32.send(handle, chunk.ptr, len, 0);
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                return switch (windows.ws2_32.WSAGetLastError()) {
                    .WSAECONNRESET => return,
                    else => |err| windows.unexpectedWSAError(err),
                };
            }
            sent += @intCast(rc);
        } else {
            sent += std.posix.write(handle, chunk) catch |err| switch (err) {
                error.ConnectionResetByPeer, error.BrokenPipe => return,
                else => return @errorCast(err),
            };
        }
    }
}

fn parsePath(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const rest = request[4..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return rest[0..end];
}

fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
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

fn proxyRequest(allocator: std.mem.Allocator, client_stream: std.net.Stream, request: []const u8, path: []const u8, target: []const u8, console: *rich.Console) !void {
    const scheme_end = std.mem.indexOf(u8, target, "://") orelse return error.InvalidAddress;
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

    const backend = std.net.tcpConnectToHost(allocator, host, port) catch return error.ConnectionRefused;
    defer backend.close();

    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return error.InvalidRequest;
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(allocator);
    const w = rewritten.writer(allocator);

    const method_end = std.mem.indexOfScalar(u8, request[0..first_line_end], ' ') orelse return error.InvalidRequest;
    const method = request[0..method_end];
    const version_start = std.mem.lastIndexOfScalar(u8, request[0..first_line_end], ' ') orelse return error.InvalidRequest;
    const version = request[version_start..first_line_end];

    try w.print("{s} {s}{s}\r\n", .{ method, path, version });
    try w.writeAll(request[first_line_end + 2 ..]);

    try backend.writeAll(rewritten.items);

    var response_buf: [8192]u8 = undefined;
    while (true) {
        const n = backend.read(&response_buf) catch break;
        if (n == 0) break;
        socketWrite(client_stream.handle, response_buf[0..n]) catch break;
    }
}

fn isCompressible(content_type: []const u8) bool {
    const compressible = [_][]const u8{
        "text/html",
        "application/javascript",
        "text/css",
        "application/json",
        "text/wgsl",
        "application/wasm",
        "image/svg+xml",
    };
    for (compressible) |ct| {
        if (std.mem.eql(u8, content_type, ct)) return true;
    }
    return false;
}

fn gzipCompress(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    const flate = std.compress.flate;
    var output = std.Io.Writer.Allocating.init(allocator);
    const compress_buf = allocator.alloc(u8, 65536) catch return null;
    defer allocator.free(compress_buf);
    var compressor = allocator.create(flate.Compress) catch return null;
    defer allocator.destroy(compressor);
    compressor.* = flate.Compress.init(&output.writer, compress_buf, .{
        .level = .fast,
        .container = .gzip,
    });
    compressor.writer.writeAll(input) catch return null;
    compressor.end() catch return null;
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator) catch null;
}

fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try sendResponseImpl(stream, status, content_type, body, false);
}

fn sendCompressedResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try sendResponseImpl(stream, status, content_type, body, true);
}

fn sendResponseImpl(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8, gzip: bool) !void {
    var header_buf: [512]u8 = undefined;
    var off: usize = 0;
    off += (std.fmt.bufPrint(header_buf[off..],
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n",
        .{ status, content_type, body.len },
    ) catch return).len;
    if (gzip) {
        off += (std.fmt.bufPrint(header_buf[off..], "Content-Encoding: gzip\r\n", .{}) catch return).len;
    }
    off += (std.fmt.bufPrint(header_buf[off..],
        "Cache-Control: no-store\r\n" ++
            "Cross-Origin-Opener-Policy: same-origin\r\n" ++
            "Cross-Origin-Embedder-Policy: require-corp\r\n" ++
            "Connection: close\r\n\r\n",
        .{},
    ) catch return).len;
    try socketWrite(stream.handle, header_buf[0..off]);
    try socketWrite(stream.handle, body);
}
