// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip symbols and debug information") orelse false;
    const version = b.option([]const u8, "version", "Version reported by --version") orelse "0.1.0-dev";
    const kdump_prefix = b.option([]const u8, "kdump-prefix", "Directory containing static libkdumpfile and codec archives");

    const exe = addUdmesg(b, target, optimize, strip, version, "udmesg", null);
    b.installArtifact(exe);
    if (kdump_prefix) |prefix| {
        const kdump_exe = addUdmesg(b, target, optimize, strip, version, "udmesg-kdump", prefix);
        b.installArtifact(kdump_exe);
        const arch = switch (target.result.cpu.arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            else => @panic("udmesg-kdump release supports amd64 and arm64 hosts"),
        };
        const asset = b.fmt("udmesg-kdump-linux-{s}", .{arch});
        const release_exe = addUdmesg(b, target, .ReleaseSmall, true, version, asset, prefix);
        const install = b.addInstallArtifact(release_exe, .{ .dest_sub_path = asset });
        const kdump_release = b.step("kdump-release", "Build a static kdump-enabled Linux binary");
        kdump_release.dependOn(&install.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);

    const fixture_exe = addFixtureTool(b, target, .ReleaseSmall);
    const cli_tests = b.addSystemCommand(&.{ "sh", "tools/cli-test.sh" });
    cli_tests.addArtifactArg(exe);
    cli_tests.addArtifactArg(fixture_exe);
    cli_tests.addArg(version);
    test_step.dependOn(&cli_tests.step);

    const release_step = b.step("release", "Build stripped static Linux amd64 and arm64 binaries");
    addRelease(b, release_step, .x86_64, "udmesg-linux-amd64", version);
    addRelease(b, release_step, .aarch64, "udmesg-linux-arm64", version);

    const bench_exe = addUdmesg(b, target, .ReleaseSmall, true, version, "udmesg-bench", null);
    const bench = b.addSystemCommand(&.{ "sh", "tools/bench.sh" });
    bench.addArtifactArg(bench_exe);
    bench.addArtifactArg(fixture_exe);
    const bench_step = b.step("bench", "Report native ReleaseSmall size and smoke-test timing");
    bench_step.dependOn(&bench.step);

    const fixture_run = b.addRunArtifact(fixture_exe);
    if (b.args) |args| fixture_run.addArgs(args);
    const fixture_step = b.step("fixture", "Write a synthetic raw ELF vmcore fixture");
    fixture_step.dependOn(&fixture_run.step);
}

fn addFixtureTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const fixture_module = b.createModule(.{
        .root_source_file = b.path("src/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    return b.addExecutable(.{
        .name = "make-udmesg-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/make_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "fixture", .module = fixture_module }},
        }),
    });
}

fn addUdmesg(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    version: []const u8,
    name: []const u8,
    kdump_prefix: ?[]const u8,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "kdump", kdump_prefix != null);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = true,
    });
    module.addOptions("build_options", options);
    if (kdump_prefix) |prefix| {
        module.link_libc = true;
        module.addCSourceFile(.{ .file = b.path("src/kdump_bridge.c"), .flags = &.{"-std=c11"} });
        module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        for ([_][]const u8{
            "libkdumpfile.a",
            "libaddrxlat.a",
            "libzstd.a",
            "libsnappy.a",
            "liblzo2.a",
            "libz.a",
            "libstdc++.a",
            "libgcc_eh.a",
        }) |archive| module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}", .{ prefix, archive }) });
    }

    return b.addExecutable(.{
        .name = name,
        .root_module = module,
        .linkage = if (target.result.os.tag == .linux) .static else null,
    });
}

fn addRelease(
    b: *std.Build,
    release_step: *std.Build.Step,
    arch: std.Target.Cpu.Arch,
    asset_name: []const u8,
    version: []const u8,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .linux,
        .abi = .musl,
    });
    const exe = addUdmesg(b, target, .ReleaseSmall, true, version, asset_name, null);
    const install = b.addInstallArtifact(exe, .{ .dest_sub_path = asset_name });
    release_step.dependOn(&install.step);
}
