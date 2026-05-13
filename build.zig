const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .musl,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const common = b.createModule(.{
        .root_source_file = b.path("src/common/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    addExe(b, target, optimize, "preprocess", "src/preprocess/main.zig", common, true);
    addExe(b, target, optimize, "api", "src/api/main.zig", common, true);
    addExe(b, target, optimize, "lb", "src/lb/main.zig", common, true);

    const test_step = b.step("test", "Run unit tests");
    const files = [_][]const u8{
        "src/common/lib.zig",
        "src/common/mcc.zig",
        "src/common/quant.zig",
        "src/common/index_format.zig",
        "src/common/features.zig",
        "src/common/simd.zig",
        "src/api/parser.zig",
    };
    for (files) |f| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(f),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    src: []const u8,
    common: *std.Build.Module,
    link_libc: bool,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    mod.addImport("common", common);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step_name = b.fmt("run-{s}", .{name});
    b.step(step_name, b.fmt("Run {s}", .{name})).dependOn(&run.step);
}
