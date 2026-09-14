const std = @import("std");

/// CRM（医学考试学习平台）构建脚本
/// 后端：Zig + http_framework（自研）+ zqlite（SQLite）
/// 前端：web/（Vue 3 + Vite），构建产物 web/dist 由本服务托管
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 外部依赖模块 ─────────────────────────────────────────────
    const framework = b.dependency("http_framework", .{}).module("http_framework");
    const zqlite = b.dependency("zqlite", .{}).module("zqlite");

    // ── 应用库模块（业务逻辑，供 exe 与测试复用）────────────────
    const mod = b.addModule("crm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "http_framework", .module = framework },
            .{ .name = "zqlite", .module = zqlite },
        },
    });

    // ── 可执行文件 ───────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "crm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "crm", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // ── run ──────────────────────────────────────────────────────
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // ── test ─────────────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
