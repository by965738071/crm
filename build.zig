const std = @import("std");

/// CRM（多专业考试学习平台）构建脚本
/// 后端：Zig + http_framework（自研）+ zqlite（SQLite）
/// 前端：web/（Vue 3 + Vite）。-Dembed-dist=true 时把 web/dist 以 @embedFile
/// 编进可执行文件（单文件部署，默认关闭）；未内嵌时回退为运行期托管
/// web/dist 目录（开发模式）。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 外部依赖模块 ─────────────────────────────────────────────
    const framework = b.dependency("http_framework", .{}).module("http_framework");
    // zqlite 必须随主构建的 optimize/target 编译：它捆绑的 sqlite3.c 在 Debug 下会被
    // zig 驱动插桩 UBSan；若固定在 Debug 编译而主程序用 ReleaseSafe/Fast（不链
    // ubsan 运行时）链接，lld 会报 __ubsan_handle_* 未定义。
    const zqlite = (b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    })).module("zqlite");

    // ── 前端产物内嵌模块（web/dist → @embedFile 代码生成）────────
    const dist_assets = embedDistCodegen(b, target, optimize);

    // ── 应用库模块（业务逻辑，供 exe 与测试复用）────────────────
    const mod = b.addModule("crm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "http_framework", .module = framework },
            .{ .name = "zqlite", .module = zqlite },
            .{ .name = "dist_assets", .module = dist_assets },
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

/// 扫描 web/dist，自动生成一个把全部前端文件以 @embedFile 内嵌的源码模块。
/// 生成源码形如：
///     pub const File = struct { path: []const u8, content: []const u8 };
///     pub const files = &[_]File{ .{ .path = "assets/x.js", .content = @embedFile("f0") } };
/// 目录缺失 / -Dembed-dist=false → files 为空数组，运行期由
/// src/web/dist_embed.zig 的 enabled 常量回退到磁盘托管。
fn embedDistCodegen(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const arena = b.graph.arena;

    const embed = b.option(bool, "embed-dist", "Embed web/dist frontend build output into the binary (default: false)") orelse false;

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(arena,
        \\//! 由 build.zig 自动生成，请勿手动编辑。
        \\//! web/dist 前端构建产物在编译期内嵌进二进制。
        \\//! files 为空表示未内嵌（-Dembed-dist=false 或 web/dist 缺失），
        \\//! 此时后端回退为运行期托管 web/dist 目录。
        \\
        \\pub const File = struct { path: []const u8, content: []const u8 };
        \\
        \\pub const files = &[_]File{
    ) catch @panic("OOM");

    if (embed) {
        collectDist(b, wf, &src) catch |err| {
            std.log.warn("web/dist not embeddable ({s}): run `npx vite build` in web/ first, or use -Dembed-dist=false", .{@errorName(err)});
        };
    }

    src.appendSlice(arena, "};\n") catch @panic("OOM");
    const gen = wf.add("dist_assets.zig", src.items);
    return b.createModule(.{
        .root_source_file = gen,
        .target = target,
        .optimize = optimize,
    });
}

/// 遍历 web/dist：每个文件复制进生成目录（扁平名 f0/f1/…），并追加一条
/// `.{ .path = "...", .content = @embedFile("fN") },` 到 src。
fn collectDist(b: *std.Build, wf: *std.Build.Step.WriteFile, src: *std.ArrayList(u8)) !void {
    const arena = b.graph.arena;
    const io = b.graph.io;

    var dir = try b.root.root_dir.handle.openDir(io, "web/dist", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    var count: usize = 0;
    while (true) {
        const entry = (try walker.next(io)) orelse break;
        if (entry.kind != .file) continue;
        // Windows 下 entry.path 用反斜杠；URL 键统一 '/'
        const rel = arena.alloc(u8, entry.path.len) catch @panic("OOM");
        for (entry.path, 0..) |ch, i| rel[i] = if (ch == '\\') '/' else ch;

        const src_rel = std.fmt.allocPrint(arena, "web/dist/{s}", .{rel}) catch @panic("OOM");
        const embed_name = std.fmt.allocPrint(arena, "f{d}", .{count}) catch @panic("OOM");
        _ = wf.addCopyFile(b.path(src_rel), embed_name);

        const line = std.fmt.allocPrint(arena, ".{{ .path = \"{s}\", .content = @embedFile(\"{s}\") }},\n", .{
            zigEscapePath(arena, rel) catch @panic("OOM"),
            embed_name,
        }) catch @panic("OOM");
        src.appendSlice(arena, line) catch @panic("OOM");
        count += 1;
    }
    std.log.info("embedded web/dist: {d} files", .{count});
}

/// 把路径转成可安全放进 Zig 字符串字面量的形式（std.zig.fmtEscapes 在本 std 已移除）。
/// 转义反斜杠、双引号、控制字符；其余字节（含 UTF-8 多字节）原样保留。
fn zigEscapePath(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(arena, "\\\\"),
            '"' => try out.appendSlice(arena, "\\\""),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{ch}));
                } else {
                    try out.append(arena, ch);
                }
            },
        }
    }
    return out.items;
}
