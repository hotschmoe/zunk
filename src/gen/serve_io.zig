const assert = @import("../assert.zig").assert;

pub const connections_max: u16 = 16;
pub const snapshots_max: u16 = 4;
pub const request_bytes_max: u32 = 4096;
pub const path_bytes_max: u16 = 1024;
pub const file_bytes_max: u32 = 50 * 1024 * 1024;
pub const output_bytes_max: u32 = 60000;
pub const message_bytes_max: u32 = output_bytes_max + 512;
pub const poll_ms: u64 = 500;
pub const debounce_ms: u64 = 100;
pub const connection_timeout_ms: u64 = 30000;
pub const build_timeout_ms: u64 = 120000;
pub const handle_none: u32 = @bitCast(@as(i32, -1));

pub const Config = struct {
    autoreload: bool = true,
    port: u16 = 8080,
    watch_sources: bool = true,
    watch_paths: []const []const u8 = &.{"src"},
    watch_files: []const []const u8 = &.{ "build.zig", "build.zig.zon" },
    build_cmd: []const []const u8 = &.{ "zig", "build" },
    proxy_prefix: ?[]const u8 = null,
    proxy_target: ?[]const u8 = null,
    hmr: bool = false,
};

pub const Path = struct {
    bytes: [path_bytes_max]u8 = undefined,
    len: u16 = 0,

    pub fn init(bytes: []const u8) error{PathLimit}!Path {
        if (bytes.len > path_bytes_max) return error.PathLimit;
        var path: Path = .{};
        @memcpy(path.bytes[0..bytes.len], bytes);
        path.len = @intCast(bytes.len);
        assert(path.len == bytes.len);
        assert(path.len <= path_bytes_max);
        return path;
    }

    pub fn slice(path: *const Path) []const u8 {
        return path.bytes[0..path.len];
    }
};

pub const Failure = error{
    System,
    NotFound,
    Changed,
    FileLimit,
    PathLimit,
    WatchLimit,
    Busy,
    InvalidConfig,
};
pub const Transfer = union(enum) { pending, count: u32, closed, failed };
pub const Accept = union(enum) { pending, handle: u32, failed };
pub const Interest = struct { handle: u32, token: u16, read: bool, write: bool };
pub const Ready = struct { token: u16, read: bool, write: bool, closed: bool };
pub const FileOperation = enum { open, read, verify_close, close };
pub const Metadata = struct {
    size: u64,
    inode: u64,
    modified_ns: i128,
    changed_ns: i128,
};
pub const FileValue = union(enum) {
    opened: Metadata,
    read: u32,
    verified: struct { handle: Metadata, path: Metadata },
    closed,
};
pub const FileJob = struct {
    index: u16,
    path: Path,
    buffer: []u8,
    operation: FileOperation,
    offset: u32 = 0,
};
pub const FileResult = struct { index: u16, result: Failure!FileValue };
pub const Changes = struct {
    source: bool = false,
    dist: bool = false,
    wasm_only: bool = false,
    wasm: Path = .{},
};
pub const BuildResult = struct {
    success: bool = false,
    cancelled: bool = false,
    io_failed: bool = false,
    truncated: bool = false,
    output: [output_bytes_max]u8 = undefined,
    len: u32 = 0,
};
pub const Event = struct {
    now_ms: u64,
    value: union(enum) {
        timer,
        accept,
        stop,
        ready: Ready,
        file: FileResult,
        changes: Failure!Changes,
        build: BuildResult,
    },
};

pub const Interface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listen: *const fn (*anyopaque, u16) Failure!void,
        accept: *const fn (*anyopaque) Accept,
        read: *const fn (*anyopaque, u32, []u8) Transfer,
        write: *const fn (*anyopaque, u32, []const u8) Transfer,
        close: *const fn (*anyopaque, u32) void,
        connect: *const fn (*anyopaque) Failure!u32,
        connected: *const fn (*anyopaque, u32) bool,
        file: *const fn (*anyopaque, FileJob) Failure!void,
        watch: *const fn (*anyopaque) Failure!void,
        build: *const fn (*anyopaque) Failure!void,
        cancel_build: *const fn (*anyopaque) void,
        wait: *const fn (*anyopaque, []const Interest, u64, bool) Failure!Event,
        log: *const fn (*anyopaque, []const u8) Failure!void,
    };
};
