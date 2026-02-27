const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module -- the public "zunk" package that user projects import.
    // No target set: inherits from whatever compile step imports it.
    const mod = b.addModule("zunk", .{
        .root_source_file = b.path("src/root.zig"),
    });

    // CLI executable -- the `zunk` build tool (always compiled for host)
    const exe = b.addExecutable(.{
        .name = "zunk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zunk", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // -- run step --
    const run_step = b.step("run", "Run the zunk CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -- test step --
    const test_step = b.step("test", "Run all tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}

// -- Build integration for consumer projects --

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

    // Default install step: compile WASM + generate dist/
    const gen_cmd = b.addRunArtifact(cli);
    gen_cmd.addArg("build");
    gen_cmd.addArg("--wasm");
    gen_cmd.addArtifactArg(user_exe);
    gen_cmd.addArg("--output-dir");
    gen_cmd.addArg(options.output_dir);
    gen_cmd.setCwd(b.path("."));
    b.getInstallStep().dependOn(&gen_cmd.step);

    // "run" step: build + serve
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
