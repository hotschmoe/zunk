const std = @import("std");
const assert = @import("../assert.zig").assert;
const api = @import("serve_io.zig");
const os = @import("serve_os.zig");
const Loop = @import("serve_loop.zig").Loop;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    config: api.Config,
};

pub fn serve(options: Options) !void {
    const real = try reserve(os.Real, options.allocator);
    defer options.allocator.rawFree(std.mem.asBytes(real), .of(os.Real), @returnAddress());
    const loop = try reserve(Loop, options.allocator);
    defer options.allocator.rawFree(std.mem.asBytes(loop), .of(Loop), @returnAddress());
    try real.init(.{
        .io = options.io,
        .root = options.root,
        .config = options.config,
    });
    defer real.deinit();
    assert(real.file_future != null);
    loop.init(real.interface(), options.config);
    assert(loop.io.context == @as(*anyopaque, @ptrCast(real)));
    try loop.run();
}

fn reserve(comptime T: type, allocator: std.mem.Allocator) error{OutOfMemory}!*T {
    return @ptrCast(@alignCast(allocator.rawAlloc(
        @sizeOf(T),
        .of(T),
        @returnAddress(),
    ) orelse return error.OutOfMemory));
}
