//! 认证与个人中心 handler。
//!   公开：POST /api/auth/register | /api/auth/login | /api/auth/logout
//!   登录态（AuthRequired 组）：GET /api/auth/me，PUT /api/auth/profile | /api/auth/password

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const identity = @import("../../svc/identity.zig");
const user_repo = @import("../../db/user_repo.zig");
const respond = @import("../respond.zig");

/// 解析 JSON 请求体（上限 1MB，忽略未知字段）。调用方 catch 成 400。
pub fn readJson(comptime T: type, ctx: *framework.Context) !T {
    const body = try ctx.readBody(ctx.arena, 1 << 20);
    const parsed = std.json.parseFromSlice(T, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch
        return error.BadJson;
    return parsed.value;
}

fn nowSec(ctx: *framework.Context) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_s));
}

/// 请求级分配器：handler 内所有 dupe/ArrayList 都走 arena，随请求回收
fn arenaOf(ctx: *framework.Context) std.mem.Allocator {
    return ctx.arena;
}

// ---------------------------------------------------------------- 校验

fn isEmail(s: []const u8) bool {
    if (s.len == 0 or s.len > 254) return false;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    if (std.mem.indexOfScalar(u8, s, '\"') != null) return false;
    var prev: u8 = undefined;
    var prev_prev: u8 = undefined;
    for (s) |c| {
        if (c <= ' ' or c == 127) return false;
        if (c == '.') {
            if (prev == '.' or prev_prev == '.') return false;
            if (prev == '@') return false;
            if (at > 0 and s[at - 1] == '.') return false;
        }
        prev_prev = prev;
        prev = c;
    }
    const domain = s[at + 1 ..];
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return false;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    return true;
}

fn isUsername(s: []const u8) bool {
    if (s.len < 3 or s.len > 32) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn passwordOk(s: []const u8) bool {
    return s.len >= identity.password_min_len and s.len <= identity.password_max_len;
}

/// user → JSON 输出视图（永远不含 password_hash）
pub const UserView = struct {
    id: i64,
    email: []const u8,
    username: []const u8,
    nickname: []const u8,
    avatar: []const u8,
    role: []const u8,
    status: []const u8,
    created_at: i64,
};

pub fn view(u: user_repo.User) UserView {
    return .{
        .id = u.id,
        .email = u.email,
        .username = u.username,
        .nickname = u.nickname,
        .avatar = u.avatar,
        .role = u.role,
        .status = u.status,
        .created_at = u.created_at,
    };
}

// ---------------------------------------------------------------- 公开接口

const RegisterBody = struct {
    email: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    nickname: []const u8 = "",
};

pub fn register(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const body = readJson(RegisterBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));

    if (!isEmail(body.email)) return ctx.failWith(framework.AppError.badRequest("邮箱格式不正确"));
    if (!isUsername(body.username)) return ctx.failWith(framework.AppError.badRequest("用户名需为 3-32 位字母、数字或 _-."));
    if (!passwordOk(body.password)) return ctx.failWith(framework.AppError.badRequest("密码长度需为 8-128 位"));
    if (body.nickname.len > 64) return ctx.failWith(framework.AppError.badRequest("昵称最长 64 字符"));

    const hash = try identity.hashPassword(arenaOf(ctx), ctx.io, body.password);
    const nickname = if (body.nickname.len > 0) body.nickname else body.username;

    const id = user_repo.create(st.db, body.email, body.username, nickname, hash, "student", nowSec(ctx)) catch |err| switch (err) {
        error.UserExists => return ctx.failWith(framework.AppError.conflict("邮箱或用户名已被注册")),
        else => return err,
    };

    const user = (try user_repo.getById(st.db, arenaOf(ctx), id)) orelse
        return ctx.failWith(framework.AppError.internal("创建后回读失败"));
    try respond.ok(res, view(user));
}

const LoginBody = struct {
    account: []const u8 = "",
    password: []const u8 = "",
};

