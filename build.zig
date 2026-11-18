const std = @import("std");

fn versionString(b: *std.Build) []const u8 {
    const base: []const u8 = @import("build.zig.zon").version;
    _ = std.SemanticVersion.parse(base) catch @panic("build.zig.zon .version is not valid semver");
    const meta = b.option([]const u8, "version-meta", "Semver build metadata appended as +<meta>") orelse return base;
    return b.fmt("{s}+{s}", .{ base, meta });
}

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webzocket = b.dependency("webzocket", .{}).module("webzocket");
    const rich_zig = b.dependency("rich_zig", .{}).module("rich_zig");

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", versionString(b));
    version_options.addOption([]const u8, "manifest_version", @import("build.zig.zon").version);

    const mod = b.addModule("zunk", .{
        .root_source_file = b.path("src/root.zig"),
    });
    mod.addOptions("build_options", version_options);

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

    exe.root_module.addOptions("build_options", version_options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the zunk CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run the blocking end-to-end gate");
    const test_cmd = b.addSystemCommand(&.{ "node", "tools/test.mjs", "blocking" });
    test_cmd.addArtifactArg(exe);
    test_step.dependOn(&test_cmd.step);

    const heavy_step = b.step("test-heavy", "Run the background end-to-end gate");
    const heavy_cmd = b.addSystemCommand(&.{ "node", "tools/test.mjs", "heavy" });
    heavy_cmd.addArtifactArg(exe);
    heavy_step.dependOn(&heavy_cmd.step);
}

pub const InstallAppOptions = struct {
    port: u16 = 8080,
    output_dir: []const u8 = "dist",
    bridge_deps: []const *std.Build.Dependency = &.{},
    run_step_name: []const u8 = "run",
    build_step_name: ?[]const u8 = null,
    fonts: []const FontFile = &.{},
};

pub const FontFile = struct {
    family: []const u8,
    weight: u16 = 400,
    path: std.Build.LazyPath,
};

pub fn addFontArgs(run: *std.Build.Step.Run, fonts: []const FontFile) void {
    for (fonts) |f| {
        run.addArg("--font");
        run.addArg(f.family);
        run.addArg(run.step.owner.fmt("{d}", .{f.weight}));
        run.addFileArg(f.path);
    }
}

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
    addFontArgs(gen_cmd, options.fonts);
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
    addFontArgs(serve_cmd, options.fonts);
    serve_cmd.setCwd(b.path("."));
    run_step.dependOn(&serve_cmd.step);
}
