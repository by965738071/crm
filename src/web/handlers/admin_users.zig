//! 管理端用户管理（挂在 /api/admin 组，AuthRequired{admin_only} 已保证角色）。
//!   GET  /users                    列表（分页 + keyword + role 过滤）
//!   GET  /users/:id                详情
//!   PUT  /users/:id/status         启用/禁用 {status: active|disabled}
//!   PUT  /users/:id/role           改角色 {role}，仅超管
//!   POST /users/:id/reset-password 重置密码 {password}
//!
//! 业务护栏（角色门槛之上的自我保护规则）：
//!   - 不能禁用自己 / 改自己的角色 / 给自己重置密码（走 /auth/password）
//!   - 改角色仅超管；重置“管理员”的密码仅超管
//!
//! 控制流约定：void handler 里失败统一 `try ctx.failWith(...); return;`；
//! 需要返回值的辅助函数用 out-param + bool（false = 已响应错误）。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const auth = @import("../../svc/auth.zig");
const user_repo = @import("../../db/user_repo.zig");
const respond = @import("../respond.zig");
const auth_handlers = @import("auth.zig");

fn nowSec(ctx: *framework.Context) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_s));
}

fn parseId(ctx: *framework.Context, out: *i64) !bool {
    const raw = ctx.param("id") orelse {
        try ctx.failWith(framework.AppError.badRequest("缺少用户 id"));
        return false;
    };
    out.* = std.fmt.parseInt(i64, raw, 10) catch {
        try ctx.failWith(framework.AppError.badRequest("用户 id 无效"));
        return false;
    };
    return true;
}

/// 取 :id 目标用户（不存在 → 已响应 404，返回 false）
fn mustGetTarget(ctx: *framework.Context, st: *state.State, id: i64, out: *user_repo.User) !bool {
    out.* = (try user_repo.getById(st.db, ctx.arena, id)) orelse {
        try ctx.failWith(framework.AppError.notFound("用户不存在"));
        return false;
    };
    return true;
}

fn validRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "student") or
        std.mem.eql(u8, role, "admin") or
        std.mem.eql(u8, role, "superadmin");
}

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var page: i64 = 1;
    if (ctx.query("page")) |q| page = std.fmt.parseInt(i64, q, 10) catch 1;
    var size: i64 = 20;
    if (ctx.query("size")) |q| size = std.fmt.parseInt(i64, q, 10) catch 20;
    size = @max(1, @min(100, size));
    page = @max(1, page);

    const keyword = ctx.queryDecoded("keyword") catch null orelse "";
    const role = ctx.query("role") orelse "";
    if (role.len > 0 and !validRole(role)) {
        return ctx.failWith(framework.AppError.badRequest("role 仅支持 student/admin/superadmin"));
    }

    const r = try user_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .keyword = keyword,
        .role = role,
    });
    try respond.ok(res, .{
        .items = r.items.items,
        .total = r.total,
        .page = page,
        .size = size,
    });
}

pub fn get(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try parseId(ctx, &id)) return;
    var target: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &target)) return;
    try respond.ok(res, auth_handlers.view(target));
}

const StatusBody = struct { status: []const u8 = "" };

pub fn putStatus(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try parseId(ctx, &id)) return;
    if (id == cu.id) return ctx.failWith(framework.AppError.badRequest("不能禁用自己的账号"));

    const body = auth_handlers.readJson(StatusBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!std.mem.eql(u8, body.status, "active") and !std.mem.eql(u8, body.status, "disabled")) {
        return ctx.failWith(framework.AppError.badRequest("status 仅支持 active/disabled"));
    }

    var target: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &target)) return;
    if (auth.isAdminRole(target.role) and !std.mem.eql(u8, cu.role, "superadmin")) {
        return ctx.failWith(framework.AppError.forbidden("仅超级管理员可操作管理员账号"));
    }

    try user_repo.updateStatus(st.db, id, body.status, nowSec(ctx));
    var fresh: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &fresh)) return;
    try respond.ok(res, auth_handlers.view(fresh));
}

const RoleBody = struct { role: []const u8 = "" };

pub fn putRole(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    if (!std.mem.eql(u8, cu.role, "superadmin")) {
        return ctx.failWith(framework.AppError.forbidden("仅超级管理员可修改角色"));
    }
    var id: i64 = 0;
    if (!try parseId(ctx, &id)) return;
    if (id == cu.id) return ctx.failWith(framework.AppError.badRequest("不能修改自己的角色"));

    const body = auth_handlers.readJson(RoleBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!validRole(body.role)) {
        return ctx.failWith(framework.AppError.badRequest("role 仅支持 student/admin/superadmin"));
    }

    var target: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &target)) return;
    try user_repo.updateRole(st.db, id, body.role, nowSec(ctx));
    var fresh: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &fresh)) return;
    try respond.ok(res, auth_handlers.view(fresh));
}

const ResetBody = struct { password: []const u8 = "" };

pub fn postResetPassword(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try parseId(ctx, &id)) return;
    if (id == cu.id) return ctx.failWith(framework.AppError.badRequest("修改自己的密码请走 /api/auth/password"));

    const body = auth_handlers.readJson(ResetBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.password.len < auth.password_min_len or body.password.len > auth.password_max_len) {
        return ctx.failWith(framework.AppError.badRequest("密码长度需为 8-128 位"));
    }

    var target: user_repo.User = undefined;
    if (!try mustGetTarget(ctx, st, id, &target)) return;
    if (auth.isAdminRole(target.role) and !std.mem.eql(u8, cu.role, "superadmin")) {
        return ctx.failWith(framework.AppError.forbidden("仅超级管理员可重置管理员密码"));
    }

    const hash = try auth.hashPassword(ctx.arena, ctx.io, body.password);
    try user_repo.updatePassword(st.db, id, hash, nowSec(ctx));
    try respond.ok(res, .{ .status = "ok" });
}
