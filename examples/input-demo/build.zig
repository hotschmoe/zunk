const std = @import("std");
const zunk = @import("zunk");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const zunk_dep = b.dependency("zunk", .{
        .target = wasm_target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "input-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zunk", .module = zunk_dep.module("zunk") },
            },
        }),
    });

    exe.rdynamic = true;
    exe.entry = .disabled;
    exe.export_memory = true;

    zunk.installApp(b, zunk_dep, exe, .{});
}