pub fn login(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const body = readJson(LoginBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.account.len == 0 or body.password.len == 0) {
        return ctx.failWith(framework.AppError.badRequest("账号和密码不能为空"));
    }

    const now = nowSec(ctx);
    if (!st.login_guard.allow(now, body.account)) {
        return ctx.failWith(framework.AppError.tooManyRequests("失败次数过多，请 15 分钟后再试"));
    }

    const found = try user_repo.getByAccount(st.db, arenaOf(ctx), body.account);
    const wrong = framework.AppError.unauthorized("账号或密码错误");
    const hit = found orelse {
        try st.login_guard.recordFailure(now, body.account);
        return ctx.failWith(wrong);
    };
    if (!identity.verifyPassword(ctx.io, hit.password_hash, body.password)) {
        try st.login_guard.recordFailure(now, body.account);
        return ctx.failWith(wrong);
    }
    if (!std.mem.eql(u8, hit.user.status, "active")) {
        return ctx.failWith(framework.AppError.forbidden("账号已被禁用，请联系管理员"));
    }

    // 防会话固定：登录成功必须轮换 session（销毁请求带来的旧 ID 再签新 ID）
    const sid = try st.session.rotate(ctx, res);
    st.login_guard.reset(body.account);

    const uid_buf = try ctx.arena.print("{d}", .{hit.user.id});
    try st.session.setData(sid, "user_id", uid_buf);
    try st.session.setData(sid, "role", hit.user.role);

    try respond.ok(res, view(hit.user));
}

pub fn logout(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    // 无 cookie / 会话已过期都是 no-op，登出天然幂等
    st.session.destroyFromRequest(ctx);
    try respond.ok(res, .{ .status = "ok" });
}

// ---------------------------------------------------------------- 登录态接口

pub fn me(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    // 查库拿最新资料；同时兜底“已被删除/禁用但 session 还在”的情况
    const user = (try user_repo.getById(st.db, arenaOf(ctx), cu.id)) orelse
        return ctx.failWith(framework.AppError.unauthorized("登录已失效，请重新登录"));
    if (!std.mem.eql(u8, user.status, "active")) {
        return ctx.failWith(framework.AppError.forbidden("账号已被禁用"));
    }
    try respond.ok(res, view(user));
}

const ProfileBody = struct {
    nickname: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

pub fn updateProfile(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = readJson(ProfileBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.nickname) |n| {
        if (n.len > 64) return ctx.failWith(framework.AppError.badRequest("昵称最长 64 字符"));
    }
    if (body.avatar) |av| {
        if (av.len > 512) return ctx.failWith(framework.AppError.badRequest("头像地址最长 512 字符"));
    }

    try user_repo.updateProfile(st.db, cu.id, body.nickname, body.avatar, nowSec(ctx));
    const user = (try user_repo.getById(st.db, arenaOf(ctx), cu.id)) orelse
        return ctx.failWith(framework.AppError.unauthorized("登录已失效，请重新登录"));
    try respond.ok(res, view(user));
}

const PasswordBody = struct {
    old_password: []const u8 = "",
    new_password: []const u8 = "",
};

pub fn changePassword(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = readJson(PasswordBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!passwordOk(body.new_password)) {
        return ctx.failWith(framework.AppError.badRequest("新密码长度需为 8-128 位"));
    }

    const old_hash = (try user_repo.getPasswordHashById(st.db, arenaOf(ctx), cu.id)) orelse
        return ctx.failWith(framework.AppError.unauthorized("登录已失效，请重新登录"));
    if (!identity.verifyPassword(ctx.io, old_hash, body.old_password)) {
        return ctx.failWith(framework.AppError.unauthorized("原密码不正确"));
    }

    const hash = try identity.hashPassword(arenaOf(ctx), ctx.io, body.new_password);
    try user_repo.updatePassword(st.db, cu.id, hash, nowSec(ctx));

    // 改密后轮换 session（框架要求：角色/凭证变化后旧会话必须作废）
    const sid = try st.session.rotate(ctx, res);
    const uid_buf = try ctx.arena.print("{d}", .{cu.id});
    try st.session.setData(sid, "user_id", uid_buf);
    try st.session.setData(sid, "role", cu.role); // 改密不改角色，沿用会话内角色

    try respond.ok(res, .{ .status = "ok" });
}
