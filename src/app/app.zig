//! 应用装配入口：配置 → 数据库 → 迁移/种子 → 中间件 → 路由 → HTTP 服务。

const std = @import("std");
const framework = @import("http_framework");

const state = @import("state.zig");
const router = @import("router.zig");
const db = @import("../db/db.zig");
const migrate = @import("../db/migrate.zig");
const identity = @import("../svc/identity.zig");

/// 应用级路径。framework.Config 只有网络/HTTP/body/pool 分层配置，
/// 没有应用级字段与加载机制——缺口已在 http-framework-issues.md 中起草提 issue。
const data_dir = "data";
const db_path: [:0]const u8 = data_dir ++ "/crm.db";
const static_dir = "web/dist";

/// 由 main 经 framework.runZio 在 zio 协程上下文中调用
pub fn appMain(io: std.Io, allocator: std.mem.Allocator) !void {
    // 服务器配置：直接使用 framework 的分层 Config（network/http/body/pool）
    const cfg = framework.Config{
        .network = .{
            .address = "127.0.0.1", // 生产环境改 0.0.0.0
            .port = 8080,
            .reuse_address = true,
        },
        .http = .{ .server_name = "crm/0.1" },
        .body = .{ .size_limit = 16 * 1024 * 1024 }, // 16MB，后续支持视频上传时再评估
    };

    // 数据目录（SQLite 文件与后续上传目录都放这里）
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const database = try allocator.create(db.Db);
    errdefer allocator.destroy(database);
    database.* = try db.Db.open(allocator, db_path);
    errdefer database.close();

    try migrate.run(database, io, allocator);

    const st = try allocator.create(state.State);
    // （不用单独的 errdefer destroy(st)：字面量装配无失败点，统一由下方块 errdefer 接管）
    st.* = .{
        .allocator = allocator,
        .config = cfg,
        .db = database,
        .started_at_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
        .session = framework.SessionManager.init(allocator, io, .{
            .cookie_name = "crm_session",
            .session_timeout_sec = 24 * 3600, // 滑动窗口 24h
            .secure = false, // 开发环境明文 HTTP；生产上 TLS 后必须改 true
        }),
        .login_guard = identity.LoginGuard.init(allocator),
        .static_index = framework.StaticFileServer.init(allocator, io, static_dir, "/"),
        .static_assets = framework.StaticFileServer.init(allocator, io, static_dir, "/static"),
        .security = .{ .config = .{} },
        .cors = .{ .config = .{} },
        .rate = framework.RateLimiter.init(allocator, io, .{
            .window_seconds = 60,
            .max_requests = 600,
            .per_ip = false,
        }),
    };
    // 自引用回填：中间件指向 State 内的 session（State 堆分配，地址稳定）
    st.auth_user.session = &st.session;
    st.auth_admin.session = &st.session;
    // SPA 入口预载入内存（缺失 = 前端未构建，空串即可，非错误）
    st.spa.html = std.Io.Dir.cwd().readFileAlloc(io, static_dir ++ "/index.html", allocator, .limited(1 << 20)) catch "";

    errdefer {
        if (st.spa.html.len > 0) allocator.free(st.spa.html);
        st.session.deinit();
        st.login_guard.deinit();
        allocator.destroy(st);
    }

    // 服务注册表：handler 经 ctx.service(state.State) 取回应用上下文，不用全局变量。
    // 注意：Services 不持有所有权；st 必须在 server 停止、rt.deinit() 之后才能销毁。
    var services = framework.Services.init(allocator);
    errdefer services.deinit();
    try services.register(state.State, st);
    services.seal(); // 封箱：运行期再 register 会显式报错

    var rt = try framework.Router.init(allocator);
    errdefer rt.deinit();
    // 注意：rt.deinit() 会触发中间件 destroy 钩子（如 RateLimiter.deinit），
    // 必须发生在销毁 st 之前 → 不用 defer，在 run() 返回后按序清理。

    const audit_mw = @import("audit_middleware.zig");
    const audit_repo_mod = @import("../db/audit_repo.zig");
    var audit_repo_inst = audit_repo_mod.AuditLogRepo.init(database);
    const audit_middleware_inst = try allocator.create(audit_mw.AuditLogMiddleware);
    audit_middleware_inst.* = audit_mw.AuditLogMiddleware.init(&audit_repo_inst, allocator);
    errdefer allocator.destroy(audit_middleware_inst);

    // 使用框架内置的日志中间件（http_logging 模块已实现完整能力）
    var framework_logger = try framework.Logger.init(allocator, io, .{
        .min_level = .info,
        .format = .text,
        .output = .file,
        .file = .{ .path = data_dir ++ "/logs/app.log", .max_size = 1024 * 1024, .max_backups = 3, .compress = false },
    });
    errdefer framework_logger.deinit();
    const framework_log_mw = try allocator.create(framework.LoggingMiddleware);
    framework_log_mw.* = .{ .logger = &framework_logger };
    errdefer allocator.destroy(framework_log_mw);

    // 先注册 = 外层 = 先执行
    try rt.use(framework.Middleware.init(framework.ErrorRenderer, &st.error_renderer));
    try rt.use(framework.Middleware.init(framework.RequestIdMiddleware, &st.request_id));
    try rt.use(framework.Middleware.init(framework.SecurityHeaders, &st.security));
    try rt.use(framework.Middleware.init(framework.CorsMiddleware, &st.cors));
    try rt.use(framework.Middleware.init(framework.RateLimiter, &st.rate));
    // 审计日志中间件（记录所有操作到数据库）
    try rt.use(framework.Middleware.init(audit_mw.AuditLogMiddleware, audit_middleware_inst));
    // 应用运行日志中间件（使用框架内置 http_logging.Logger + LoggingMiddleware）
    try rt.use(framework.Middleware.init(framework.LoggingMiddleware, framework_log_mw));

    try router.register(st, &rt);

    var server = try framework.Server.init(allocator, io, cfg, &rt);
    errdefer server.deinit();
    server.setServices(&services); // services 是 appMain 栈上变量，run() 阻塞期间地址稳定

    try server.setup();
    try server.run(); // 阻塞，收到 SIGINT/SIGTERM 后返回

    // ---- 优雅退出清理（与 errdefer 链等价的显式顺序，不能换）----
    // 1. 先停服务；2. rt.deinit() 会经中间件 destroy 钩子自动调 RateLimiter.deinit 等，
    //    此时 st 必须仍存活；3. services 只存指针，entries 列表最后随 st 一起释放。
    // cfg 为编译期常量（无堆分配），无需释放。
    server.deinit();
    rt.deinit();
    services.deinit();
    allocator.destroy(audit_middleware_inst);
    allocator.destroy(framework_log_mw);
    framework_logger.deinit();
    if (st.spa.html.len > 0) allocator.free(st.spa.html);
    st.session.deinit();
    st.login_guard.deinit();
    allocator.destroy(st);
    database.close();
    allocator.destroy(database);
}
