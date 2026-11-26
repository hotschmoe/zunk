const std = @import("std");
const assert = @import("src/assert.zig").assert;

fn versionString(b: *std.Build) []const u8 {
    const base: []const u8 = @import("build.zig.zon").version;
    _ = std.SemanticVersion.parse(base) catch @panic("build.zig.zon .version is not valid semver");
    const meta = b.option([]const u8, "version-meta", "Semver build metadata appended as +<meta>") orelse return base;
    return b.fmt("{s}+{s}", .{ base, meta });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", versionString(b));
    version_options.addOption([]const u8, "manifest_version", @import("build.zig.zon").version);
    const mod = b.addModule("zunk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", version_options);

    const exe = add_cli(b, b.graph.host, optimize, version_options);
    b.installArtifact(exe);
    const size_cmd = b.addSystemCommand(&.{ "node", "tools/test.mjs", "size" });
    size_cmd.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } });
    size_cmd.step.dependOn(b.getInstallStep());
    b.step("check-size", "Check the installed CLI against a 64 MiB budget")
        .dependOn(&size_cmd.step);

    const run_step = b.step("run", "Run the zunk CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tidy_run = add_tidy(b, optimize);

    const test_step = b.step("test", "Run the blocking end-to-end gate");
    const test_cmd = b.addSystemCommand(&.{ "node", "tools/test.mjs", "blocking" });
    test_cmd.step.dependOn(&tidy_run.step);
    test_cmd.step.dependOn(&size_cmd.step);
    test_cmd.addArtifactArg(exe);
    test_cmd.addArg(@tagName(optimize));
    test_step.dependOn(&test_cmd.step);

    const heavy_step = b.step("test-heavy", "Run the background end-to-end gate");
    const heavy_cmd = b.addSystemCommand(&.{ "node", "tools/test.mjs", "heavy" });
    heavy_cmd.addArtifactArg(exe);
    heavy_step.dependOn(&heavy_cmd.step);
    heavy_step.dependOn(add_cross(b, optimize, version_options));

    add_fuzz(b, optimize);
}

fn add_cli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version_options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const webzocket = b.dependency("webzocket", .{
        .target = target,
        .optimize = optimize,
    }).module("webzocket");
    const rich_zig = b.dependency("rich_zig", .{
        .target = target,
        .optimize = optimize,
    }).module("rich_zig");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", version_options);
    const exe = b.addExecutable(.{
        .name = "zunk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zunk", .module = mod },
                .{ .name = "webzocket", .module = webzocket },
                .{ .name = "rich_zig", .module = rich_zig },
            },
        }),
    });
    exe.root_module.addOptions("build_options", version_options);
    assert(exe.root_module.resolved_target.?.result.cpu.arch == target.result.cpu.arch);
    assert(exe.root_module.resolved_target.?.result.os.tag == target.result.os.tag);
    return exe;
}

fn add_cross(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    version_options: *std.Build.Step.Options,
) *std.Build.Step {
    const step = b.step("check-cross", "Compile the CLI for Linux, Windows and macOS on both CPUs");
    const targets: []const []const u8 = &.{
        "x86_64-linux",        "aarch64-linux", "x86_64-windows-gnu",
        "aarch64-windows-gnu", "x86_64-macos",  "aarch64-macos",
    };
    for (targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("invalid cross target");
        assert(query.cpu_arch.? == .x86_64 or query.cpu_arch.? == .aarch64);
        assert(query.os_tag.? == .linux or query.os_tag.? == .windows or query.os_tag.? == .macos);
        const exe = add_cli(b, b.resolveTargetQuery(query), optimize, version_options);
        _ = exe.getEmittedBin();
        step.dependOn(&exe.step);
    }
    return step;
}

fn add_fuzz(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const fuzz_options = b.addOptions();
    const fuzz_commit = b.option([]const u8, "commit", "Commit recorded by the tester") orelse
        "unknown";
    fuzz_options.addOption([]const u8, "commit", fuzz_commit);
    const fuzz = b.addExecutable(.{
        .name = "zunk-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    fuzz.root_module.addOptions("fuzz_options", fuzz_options);
    assert(fuzz.root_module.resolved_target.?.result.os.tag == b.graph.host.result.os.tag);
    assert(fuzz.root_module.resolved_target.?.result.cpu.arch == b.graph.host.result.cpu.arch);
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addPassthruArgs();
    b.step("fuzz", "Run seeded build-path generation and oracles").dependOn(&fuzz_run.step);
    const fuzz_long = b.addRunArtifact(fuzz);
    fuzz_long.addArgs(&.{ "--iterations", "200000" });
    b.step("fuzz-heavy", "Run the random background build-path gate").dependOn(&fuzz_long.step);
}

fn add_tidy(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "assert", .module = b.createModule(.{
                .root_source_file = b.path("src/assert.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }) }},
        }),
    });
    const run = b.addRunArtifact(tidy);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("tidy", "Measure Zig style and enforce ratchets").dependOn(&run.step);
    return run;
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
