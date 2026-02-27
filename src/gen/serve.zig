const std = @import("std");

pub fn serve(allocator: std.mem.Allocator, root_dir_path: []const u8, port: u16) !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 0 }, port);
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        if (err == error.AddressInUse) {
            std.debug.print("error: port {d} is already in use\n", .{port});
        }
        return err;
    };
    defer server.deinit();

    std.debug.print("Serving on http://127.0.0.1:{d}/\nPress Ctrl+C to stop.\n", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();
        handleConnection(allocator, conn.stream, root_dir_path) catch |err| {
            std.debug.print("request error: {}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: std.net.Stream, root_dir_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const n = try stream.read(&buf);
    if (n == 0) return;

    const request = buf[0..n];
    const path = parsePath(request) orelse return;

    if (std.mem.indexOf(u8, path, "..") != null) {
        try sendResponse(stream, "403 Forbidden", "text/plain", "Forbidden");
        return;
    }

    const file_path = if (std.mem.eql(u8, path, "/"))
        "index.html"
    else
        path[1..];

    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_dir_path, file_path });
    defer allocator.free(full_path);

    const file_data = std.fs.cwd().readFileAlloc(allocator, full_path, 50 * 1024 * 1024) catch {
        try sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer allocator.free(file_data);

    const mime = mimeType(file_path);
    std.debug.print("{s} -> {s}\n", .{ path, file_path });
    try sendResponse(stream, "200 OK", mime, file_data);
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

fn writeAll(stream: std.net.Stream, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        sent += try stream.write(data[sent..]);
    }
}

fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    try writeAll(stream, header);
    try writeAll(stream, body);
}
