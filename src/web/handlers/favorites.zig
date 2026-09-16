//! 收藏 handler（M-G G2，第 7 期）：课程/资料的收藏增删查。
//!
//! add 幂等（INSERT OR IGNORE），目标存在性预检后置 404；remove 未收藏 → 404。
//! 列表 LEFT JOIN 目标表，已软删目标隐身（repo 层负责）。
//! 题目收藏在练习模块（/practice/favorites），本接口只管 course/resource。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const favorite_repo = @import("../../db/favorite_repo.zig");
const course_repo = @import("../../db/course_repo.zig");
const resource_repo = @import("../../db/resource_repo.zig");

const FavBody = struct {
    /// course | resource（字段名对齐 §7：target_type/target_id）
    target_type: []const u8 = "",
    target_id: i64 = 0,
};

/// type 合法 + 目标未删存在；非法 400，不存在 404（failWith 以 error 结束）
fn mustTarget(ctx: *framework.Context, st: *state.State, t: []const u8, id: i64) !void {
    if (!favorite_repo.validTargetType(t)) {
        try ctx.failWith(framework.AppError.badRequest("target_type 仅支持 course/resource"));
        unreachable;
    }
    if (id <= 0) {
        try ctx.failWith(framework.AppError.badRequest("target_id 无效"));
        unreachable;
    }
    if (std.mem.eql(u8, t, "course")) {
        _ = (try course_repo.getById(st.db, ctx.arena, id)) orelse {
            try ctx.failWith(framework.AppError.notFound("课程不存在"));
            unreachable;
        };
    } else {
        _ = (try resource_repo.getById(st.db, ctx.arena, id)) orelse {
            try ctx.failWith(framework.AppError.notFound("资料不存在"));
            unreachable;
        };
    }
}

fn readFavBody(ctx: *framework.Context) !FavBody {
    return common.readJson(FavBody, ctx) catch {
        try ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
        unreachable;
    };
}

pub fn add(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = try readFavBody(ctx);
    try mustTarget(ctx, st, body.target_type, body.target_id);
    try favorite_repo.add(st.db, cu.id, body.target_type, body.target_id, common.nowSec(ctx));
    try respond.ok(res, .{ .favorited = true });
}

pub fn remove(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    // 框架协议层拒绝 DELETE 携带 body（std requestHasBody 口径，见 http-framework-issues.md Issue 5），
    // 故取消收藏走 query 参数：DELETE /api/favorites?target_type=course&target_id=1
    const t = ctx.query("target_type") orelse "";
    if (!favorite_repo.validTargetType(t))
        return ctx.failWith(framework.AppError.badRequest("target_type 仅支持 course/resource"));
    const id = common.parseQueryInt(ctx, "target_id", 0, 1 << 40, 1);
    if (id <= 0) return ctx.failWith(framework.AppError.badRequest("target_id 必填且为正整数"));

    favorite_repo.remove(st.db, cu.id, t, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("未收藏该对象")),
        else => return err,
    };
    try respond.ok(res, .{ .removed = true });
}

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const t = ctx.query("target_type") orelse "";
    if (t.len != 0 and !favorite_repo.validTargetType(t))
        return ctx.failWith(framework.AppError.badRequest("target_type 仅支持 course/resource"));

    const r = try favorite_repo.list(st.db, ctx.arena, cu.id, t, page, size);
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}
