const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

    const opts = b.addOptions();
    opts.addOption(usize, "reps", b.option(usize, "reps", "build cycles per measured run") orelse 10);
    opts.addOption(usize, "jitter", b.option(usize, "jitter", "max %% random downward size jitter per rep") orelse 10);
    opts.addOption(bool, "track", b.option(bool, "track", "report allocation counts/peaks") orelse false);
    opts.addOption(bool, "shuffle", b.option(bool, "shuffle", "use zBench's ShufflingAllocator") orelse false);

    const exe = b.addExecutable(.{
        .name = "collection_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zbench", .module = zbench.module("zbench") },
                .{ .name = "build_options", .module = opts.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the benchmarks");
    run_step.dependOn(&run_cmd.step);
}
