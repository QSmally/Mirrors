
const std = @import("std");
const builtin = @import("builtin");

const Target = std.Build.StandardTargetOptionsArgs;

pub fn build(b: *std.Build) void {
    const default_target: Target = if (builtin.target.os.tag == .macos)
        .{} else
        .{ .default_target = .{ .abi = .musl } };
    const target = b.standardTargetOptions(default_target);
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(u16, "port", b.option(u16, "port", "HTTP port, default 80") orelse 80);
    options.addOption(usize, "housekeeping_s", b.option(usize, "housekeeping_s", "minimum housekeeping interval in seconds, default 500 seconds") orelse 500);
    options.addOption(usize, "housekeeping_len", b.option(usize, "housekeeping_len", "maximum housekeeping file len, default 16 files (* 50 = ~800 MiB)") orelse 16);
    options.addOption(usize, "fail_ratelimit_s", b.option(usize, "fail_ratelimit_s", "failure ratelimit in seconds, default 120 seconds") orelse 120);

    const minizign = b.dependency("minizign", .{
        .target = target,
        .optimize = optimize });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize });

    const mirror_zig = b.addModule("mirror_zig", .{
        .root_source_file = b.path("zig/module.zig"),
        .target = target,
        .optimize = optimize });
    mirror_zig.addImport("httpz", httpz.module("httpz"));
    mirror_zig.addImport("minizign", minizign.module("minizign"));

    const mirror_cdn = b.addModule("mirror_cdn", .{
        .root_source_file = b.path("cdn/module.zig"),
        .target = target,
        .optimize = optimize });
    mirror_cdn.addImport("httpz", httpz.module("httpz"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize });
    root_module.addImport("httpz", httpz.module("httpz"));
    root_module.addImport("mirror_zig", mirror_zig);
    root_module.addImport("mirror_cdn", mirror_cdn);
    root_module.addOptions("options", options);

    mirror_zig.addImport("lib", root_module);
    mirror_cdn.addImport("lib", root_module);

    const exec = b.addExecutable(.{
        .name = "mirrors",
        .root_module = root_module });
    b.installArtifact(exec);

    const run = b.addRunArtifact(exec);
    const run_step = b.step("run", "run");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "application tests");
    test_step.dependOn(&run_tests.step);
}
