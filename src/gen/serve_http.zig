const std = @import("std");
const webzocket = @import("webzocket");
const assert = @import("../assert.zig").assert;
const io = @import("serve_io.zig");

pub const script_bytes_max: u16 = 1536;
pub const favicon = @embedFile("favicon.ico");
pub const RequestError = error{ BadRequest, UriLimit, Forbidden };
const reload_template =
    \\<script>
    \\(()=>{{const ws=new WebSocket('ws://'+location.hostname+':{d}/__zunk_ws');
    \\ws.onmessage=e=>{{
    \\if(e.data==='reload')location.reload();
    \\else if(e.data.startsWith('hmr:')){{const swap=window.__zunkHmrSwap;
    \\if(typeof swap==='function')
    \\Promise.resolve(swap(e.data.slice(4))).catch(()=>location.reload());
    \\else location.reload();}}
    \\else if(e.data==='clear'){{const o=document.getElementById('zunk-err');if(o)o.remove();}}
    \\else if(e.data.startsWith('error:')){{let o=document.getElementById('zunk-err');
    \\if(!o){{o=document.createElement('pre');o.id='zunk-err';
    \\o.style.cssText='position:fixed;inset:0;z-index:99999;background:#000e;'+
    \\'color:#ff6b6b;padding:2rem;margin:0;overflow:auto;'+
    \\'font:14px/1.6 monospace;white-space:pre-wrap';
    \\document.body.appendChild(o);}}o.textContent='BUILD ERROR\n\n'+e.data.slice(6);}}}};
    \\ws.onclose=()=>setTimeout(()=>location.reload(),2000);}})();
    \\</script>
;

pub fn request_path(request: []const u8) RequestError![]const u8 {
    assert(request.len <= io.request_bytes_max);
    assert(std.mem.find(u8, request, "\r\n\r\n") != null);
    if (!std.mem.startsWith(u8, request, "GET ")) return error.BadRequest;
    const end = std.mem.findScalar(u8, request[4..], ' ') orelse return error.BadRequest;
    if (end == 0 or request[4] != '/') return error.BadRequest;
    if (end > io.path_bytes_max) return error.UriLimit;
    const target = request[4..][0..end];
    const query = std.mem.findScalar(u8, target, '?') orelse target.len;
    const path = target[0..query];
    if (std.mem.find(u8, path, "..") != null) return error.Forbidden;
    if (std.mem.findScalar(u8, path, '\\') != null) return error.Forbidden;
    if (std.mem.findScalar(u8, path, 0) != null) return error.BadRequest;
    return path;
}

pub fn header(request: []const u8, name: []const u8) ?[]const u8 {
    assert(request.len <= io.request_bytes_max);
    assert(name.len > 0);
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    for (0..io.request_bytes_max) |_| {
        const line = lines.next() orelse return null;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

pub fn handshake(request: []const u8, buffer: []u8) error{BadRequest}![]const u8 {
    assert(buffer.len >= 256);
    assert(request.len <= io.request_bytes_max);
    const upgrade = header(request, "Upgrade") orelse return error.BadRequest;
    const connection = header(request, "Connection") orelse return error.BadRequest;
    const version = header(request, "Sec-WebSocket-Version") orelse return error.BadRequest;
    const key = header(request, "Sec-WebSocket-Key") orelse return error.BadRequest;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.BadRequest;
    if (std.ascii.findIgnoreCase(connection, "upgrade") == null) return error.BadRequest;
    if (!std.mem.eql(u8, version, "13") or key.len != 24) return error.BadRequest;
    var decoded: [16]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(key) catch return error.BadRequest;
    if (size != decoded.len) return error.BadRequest;
    std.base64.standard.Decoder.decode(&decoded, key) catch return error.BadRequest;
    return webzocket.Handshake.createReply(key, null, false, buffer) catch error.BadRequest;
}

pub fn response(buffer: []u8, status: []const u8, mime: []const u8, len: u32) []const u8 {
    assert(buffer.len >= 512);
    assert(len <= io.file_bytes_max + script_bytes_max);
    return std.fmt.bufPrint(
        buffer,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\nCross-Origin-Opener-Policy: same-origin\r\n" ++
            "Cross-Origin-Embedder-Policy: require-corp\r\nConnection: close\r\n\r\n",
        .{ status, mime, len },
    ) catch @panic("response header bound");
}

pub fn mime_type(path: []const u8) []const u8 {
    const extensions = [_][]const u8{
        ".html", ".js",  ".wasm", ".css",  ".json",  ".map", ".png", ".jpg", ".jpeg",
        ".gif",  ".svg", ".ico",  ".woff", ".woff2", ".mp3", ".ogg", ".wav", ".wgsl",
    };
    const types = [_][]const u8{
        "text/html",        "application/javascript", "application/wasm", "text/css",
        "application/json", "application/json",       "image/png",        "image/jpeg",
        "image/jpeg",       "image/gif",              "image/svg+xml",    "image/x-icon",
        "font/woff",        "font/woff2",             "audio/mpeg",       "audio/ogg",
        "audio/wav",        "text/wgsl",
    };
    assert(extensions.len == types.len);
    for (extensions, types) |extension, mime| {
        if (std.mem.endsWith(u8, path, extension)) return mime;
    }
    assert(types.len > 0);
    return "application/octet-stream";
}

pub fn has_extension(path: []const u8) bool {
    assert(path.len > 0);
    const start = if (std.mem.findScalarLast(u8, path, '/')) |slash| slash + 1 else 0;
    assert(start <= path.len);
    return std.mem.findScalar(u8, path[start..], '.') != null;
}

pub fn inject(body: []u8, len: u32, script: []const u8) u32 {
    assert(len + script.len <= body.len);
    const position = std.mem.find(u8, body[0..len], "</body>") orelse len;
    std.mem.copyBackwards(
        u8,
        body[position + script.len ..][0 .. len - position],
        body[position..len],
    );
    @memcpy(body[position..][0..script.len], script);
    const result: u32 = @intCast(len + script.len);
    assert(result <= body.len);
    return result;
}

pub fn reload_script(buffer: []u8, port: u16) []const u8 {
    assert(buffer.len >= script_bytes_max);
    assert(port > 0);
    return std.fmt.bufPrint(buffer, reload_template, .{port}) catch @panic("reload script bound");
}
