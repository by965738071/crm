//! 进程级应用状态：装配产物的所有权容器。
//!
//! handler 不通过全局变量访问依赖：启动时把 *State 注册进 framework.Services
//! 并 seal()，Server 注入到每个 Context，handler 用 ctx.service(state.State) 取回。
//! State 本身只负责「谁持有这些对象、退出时按什么顺序释放」。
//! 中间件/单例 handler 以指针被框架持有，必须放在稳定的堆地址上。

const std = @import("std");
const framework = @import("http_framework");
const db = @import("../db/db.zig");
const auth_mw = @import("auth_middleware.zig");
const identity = @import("../svc/identity.zig");
const respond = @import("../web/respond.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    /// 服务器配置的只读快照（framework 分层 Config，编译期常量，无堆分配）
    config: framework.Config = .{},
    db: *db.Db,
    started_at_ns: i128,

    /// cookie session（内存存储，重启即失效；生产如需持久化见 plan.md 第 11 节）
    session: framework.SessionManager,
    /// 登录失败计数（防暴力）
    login_guard: identity.LoginGuard,

    /// 鉴权中间件实例：session 指针在 State 构造后回填（自引用不能写进字面量）
    auth_user: auth_mw.AuthRequired = .{},
    auth_admin: auth_mw.AuthRequired = .{ .admin_only = true },

    static_index: framework.StaticFileServer,
    static_assets: framework.StaticFileServer,
    /// vite 产物 /assets/* 的磁盘回退（mount 必须与路由前缀一致，否则剥不掉前缀永远 404）
    static_vite: framework.StaticFileServer,
    /// 题目图片静态服务（仅暴露 data/uploads/images，随机文件名防猜测）
    image_files: framework.StaticFileServer,
    /// SPA 深链回退（index.html 启动时读入；前端未构建时为空，退回 JSON 404）
    spa: respond.SpaFallback = .{},

    error_renderer: framework.ErrorRenderer = .{},
    request_id: framework.RequestIdMiddleware = .{},
    security: framework.SecurityHeaders,
    cors: framework.CorsMiddleware,
    rate: framework.RateLimiter,
};
