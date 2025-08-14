const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const llrb = b.dependency("llrb", .{ .target = target, .optimize = .Debug });
    _ = b.addModule("zigdb", .{
        .root_source_file = b.path("src/db.zig"),
        .imports = &.{.{ .name = "llrb", .module = llrb.module("llrb") }},
    });

    exe_mod.addImport("llrb", llrb.module("llrb"));

    const exe = b.addExecutable(.{
        .name = "comptime-orm",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
