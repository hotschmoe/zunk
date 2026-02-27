const std = @import("std");
const webzocket = @import("webzocket");
const native_os = @import("builtin").os.tag;
const windows = std.os.windows;

const Handle = std.net.Stream.Handle;

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

pub fn serve(allocator: std.mem.Allocator, root_dir_path: []const u8, port: u16, autoreload: bool) !void {
    var root_dir = try std.fs.cwd().openDir(root_dir_path, .{});
    defer root_dir.close();

    var ws_reg = WsRegistry{};

    if (autoreload) {
        const watcher = std.Thread.spawn(.{}, watcherThread, .{ root_dir_path, &ws_reg });
        if (watcher) |t| t.detach() else |err| {
            std.debug.print("warning: could not start file watcher: {}\n", .{err});
        }
    }

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        if (err == error.AddressInUse) {
            std.debug.print("error: port {d} is already in use\n", .{port});
        }
        return err;
    };
    defer server.deinit();

    const reload_note: []const u8 = if (autoreload) " (live reload enabled)" else "";
    std.debug.print("Serving on http://127.0.0.1:{d}/{s}\nPress Ctrl+C to stop.\n", .{ port, reload_note });

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionThread, .{ allocator, conn.stream, root_dir, &ws_reg, autoreload });
        if (thread) |t| t.detach() else |_| conn.stream.close();
    }
}

fn connectionThread(allocator: std.mem.Allocator, stream: std.net.Stream, root_dir: std.fs.Dir, ws_reg: *WsRegistry, autoreload: bool) void {
    defer stream.close();

    var buf: [4096]u8 = undefined;
    const n = socketRead(stream.handle, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    if (autoreload and isWsUpgrade(request)) {
        wsHandshake(stream.handle, request) catch return;
        ws_reg.add(stream.handle);
        wsReadLoop(stream.handle);
        ws_reg.remove(stream.handle);
        return;
    }

    handleHttpRequest(allocator, stream, root_dir, request) catch |err| {
        std.debug.print("request error: {}\n", .{err});
    };
}

fn handleHttpRequest(allocator: std.mem.Allocator, stream: std.net.Stream, root_dir: std.fs.Dir, request: []const u8) !void {
    const path = parsePath(request) orelse return;

    if (std.mem.indexOf(u8, path, "..") != null) {
        try sendResponse(stream, "403 Forbidden", "text/plain", "Forbidden");
        return;
    }

    const rel_path = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];

    const file_data = root_dir.readFileAlloc(allocator, rel_path, 50 * 1024 * 1024) catch {
        try sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer allocator.free(file_data);

    std.debug.print("{s} -> {s}\n", .{ path, rel_path });
    try sendResponse(stream, "200 OK", mimeType(rel_path), file_data);
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
    std.debug.assert(msg.len <= 125);
    var buf: [2 + 125]u8 = undefined;
    const header = webzocket.proto.writeFrameHeader(&buf, .text, msg.len, false);
    @memcpy(buf[header.len..][0..msg.len], msg);
    try socketWrite(handle, buf[0 .. header.len + msg.len]);
}

fn wsReadLoop(handle: Handle) void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = socketRead(handle, &buf) catch return;
        if (n == 0) return;
        if (buf[0] == @intFromEnum(webzocket.OpCode.close)) return;
    }
}

fn watcherThread(root_dir_path: []const u8, ws_reg: *WsRegistry) void {
    var last_fingerprint: i128 = 0;
    _ = pollDirChanged(root_dir_path, &last_fingerprint);
    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        if (pollDirChanged(root_dir_path, &last_fingerprint)) {
            std.debug.print("[reload] dist/ changed, notifying browsers\n", .{});
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
    return "application/octet-stream";
}

fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cross-Origin-Opener-Policy: same-origin\r\n" ++
            "Cross-Origin-Embedder-Policy: require-corp\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;
    try socketWrite(stream.handle, header);
    try socketWrite(stream.handle, body);
}
