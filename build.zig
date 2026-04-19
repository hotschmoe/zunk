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
    /// Zig dependencies that ship a `bridge.js` at their package root. Each
    /// listed dep must actually have a `bridge.js` file -- resolution is
    /// lazy, so a typo or missing file fails loudly when the RunStep executes.
    /// Order is preserved; earlier entries are emitted earlier in the merged
    /// JS. The user project's own `bridge.js` (if any) is always emitted last
    /// so it can override dep-provided symbols.
    bridge_deps: []const *std.Build.Dependency = &.{},
    /// Name of the build-and-serve step registered by `installApp`. Override
    /// when the host `build.zig` already owns a step named `"run"` (e.g. a
    /// non-web CLI variant) to avoid a duplicate-step error.
    run_step_name: []const u8 = "run",
    /// If non-null, also register a build-only step with this name that
    /// produces the `dist/` artifacts without starting the dev server.
    build_step_name: ?[]const u8 = null,
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
    for (options.bridge_deps) |bd| {
        gen_cmd.addArg("--bridge-dep");
        gen_cmd.addFileArg(bd.path("bridge.js"));
    }
    gen_cmd.setCwd(b.path("."));
    b.getInstallStep().dependOn(&gen_cmd.step);

    if (options.build_step_name) |name| {
        const build_step = b.step(name, "Build the web app (no server)");
        build_step.dependOn(&gen_cmd.step);
    }

    const run_step = b.step(options.run_step_name, "Build and serve on localhost");
    const serve_cmd = b.addRunArtifact(cli);
    serve_cmd.addArg("run");
    serve_cmd.addArg("--wasm");
    serve_cmd.addArtifactArg(user_exe);
    serve_cmd.addArg("--output-dir");
    serve_cmd.addArg(options.output_dir);
    serve_cmd.addArg("--port");
    serve_cmd.addArg(b.fmt("{d}", .{options.port}));
    for (options.bridge_deps) |bd| {
        serve_cmd.addArg("--bridge-dep");
        serve_cmd.addFileArg(bd.path("bridge.js"));
    }
    serve_cmd.setCwd(b.path("."));
    run_step.dependOn(&serve_cmd.step);
}
