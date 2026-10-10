const std = @import("std");

/// CRM（多专业考试学习平台）构建脚本
/// 后端：Zig + http_framework（自研）+ zqlite（SQLite）
/// 前端：web/（Vue 3 + Vite）。-Dembed-dist=true 时把 web/dist 以 @embedFile
/// 编进可执行文件（单文件部署，默认关闭）；未内嵌时回退为运行期托管
/// web/dist 目录（开发模式）。
pub fn build(b: *std.Build) !void {
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
    const dist_assets = try embedDistCodegen(b, target, optimize);

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
) !*std.Build.Module {
    const arena = b.graph.arena;

    const embed = b.option(bool, "embed-dist", "Embed web/dist frontend build output into the binary (default: false)") orelse false;

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena,
        \\//! 由 build.zig 自动生成，请勿手动编辑。
        \\//! web/dist 前端构建产物在编译期内嵌进二进制。
        \\//! files 为空表示未内嵌（-Dembed-dist=false 或 web/dist 缺失），
        \\//! 此时后端回退为运行期托管 web/dist 目录。
        \\
        \\pub const File = struct { path: []const u8, content: []const u8 };
        \\
        \\pub const files = &[_]File{
    );

    if (embed) {
        // 内嵌前先在 web/ 下构建前端（bun run build，PATH 中找不到 bun 时回退
        // npm run build），确保 web/dist 已存在且为最新产物，再交给 collectDist
        // 扫描并以 @embedFile 嵌入。collectDist 在 configure 阶段枚举目录，故此处
        // 必须在 configure 阶段同步完成构建，否则嵌入的是空数组。
        try ensureFrontendBuilt(b);

        // 把 web/dist 的状态显式登记为 configure 依赖：任何构建/删除/重命名都会让
        // 配置缓存失效并重新执行 configure + vite，无需 --cache-poison 就能自愈
        // "手动 rm -rf web/dist"或"外部重建前端"的场景。
        // 说明：dependOnDirectoryContents 非递归且只看条目名；vite 产物按内容哈希
        // 命名，内容变化必然伴随重命名或 index.html 内容变化，故这三项足以覆盖
        // 外部重建。递归监听 web/src 不可行（同样有非递归限制）。
        b.dependOnDirectoryContents(b.path("web/dist"));
        b.dependOnDirectoryContents(b.path("web/dist/assets"));
        b.dependOnFileContents(b.path("web/dist/index.html"));

        try collectDist(b, wf, &src);
    }

    try src.appendSlice(arena, "};\n");
    const gen = wf.add("dist_assets.zig", src.items);
    return b.createModule(.{
        .root_source_file = gen,
        .target = target,
        .optimize = optimize,
    });
}

/// 遍历 web/dist：把每个文件内容在 configure 阶段读入（arena 分配），用
/// `wf.add(embed_name, content)` 写进 configuration，并追加一条
/// `.{ .path = "...", .content = @embedFile("fN") },` 到 src。
/// 注意这里刻意不用 `wf.addCopyFile`：它会在 make 阶段才去读 web/dist，而
/// configure 缓存的 key 不包含 web/dist 内容——手动删除/改动 dist 不会触发
/// 重新 configure，make 阶段 WriteFile 的缓存检查会直接 fatal
/// "checking cache failed: file_open FileNotFound <dist 文件>"。内容进
/// configuration 后，make 只读缓存目录，删除 web/dist 不再影响构建；内容
/// 的刷新时机由 embedDistCodegen 中 dependOn* 登记的 configure 依赖自动驱动
/// （web/dist 条目增删改名、index.html 变化都会重跑 configure + vite）。
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
        const rel = try arena.alloc(u8, entry.path.len);
        for (entry.path, 0..) |ch, i| rel[i] = if (ch == '\\') '/' else ch;

        const content = try dir.readFileAlloc(io, entry.path, arena, .unlimited);
        const embed_name = try std.fmt.allocPrint(arena, "f{d}", .{count});
        _ = wf.add(embed_name, content);

        const line = try std.fmt.allocPrint(arena, ".{{ .path = \"{s}\", .content = @embedFile(\"{s}\") }},\n", .{
            try zigEscapePath(arena, rel),
            embed_name,
        });
        try src.appendSlice(arena, line);
        count += 1;
    }
    std.log.info("embedded web/dist: {d} files", .{count});
}

/// 内嵌前在 web/ 下执行前端构建：优先 `bun run build`，PATH 中找不到 bun 时
/// 回退 `npm run build`。构建在 configure 阶段同步执行，保证随后 collectDist
/// 扫描 web/dist 时产物已就绪。
///
/// 关键约束：configure 阶段本进程的 stdout 被 maker 用作序列化 configuration
/// 文件的写入通道，子进程绝不能继承它，否则前端输出会写坏配置文件（表现为误导性
/// 的 "failed to load configuration file .zig-cache/tmp/<hash>: OutOfMemory"）。
/// 本版本 Zig 的 std.process.spawn 对 .stdout = .file 要求路径型 File，无法拿
/// stderr 句柄顶替；而 vite 的进度、警告、错误都在 stderr（继承后可实时显示），
/// stdout 只有产物清单，故直接丢弃。
fn ensureFrontendBuilt(b: *std.Build) !void {
    const arena = b.graph.arena;
    const web_dir = try b.root.joinString(arena, "web");

    // 优先 bun，PATH 中找不到 bun 时回退 npm（通过 `bun --version` 探测）。
    const pkg = if (frontendPkgExists(b, "bun")) "bun" else "npm";
    std.log.info("embed-dist: running `{s} run build` in web/", .{pkg});

    var child = try std.process.spawn(b.graph.io, .{
        .argv = &.{ pkg, "run", "build" },
        .cwd = .{ .path = web_dir },
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(b.graph.io);

    if (!term.success()) {
        std.log.err("`{s} run build` {}", .{ pkg, term });
        return error.FrontendBuildFailed;
    }
}

/// 探测 PATH 中是否存在给定包管理器：尝试以 `--version` 启动，能启动且退出码
/// 为 0 即视为存在。找不到（FileNotFound）或启动失败则返回 false。
fn frontendPkgExists(b: *std.Build, name: []const u8) bool {
    const probe_argv = [2][]const u8{ name, "--version" };
    var child = std.process.spawn(b.graph.io, .{
        .argv = &probe_argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(b.graph.io) catch return false;
    return term.success();
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
