const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webzocket = b.dependency("webzocket", .{}).module("webzocket");
    const rich_zig = b.dependency("rich_zig", .{}).module("rich_zig");

    const mod = b.addModule("zunk", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "zunk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zunk", .module = mod },
                .{ .name = "webzocket", .module = webzocket },
                .{ .name = "rich_zig", .module = rich_zig },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the zunk CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run all tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}

pub const InstallAppOptions = struct {
    port: u16 = 8080,
    output_dir: []const u8 = "dist",
};

pub fn installApp(
    b: *std.Build,
    dep: *std.Build.Dependency,
    user_exe: *std.Build.Step.Compile,
    options: InstallAppOptions,
) void {
    const cli = dep.artifact("zunk");
    b.installArtifact(user_exe);

    const gen_cmd = b.addRunArtifact(cli);
    gen_cmd.addArg("build");
    gen_cmd.addArg("--wasm");
    gen_cmd.addArtifactArg(user_exe);
    gen_cmd.addArg("--output-dir");
    gen_cmd.addArg(options.output_dir);
    gen_cmd.setCwd(b.path("."));
    b.getInstallStep().dependOn(&gen_cmd.step);

    const run_step = b.step("run", "Build and serve on localhost");
    const serve_cmd = b.addRunArtifact(cli);
    serve_cmd.addArg("run");
    serve_cmd.addArg("--wasm");
    serve_cmd.addArtifactArg(user_exe);
    serve_cmd.addArg("--output-dir");
    serve_cmd.addArg(options.output_dir);
    serve_cmd.addArg("--port");
    serve_cmd.addArg(b.fmt("{d}", .{options.port}));
    serve_cmd.setCwd(b.path("."));
    run_step.dependOn(&serve_cmd.step);
}
