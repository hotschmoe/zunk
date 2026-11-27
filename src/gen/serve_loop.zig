const std = @import("std");
const webzocket = @import("webzocket");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const http = @import("serve_http.zig");

const State = enum {
    free,
    request,
    file,
    header,
    body,
    handshake,
    websocket,
    proxy_connect,
    proxy_request,
    proxy_read,
    proxy_write,
};
const Build = enum { idle, running, pending };

fn same_metadata(before: api.Metadata, after: api.Metadata) bool {
    return before.size == after.size and before.inode == after.inode and
        before.modified_ns == after.modified_ns and before.changed_ns == after.changed_ns;
}

fn advance_revision(counter: *u64) api.Failure!void {
    if (counter.* == std.math.maxInt(u64)) return error.System;
    const previous = counter.*;
    counter.* += 1;
    assert(counter.* > previous);
    assert(counter.* != 0);
}

const Connection = struct {
    state: State = .free,
    handle: u32 = api.handle_none,
    upstream: u32 = api.handle_none,
    deadline_ms: u64 = 0,
    request: [api.request_bytes_max]u8,
    request_len: u32 = 0,
    output: [api.message_bytes_max]u8,
    output_len: u32 = 0,
    sent: u32 = 0,
    body: []const u8 = &.{},
    path: api.Path = .{},
    snapshot: ?u16 = null,
    fallback: bool = false,
    notified_build: u64 = 0,
    sending_build: u64 = 0,
    status_seen: u64 = 0,
    sending_status: u64 = 0,
    reader: webzocket.proto.Reader,
    incoming: [256]u8,

    fn reset(connection: *Connection) void {
        connection.state = .free;
        connection.handle = api.handle_none;
        connection.upstream = api.handle_none;
        connection.deadline_ms = 0;
        connection.request_len = 0;
        connection.output_len = 0;
        connection.sent = 0;
        connection.body = &.{};
        connection.path.len = 0;
        connection.snapshot = null;
        connection.fallback = false;
        connection.notified_build = 0;
        connection.sending_build = 0;
        connection.status_seen = 0;
        connection.sending_status = 0;
        assert(connection.state == .free);
        assert(connection.snapshot == null);
    }
};
const Snapshot = struct {
    bytes: [api.file_bytes_max + http.script_bytes_max]u8,
    owner: ?u16 = null,
    working: bool = false,
    used: bool = false,
    operation: api.FileOperation = .open,
    path: api.Path = .{},
    before: api.Metadata = undefined,
    offset: u32 = 0,
    requested: u32 = 0,
    failure: ?api.Failure = null,
};

