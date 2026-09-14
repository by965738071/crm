//! 会话鉴权中间件。挂在路由组上（组级 use），组内路由默认需要登录。
//!
//! 与框架 http_security.AuthMiddleware（Bearer/Basic/APIKey）互补：
//! 那是无状态凭证校验，这里是 cookie session 方案（管理后台/学员端形态）。
//!
//! 设计要点：
//! - 只读现有 cookie（不 getOrCreate，避免匿名流量刷爆 session 表）；
//! - 校验通过后把 CurrentUser 存入 ctx.user_data，handler 直接取，不再解 cookie；
//! - 密码学级别的“账号是否仍有效”不在这里查库（每请求一次全表点查），
//!   禁用实时性由 /me 与敏感 handler 自查 + session 过期兜底（见 plan.md 11 节）。

const std = @import("std");
const framework = @import("http_framework");
const auth = @import("../svc/auth.zig");

pub const AuthRequired = struct {
    /// 指向 State.session。State 构造后才能回填，故可空并在使用处判空。
    session: ?*framework.SessionManager = null,
    /// true = 组内额外要求 admin/superadmin 角色
    admin_only: bool = false,

    pub fn process(self: *AuthRequired, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const sm = self.session orelse return ctx.failWith(framework.AppError.internal("session unavailable"));

        const sid = ctx.request.getCookie(sm.config.cookie_name) orelse
            return ctx.failWith(framework.AppError.unauthorized("请先登录"));

        // getValue 内部处理过期与不存在；值 dupe 到请求 arena
        const uid_raw = (try sm.getValue(sid, "user_id", ctx.arena)) orelse
            return ctx.failWith(framework.AppError.unauthorized("登录已过期，请重新登录"));
        const id = std.fmt.parseInt(i64, uid_raw, 10) catch
            return ctx.failWith(framework.AppError.unauthorized("会话数据异常"));
        const role = (try sm.getValue(sid, "role", ctx.arena)) orelse "";

        if (self.admin_only and !auth.isAdminRole(role)) {
            return ctx.failWith(framework.AppError.forbidden("需要管理员权限"));
        }

        const cu = try ctx.arena.create(auth.CurrentUser);
        cu.* = .{ .id = id, .role = role };
        try ctx.setUserData(auth.CurrentUser, cu);

        try next.call(ctx, res);
    }
};

/// handler 侧取当前用户。仅可用于挂了 AuthRequired 的组内路由；
/// 拿不到说明路由/中间件装配错误，报 internal 而非 unauthorized（前端不应当跳登录页）。
pub fn currentUser(ctx: *framework.Context) !auth.CurrentUser {
    const p = ctx.getUserData(auth.CurrentUser) orelse {
        try ctx.failWith(framework.AppError.internal("auth middleware not installed on this route"));
        unreachable; // failWith 永远以 error 返回
    };
    return p.*;
}

/// 可选登录态：解析 cookie 会话，未登录/过期返回 null（用于公开路由的
/// “登录后可见更多”语义，如课时锁定、资料下载）。不抛未登录错误。
pub fn currentUserOptional(ctx: *framework.Context, sm: *framework.SessionManager) !?auth.CurrentUser {
    const sid = ctx.request.getCookie(sm.config.cookie_name) orelse return null;
    const uid_raw = (try sm.getValue(sid, "user_id", ctx.arena)) orelse return null;
    const id = std.fmt.parseInt(i64, uid_raw, 10) catch return null;
    const role = (try sm.getValue(sid, "role", ctx.arena)) orelse "";
    return .{ .id = id, .role = role };
}