pub const Loop = struct {
    io: api.Interface,
    config: api.Config,
    connections: [api.connections_max + 1]Connection,
    snapshots: [api.snapshots_max]Snapshot,
    provider: webzocket.buffer.Provider = .{
        .pool = undefined,
        .pool_buffer_size = 0,
        .max_buffer_size = 0,
        .allocator = .failing,
        .io = undefined,
    },
    now_ms: u64 = 0,
    accept_at_ms: u64 = 0,
    poll_at_ms: u64 = 0,
    debounce_at_ms: u64 = 0,
    build_deadline_ms: u64 = 0,
    watch_pending: bool = false,
    watch_ready: bool = false,
    build: Build = .idle,
    change_revision: u64 = 0,
    started_change: u64 = 0,
    completed_change: u64 = 0,
    build_id: u64 = 0,
    published_build: u64 = 0,
    status_revision: u64 = 0,
    error_text: [api.output_bytes_max + 64]u8 = undefined,
    error_len: u32 = 0,
    publish_pending: bool = false,
    publish_skip_watch: bool = false,
    build_dist: api.Changes = .{},
    reload_text: [api.path_bytes_max + 8]u8 = undefined,
    reload_len: u16 = 0,
    script: [http.script_bytes_max]u8 = undefined,
    script_len: u16 = 0,
    limits_hit: u64 = 0,

    pub fn init(loop: *Loop, io: api.Interface, config: api.Config) void {
        loop.io = io;
        loop.config = config;
        loop.provider = .{
            .pool = undefined,
            .pool_buffer_size = 0,
            .max_buffer_size = 0,
            .allocator = .failing,
            .io = undefined,
        };
        loop.now_ms = 0;
        loop.accept_at_ms = 0;
        loop.poll_at_ms = 0;
        loop.debounce_at_ms = 0;
        loop.build_deadline_ms = 0;
        loop.watch_pending = false;
        loop.watch_ready = false;
        loop.build = .idle;
        loop.change_revision = 0;
        loop.started_change = 0;
        loop.completed_change = 0;
        loop.build_id = 0;
        loop.published_build = 0;
        loop.status_revision = 0;
        loop.error_len = 0;
        loop.publish_pending = false;
        loop.publish_skip_watch = false;
        loop.build_dist = .{};
        loop.reload_len = 0;
        loop.script_len = 0;
        loop.limits_hit = 0;
        for (&loop.connections) |*connection| connection.reset();
        for (&loop.snapshots) |*snapshot| {
            snapshot.owner = null;
            snapshot.working = false;
            snapshot.used = false;
            snapshot.operation = .open;
            snapshot.path.len = 0;
            snapshot.offset = 0;
            snapshot.requested = 0;
            snapshot.failure = null;
        }
        assert(loop.build == .idle);
        assert(loop.change_revision == 0);
    }

    pub fn run(loop: *Loop) api.Failure!void {
        if (loop.config.port == 0) return error.InvalidConfig;
        assert(loop.config.port > 0);
        assert(loop.build == .idle);
        const script = http.reload_script(&loop.script, loop.config.port);
        loop.script_len = @intCast(script.len);
        try loop.io.vtable.listen(loop.io.context, loop.config.port);
        defer loop.close_all();
        try loop.log("serve: one event loop; 16 connections; 4 file snapshots");
        var banner: [128]u8 = undefined;
        const address = std.fmt.bufPrint(
            &banner,
            "http://127.0.0.1:{d}",
            .{loop.config.port},
        ) catch @panic("banner bound");
        try loop.log(address);
        for (0..std.math.maxInt(u64)) |_| {
            try loop.timers();
            var subscriptions: [api.connections_max * 2 + 1]api.Interest = undefined;
            const count = loop.interests(&subscriptions);
            const accept_enabled = loop.connections[api.connections_max].state == .free and
                loop.now_ms >= loop.accept_at_ms;
            const event = try loop.io.vtable.wait(
                loop.io.context,
                subscriptions[0..count],
                loop.deadline(),
                accept_enabled,
            );
            assert(event.now_ms >= loop.now_ms);
            if (event.now_ms > std.math.maxInt(u64) - api.build_timeout_ms) return error.System;
            loop.now_ms = event.now_ms;
            if (event.value == .stop) return;
            try loop.dispatch(event);
        }
        return error.System;
    }

    fn log(loop: *Loop, message: []const u8) api.Failure!void {
        return loop.io.vtable.log(loop.io.context, message);
    }

    fn limit(loop: *Loop, message: []const u8) api.Failure!void {
        try advance_revision(&loop.limits_hit);
        try loop.log(message);
        assert(loop.limits_hit > 0);
    }

    fn dispatch(loop: *Loop, event: api.Event) api.Failure!void {
        assert(event.now_ms == loop.now_ms);
        switch (event.value) {
            .accept => try loop.accept_connection(),
            .ready => |ready| try loop.ready_connection(ready),
            .file => |file| try loop.file_complete(file),
            .changes => |changes| {
                assert(loop.watch_pending);
                loop.watch_pending = false;
                loop.poll_at_ms = loop.now_ms + api.poll_ms;
                if (changes) |value| {
                    if (!loop.watch_ready) {
                        loop.watch_ready = true;
                        try loop.log("watch: ready");
                    }
                    try loop.changed(value);
                    try loop.publish();
                } else |err| {
                    loop.publish_skip_watch = false;
                    if (err == error.WatchLimit or err == error.PathLimit) {
                        try loop.limit("watch: scan limit reached; retry after 500ms");
                    }
                    try loop.diagnostic("watch", err);
                }
            },
            .build => |result| try loop.build_complete(result),
            .timer => {},
            .stop => unreachable,
        }
    }

    fn timers(loop: *Loop) api.Failure!void {
        if (loop.config.autoreload and !loop.watch_pending and loop.now_ms >= loop.poll_at_ms) {
            try loop.io.vtable.watch(loop.io.context);
            loop.watch_pending = true;
        }
        if (loop.build == .idle and loop.change_revision > loop.started_change and
            loop.now_ms >= loop.debounce_at_ms) try loop.start_build();
        if (loop.build != .idle and loop.now_ms >= loop.build_deadline_ms) {
            loop.io.vtable.cancel_build(loop.io.context);
            loop.build_deadline_ms = std.math.maxInt(u64);
            try loop.log("build: timed out; terminating child process group");
        }
        for (&loop.connections, 0..) |*connection, index| {
            if (connection.state == .free) continue;
            const timed = connection.state != .websocket or connection.output_len > 0;
            if (timed and loop.now_ms >= connection.deadline_ms) {
                try loop.log("connection: timed out");
                loop.close_connection(@intCast(index));
                continue;
            }
            if (connection.state == .websocket and connection.output_len == 0) {
                try loop.notify_client(connection);
            }
        }
    }

    fn deadline(loop: *const Loop) u64 {
        var result: u64 = loop.now_ms + 1000;
        if (loop.accept_at_ms > loop.now_ms) result = @min(result, loop.accept_at_ms);
        if (loop.config.autoreload and !loop.watch_pending) result = @min(result, loop.poll_at_ms);
        if (loop.build != .idle) result = @min(result, loop.build_deadline_ms);
        if (loop.build == .idle and loop.change_revision > loop.started_change) {
            result = @min(result, loop.debounce_at_ms);
        }
        for (&loop.connections) |*connection| {
            if (connection.state == .free) continue;
            if (connection.state != .websocket or connection.output_len > 0) {
                result = @min(result, connection.deadline_ms);
            }
        }
        assert(result >= loop.now_ms);
        return result;
    }

    fn interests(loop: *const Loop, buffer: []api.Interest) u16 {
        assert(buffer.len == api.connections_max * 2 + 1);
        var count: u16 = 0;
        for (&loop.connections, 0..) |*connection, index| {
            if (connection.state == .free) continue;
            const state = connection.state;
            buffer[count] = .{
                .handle = connection.handle,
                .token = @intCast(index),
                .read = state == .request or state == .websocket,
                .write = state == .header or state == .body or state == .handshake or
                    state == .proxy_write or (state == .websocket and connection.output_len > 0),
            };
            count += 1;
            if (connection.upstream != api.handle_none and
                (state == .proxy_read or state == .proxy_connect or state == .proxy_request))
            {
                buffer[count] = .{
                    .handle = connection.upstream,
                    .token = @intCast(index + api.connections_max + 1),
                    .read = state == .proxy_read,
                    .write = state == .proxy_connect or state == .proxy_request,
                };
                count += 1;
            }
        }
        assert(count <= buffer.len);
        return count;
    }

    fn accept_connection(loop: *Loop) api.Failure!void {
        assert(loop.connections[api.connections_max].state == .free);
        const result = loop.io.vtable.accept(loop.io.context);
        switch (result) {
            .pending => return,
            .failed => {
                loop.accept_at_ms = loop.now_ms + api.poll_ms;
                return loop.log("accept: failed; retry in 500ms");
            },
            .handle => |handle| {
                for (&loop.connections, 0..) |*connection, index| {
                    if (connection.state != .free) continue;
                    connection.reset();
                    connection.state = .request;
                    connection.handle = handle;
                    connection.deadline_ms = loop.now_ms + api.connection_timeout_ms;
                    connection.notified_build = loop.published_build;
                    if (index == api.connections_max) {
                        try loop.limit("connection limit: refusing with 503");
                        loop.small_response(
                            connection,
                            "503 Service Unavailable",
                            "Connection limit",
                        );
                    }
                    assert(connection.handle != api.handle_none);
                    return;
                }
            },
        }
        unreachable;
    }

    fn ready_connection(loop: *Loop, ready: api.Ready) api.Failure!void {
        const upstream = ready.token > api.connections_max;
        const index = if (upstream) ready.token - api.connections_max - 1 else ready.token;
        assert(index < loop.connections.len);
        const connection = &loop.connections[index];
        assert(connection.state != .free);
        if (upstream) return loop.proxy_ready(index, ready);
        if (ready.closed) {
            loop.close_connection(index);
            return;
        }
        if (ready.read) {
            switch (connection.state) {
                .request => try loop.read_request(index),
                .websocket => try loop.read_websocket(index),
                else => {},
            }
        }
        if (ready.write and connection.state != .free) try loop.write_connection(index);
    }

    fn read_request(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.state == .request);
        assert(connection.request_len < api.request_bytes_max);
        const result = loop.io.vtable.read(
            loop.io.context,
            connection.handle,
            connection.request[connection.request_len..],
        );
        switch (result) {
            .pending => {},
            .closed, .failed => loop.close_connection(index),
            .count => |count| {
                assert(count > 0 and count <= api.request_bytes_max - connection.request_len);
                connection.request_len += count;
                const request = connection.request[0..connection.request_len];
                if (std.mem.find(u8, request, "\r\n\r\n") != null) {
                    return loop.route(index);
                }
                if (request.len >= 4 and std.mem.startsWith(u8, request, "GET ") and
                    std.mem.findScalar(u8, request[4..], ' ') == null and
                    request.len > api.path_bytes_max + 4)
                {
                    try loop.limit("request URI limit: 414");
                    loop.small_response(connection, "414 URI Too Long", "URI limit");
                } else if (request.len == api.request_bytes_max) {
                    try loop.limit("request header limit: 431");
                    loop.small_response(
                        connection,
                        "431 Request Header Fields Too Large",
                        "Header limit",
                    );
                }
            },
        }
    }

    fn route(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.state == .request);
        const request = connection.request[0..connection.request_len];
        const path = http.request_path(request) catch |err| {
            const status = switch (err) {
                error.UriLimit => "414 URI Too Long",
                error.Forbidden => "403 Forbidden",
                error.BadRequest => "400 Bad Request",
            };
            try loop.limit(status);
            loop.small_response(connection, status, status);
            return;
        };
        if (loop.config.autoreload and std.mem.eql(u8, path, "/__zunk_ws")) {
            const reply = http.handshake(request, &connection.output) catch {
                loop.small_response(connection, "400 Bad Request", "Invalid WebSocket handshake");
                return;
            };
            connection.output_len = @intCast(reply.len);
            connection.reader = .init(&connection.incoming, &loop.provider, null);
            connection.state = .handshake;
            return;
        }
        if (loop.config.proxy_prefix) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return loop.start_proxy(connection);
        }
        if (loop.build != .idle) {
            loop.small_response(connection, "503 Service Unavailable", "Build in progress; retry");
            return;
        }
        connection.path = try api.Path.init(if (std.mem.eql(u8, path, "/"))
            "index.html"
        else
            path[1..]);
        assert(connection.path.len > 0);
        try loop.start_file(index);
    }

    fn start_file(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.snapshot == null);
        assert(connection.path.len > 0);
        for (&loop.snapshots, 0..) |*snapshot, slot| {
            if (snapshot.used) continue;
            snapshot.used = true;
            snapshot.offset = 0;
            snapshot.failure = null;
            snapshot.path = connection.path;
            snapshot.owner = index;
            connection.snapshot = @intCast(slot);
            connection.state = .file;
            try loop.queue_file(@intCast(slot), .open);
            return;
        }
        try loop.limit("file snapshot limit: 503");
        loop.small_response(connection, "503 Service Unavailable", "File snapshot limit; retry");
    }

    fn file_complete(loop: *Loop, event: api.FileResult) api.Failure!void {
        assert(event.index < api.snapshots_max);
        const snapshot = &loop.snapshots[event.index];
        assert(snapshot.working and snapshot.used);
        snapshot.working = false;
        const value = event.result catch |err| {
            if (snapshot.operation == .read) return loop.abort_file(event.index, err);
            return loop.finish_file(event.index, err);
        };
        if (snapshot.owner == null) {
            if (value == .opened or value == .read) return loop.queue_file(event.index, .close);
            snapshot.used = false;
            return;
        }
        switch (value) {
            .opened => |before| {
                assert(snapshot.operation == .open);
                snapshot.before = before;
                if (before.size > api.file_bytes_max) {
                    return loop.abort_file(event.index, error.FileLimit);
                }
                try loop.queue_file(event.index, .read);
            },
            .read => |count| try loop.file_read(event.index, count),
            .verified => |after| {
                assert(snapshot.operation == .verify_close);
                assert(snapshot.offset == snapshot.before.size);
                if (!same_metadata(snapshot.before, after.handle) or
                    !same_metadata(after.handle, after.path))
                {
                    return loop.finish_file(event.index, error.Changed);
                }
                try loop.finish_file(event.index, snapshot.offset);
            },
            .closed => {
                assert(snapshot.operation == .close);
                try loop.finish_file(event.index, snapshot.failure.?);
            },
        }
    }

    fn queue_file(loop: *Loop, index: u16, operation: api.FileOperation) api.Failure!void {
        const snapshot = &loop.snapshots[index];
        assert(snapshot.used and !snapshot.working);
        assert(snapshot.offset <= api.file_bytes_max);
        var buffer: []u8 = snapshot.bytes[0..0];
        if (operation == .read) {
            const size: u32 = @intCast(snapshot.before.size);
            const count = if (snapshot.offset == size) 1 else @min(65536, size - snapshot.offset);
            buffer = snapshot.bytes[snapshot.offset..][0..count];
        }
        snapshot.operation = operation;
        snapshot.working = true;
        snapshot.requested = @intCast(buffer.len);
        try loop.io.vtable.file(loop.io.context, .{
            .index = index,
            .path = snapshot.path,
            .buffer = buffer,
            .operation = operation,
            .offset = snapshot.offset,
        });
    }

    fn file_read(loop: *Loop, index: u16, count: u32) api.Failure!void {
        const snapshot = &loop.snapshots[index];
        assert(snapshot.operation == .read and !snapshot.working);
        assert(count <= snapshot.requested);
        if (snapshot.offset == snapshot.before.size) {
            if (count != 0) return loop.abort_file(index, error.Changed);
            return loop.queue_file(index, .verify_close);
        }
        if (count == 0) return loop.abort_file(index, error.Changed);
        snapshot.offset += count;
        assert(snapshot.offset <= snapshot.before.size);
        try loop.queue_file(index, .read);
    }

    fn abort_file(loop: *Loop, index: u16, err: api.Failure) api.Failure!void {
        const snapshot = &loop.snapshots[index];
        assert(snapshot.used and !snapshot.working);
        assert(snapshot.operation == .open or snapshot.operation == .read);
        snapshot.failure = err;
        try loop.queue_file(index, .close);
    }

    fn finish_file(loop: *Loop, slot: u16, result: api.Failure!u32) api.Failure!void {
        const snapshot = &loop.snapshots[slot];
        assert(!snapshot.working and snapshot.used);
        const index = snapshot.owner orelse {
            snapshot.used = false;
            return;
        };
        const connection = &loop.connections[index];
        assert(connection.state == .file and connection.snapshot == slot);
        if (result) |size| {
            assert(size <= api.file_bytes_max);
            if (loop.build != .idle) {
                loop.release_snapshot(connection);
                loop.small_response(
                    connection,
                    "503 Service Unavailable",
                    "Build in progress; retry",
                );
                return;
            }
            const mime = http.mime_type(connection.path.slice());
            const len = if (loop.config.autoreload and std.mem.eql(u8, mime, "text/html"))
                http.inject(&snapshot.bytes, size, loop.script[0..loop.script_len])
            else
                size;
            connection.body = snapshot.bytes[0..len];
            loop.begin_response(connection, "200 OK", mime);
        } else |err| {
            loop.release_snapshot(connection);
            try loop.file_failure(index, err);
        }
    }

    fn file_failure(loop: *Loop, index: u16, err: api.Failure) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.snapshot == null);
        assert(connection.state == .file);
        if (err == error.NotFound and std.mem.eql(u8, connection.path.slice(), "favicon.ico")) {
            connection.body = http.favicon;
            loop.begin_response(connection, "200 OK", "image/x-icon");
            return;
        }
        if (err == error.NotFound and !connection.fallback and
            !http.has_extension(connection.path.slice()))
        {
            connection.fallback = true;
            connection.path = try api.Path.init("index.html");
            return loop.start_file(index);
        }
        const status = switch (err) {
            error.NotFound => "404 Not Found",
            error.FileLimit => "413 Content Too Large",
            error.Changed => "503 Service Unavailable",
            else => "500 Internal Server Error",
        };
        try loop.diagnostic("file", err);
        if (err == error.FileLimit) try loop.limit("file size limit: 413");
        loop.small_response(connection, status, @errorName(err));
    }

    fn small_response(
        loop: *Loop,
        connection: *Connection,
        status: []const u8,
        body: []const u8,
    ) void {
        assert(connection.snapshot == null);
        connection.body = body;
        loop.begin_response(connection, status, "text/plain");
        assert(connection.state == .header);
    }

    fn begin_response(
        loop: *Loop,
        connection: *Connection,
        status: []const u8,
        mime: []const u8,
    ) void {
        assert(connection.body.len <= api.file_bytes_max + http.script_bytes_max);
        const header = http.response(
            &connection.output,
            status,
            mime,
            @intCast(connection.body.len),
        );
        connection.output_len = @intCast(header.len);
        connection.sent = 0;
        connection.state = .header;
        connection.deadline_ms = loop.now_ms + api.connection_timeout_ms;
        assert(connection.output_len > 0);
    }

    fn write_connection(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        const body = connection.state == .body;
        const bytes = if (body) connection.body else connection.output[0..connection.output_len];
        assert(connection.sent < bytes.len);
        const remaining = bytes[connection.sent..];
        const result = loop.io.vtable.write(
            loop.io.context,
            connection.handle,
            remaining[0..@min(65536, remaining.len)],
        );
        switch (result) {
            .pending => {},
            .closed, .failed => loop.close_connection(index),
            .count => |count| {
                assert(count > 0 and count <= bytes.len - connection.sent);
                connection.sent += count;
                connection.deadline_ms = loop.now_ms + api.connection_timeout_ms;
                if (connection.sent == bytes.len) try loop.write_complete(index);
            },
        }
    }

    fn write_complete(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.sent > 0);
        connection.sent = 0;
        connection.output_len = 0;
        switch (connection.state) {
            .header => {
                connection.state = .body;
                if (connection.body.len == 0) loop.close_connection(index);
            },
            .handshake => {
                connection.state = .websocket;
                try loop.log("reload client: connected");
            },
            .websocket => {
                assert(connection.sending_build <= loop.published_build);
                connection.notified_build = @max(
                    connection.notified_build,
                    connection.sending_build,
                );
                connection.status_seen = @max(connection.status_seen, connection.sending_status);
            },
            .proxy_write => connection.state = .proxy_read,
            .body => loop.close_connection(index),
            else => unreachable,
        }
    }

    fn read_websocket(loop: *Loop, index: u16) api.Failure!void {
        const connection = &loop.connections[index];
        const reader = &connection.reader;
        assert(connection.state == .websocket);
        assert(reader.pos < reader.buf.data.len);
        const end = if (reader.pos < 2) 2 else reader.message_len;
        assert(end > reader.pos and end <= connection.incoming.len);
        const result = loop.io.vtable.read(
            loop.io.context,
            connection.handle,
            reader.buf.data[reader.pos..end],
        );
        switch (result) {
            .pending => return,
            .closed, .failed => {
                loop.close_connection(index);
                return;
            },
            .count => |count| reader.pos += count,
        }
        if (reader.pos < 2) return;
        if (reader.buf.data[0] & 128 == 0 or reader.buf.data[1] & 127 > 125 or
            reader.buf.data[1] & 128 == 0)
        {
            try loop.limit("reload client: unsupported frame; closing");
            loop.close_connection(index);
            return;
        }
        const decoded = reader.read() catch |err| {
            try loop.diagnostic("websocket", err);
            loop.close_connection(index);
            return;
        };
        const message = decoded orelse return;
        assert(!message[0]);
        defer if (connection.state == .websocket) reader.done(message[1].type);
        switch (message[1].type) {
            .close => loop.close_connection(index),
            .ping => {
                if (connection.output_len != 0) {
                    try loop.limit("reload client: pong queue full; closing");
                    loop.close_connection(index);
                } else loop.frame(connection, .pong, message[1].data);
            },
            else => {},
        }
    }

    fn frame(
        loop: *Loop,
        connection: *Connection,
        opcode: webzocket.OpCode,
        message: []const u8,
    ) void {
        assert(connection.output_len == 0);
        assert(message.len + 14 <= connection.output.len);
        const header = webzocket.proto.writeFrameHeader(
            &connection.output,
            opcode,
            message.len,
            false,
        );
        @memcpy(connection.output[header.len..][0..message.len], message);
        connection.output_len = @intCast(header.len + message.len);
        connection.sent = 0;
        connection.deadline_ms = loop.now_ms + api.connection_timeout_ms;
    }

    fn notify_client(loop: *Loop, connection: *Connection) api.Failure!void {
        assert(connection.state == .websocket and connection.output_len == 0);
        assert(connection.notified_build <= loop.published_build);
        if (connection.status_seen < loop.status_revision) {
            const message = if (loop.error_len > 0) loop.error_text[0..loop.error_len] else "clear";
            loop.frame(connection, .text, message);
            connection.sending_status = loop.status_revision;
        } else if (connection.notified_build < loop.published_build) {
            loop.frame(connection, .text, loop.reload_text[0..loop.reload_len]);
            connection.sending_build = loop.published_build;
            try loop.log("reload: queued for client");
        }
    }

    fn changed(loop: *Loop, change: api.Changes) api.Failure!void {
        assert(loop.started_change <= loop.change_revision);
        if (change.source and loop.config.watch_sources) {
            try advance_revision(&loop.change_revision);
            loop.debounce_at_ms = loop.now_ms + api.debounce_ms;
            if (loop.build == .running) loop.build = .pending;
            switch (loop.build) {
                .pending => try loop.log("watch: change pending during build"),
                else => try loop.log("watch: source changed; debounce 100ms"),
            }
        }
        if (change.dist and (loop.build != .idle or loop.publish_pending)) {
            const wasm_only = !loop.build_dist.dist or loop.build_dist.wasm_only;
            loop.build_dist = change;
            loop.build_dist.wasm_only = wasm_only and change.wasm_only;
        }
        if (change.dist and loop.build == .idle and !change.source and
            !loop.publish_pending and loop.error_len == 0)
        {
            try advance_revision(&loop.published_build);
            loop.set_reload(change);
            try loop.log("reload: dist changed");
        }
    }

    fn start_build(loop: *Loop) api.Failure!void {
        assert(loop.build == .idle);
        assert(loop.change_revision > loop.started_change);
        try loop.io.vtable.build(loop.io.context);
        loop.started_change = loop.change_revision;
        loop.build = .running;
        loop.publish_pending = false;
        loop.build_dist = .{};
        try advance_revision(&loop.build_id);
        loop.build_deadline_ms = loop.now_ms + api.build_timeout_ms;
        try loop.log("watch: source changed, rebuilding...");
        var message: [128]u8 = undefined;
        const diagnostic_text = std.fmt.bufPrint(
            &message,
            "build: start {d}, change {d}",
            .{ loop.build_id, loop.started_change },
        ) catch @panic("build log bound");
        try loop.log(diagnostic_text);
    }

    fn build_complete(loop: *Loop, result: api.BuildResult) api.Failure!void {
        assert(loop.build != .idle);
        assert(result.len <= api.output_bytes_max);
        const pending = loop.build == .pending;
        loop.build = .idle;
        if (result.len > 0) try loop.log(result.output[0..result.len]);
        if (result.truncated) {
            try loop.limit("build: output truncated at 60000 bytes; remainder drained");
        }
        try advance_revision(&loop.status_revision);
        if (result.success) {
            try loop.log("build: success");
            loop.error_len = 0;
            loop.completed_change = loop.started_change;
            if (!pending) {
                assert(loop.completed_change == loop.change_revision);
                loop.publish_pending = true;
                loop.publish_skip_watch = loop.watch_pending;
                if (!loop.watch_pending) loop.poll_at_ms = loop.now_ms;
            }
        } else {
            if (result.cancelled) {
                try loop.log("build: failed (timeout/cancelled)");
            } else try loop.log("build: failed");
            const text = if (result.cancelled) "Build timed out" else switch (result.len) {
                0 => "Build failed without output",
                else => result.output[0..result.len],
            };
            @memcpy(loop.error_text[0..6], "error:");
            @memcpy(loop.error_text[6..][0..text.len], text);
            loop.error_len = @intCast(text.len + 6);
        }
        if (pending) {
            assert(loop.change_revision > loop.started_change);
            loop.debounce_at_ms = loop.now_ms;
        }
    }

    fn publish(loop: *Loop) api.Failure!void {
        assert(!loop.watch_pending);
        if (!loop.publish_pending) return;
        assert(loop.build == .idle);
        if (loop.publish_skip_watch) {
            loop.publish_skip_watch = false;
            loop.poll_at_ms = loop.now_ms;
            return;
        }
        loop.publish_pending = false;
        if (loop.completed_change != loop.change_revision) return;
        try advance_revision(&loop.published_build);
        loop.set_reload(loop.build_dist);
    }

    fn set_reload(loop: *Loop, change: api.Changes) void {
        assert(loop.published_build > 0);
        const message = if (loop.config.hmr and change.wasm_only and change.wasm.len > 0)
            std.fmt.bufPrint(
                &loop.reload_text,
                "hmr:/{s}",
                .{change.wasm.slice()},
            ) catch @panic("hmr path bound")
        else
            "reload";
        if (std.mem.eql(u8, message, "reload")) @memcpy(loop.reload_text[0..6], "reload");
        loop.reload_len = @intCast(message.len);
        assert(loop.reload_len > 0);
    }

    fn release_snapshot(loop: *Loop, connection: *Connection) void {
        const index = connection.snapshot orelse return;
        const snapshot = &loop.snapshots[index];
        assert(snapshot.used);
        snapshot.owner = null;
        if (!snapshot.working) snapshot.used = false;
        connection.snapshot = null;
        connection.body = &.{};
        assert(snapshot.working or !snapshot.used);
    }

    fn close_connection(loop: *Loop, index: u16) void {
        assert(index < loop.connections.len);
        const connection = &loop.connections[index];
        assert(connection.state != .free);
        if (connection.state == .websocket) connection.reader.deinit();
        loop.io.vtable.close(loop.io.context, connection.handle);
        if (connection.upstream != api.handle_none) {
            loop.io.vtable.close(loop.io.context, connection.upstream);
        }
        loop.release_snapshot(connection);
        connection.reset();
    }

    fn close_all(loop: *Loop) void {
        for (&loop.connections, 0..) |*connection, index| {
            if (connection.state != .free) loop.close_connection(@intCast(index));
        }
    }

    fn diagnostic(loop: *Loop, label: []const u8, err: anyerror) api.Failure!void {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{s}: {s}",
            .{ label, @errorName(err) },
        ) catch @panic("diagnostic bound");
        return loop.log(message);
    }

    fn start_proxy(loop: *Loop, connection: *Connection) api.Failure!void {
        assert(connection.state == .request);
        assert(connection.upstream == api.handle_none);
        connection.upstream = loop.io.vtable.connect(loop.io.context) catch |err| {
            try loop.diagnostic("proxy", err);
            loop.small_response(connection, "502 Bad Gateway", "Bad Gateway");
            return;
        };
        connection.sent = 0;
        connection.state = .proxy_connect;
    }

    fn proxy_ready(loop: *Loop, index: u16, ready: api.Ready) api.Failure!void {
        const connection = &loop.connections[index];
        assert(connection.upstream != api.handle_none);
        if (connection.state == .proxy_connect and (ready.write or ready.closed)) {
            if (!loop.io.vtable.connected(loop.io.context, connection.upstream)) {
                loop.io.vtable.close(loop.io.context, connection.upstream);
                connection.upstream = api.handle_none;
                loop.small_response(connection, "502 Bad Gateway", "Bad Gateway");
                return;
            }
            connection.state = .proxy_request;
        }
        if (connection.state == .proxy_request and ready.write) {
            const bytes = connection.request[connection.sent..connection.request_len];
            assert(bytes.len > 0);
            switch (loop.io.vtable.write(loop.io.context, connection.upstream, bytes)) {
                .pending => {},
                .closed, .failed => loop.close_connection(index),
                .count => |count| {
                    connection.sent += count;
                    if (connection.sent == connection.request_len) {
                        connection.sent = 0;
                        connection.state = .proxy_read;
                    }
                },
            }
        } else if (connection.state == .proxy_read and (ready.read or ready.closed)) {
            switch (loop.io.vtable.read(loop.io.context, connection.upstream, &connection.output)) {
                .pending => {},
                .closed, .failed => loop.close_connection(index),
                .count => |count| {
                    assert(count > 0 and count <= connection.output.len);
                    connection.output_len = count;
                    connection.sent = 0;
                    connection.state = .proxy_write;
                },
            }
        } else if (ready.closed) loop.close_connection(index);
    }
};
