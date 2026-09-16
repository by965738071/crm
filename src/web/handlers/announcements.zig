//! 公告 handler（M-G G1，第 7 期）：公开端只读已发布；管理端 CRUD + 发布/下架。
//!
//! 状态机（draft ↔ published）守卫在 announcement_repo 的 UPDATE WHERE status 条件里；
//! handler 预检只为区分「不存在(404)」与「状态不满足(400)」的友好文案。
//! 公开端访问草稿按 404 处理，不暴露「存在但未发布」的信息。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const announcement_repo = @import("../../db/announcement_repo.zig");

// ---------------------------------------------------------------- 公开端

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 10, 50, 1);
    const keyword = ctx.query("keyword") orelse "";

    const r = try announcement_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .keyword = keyword,
        .only_published = true, // status 参数对公开端无效，强制已发布
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn detail(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const ann = (try announcement_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("公告不存在"));
    if (!std.mem.eql(u8, ann.status, "published"))
        return ctx.failWith(framework.AppError.notFound("公告不存在"));
    try respond.ok(res, ann);
}

// ---------------------------------------------------------------- 管理端

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const keyword = ctx.query("keyword") orelse "";
    const status = ctx.query("status") orelse "";
    if (status.len != 0 and !announcement_repo.validStatus(status)) {
        return ctx.failWith(framework.AppError.badRequest("status 仅支持 draft/published"));
    }

    const r = try announcement_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .status = status,
        .keyword = keyword,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn adminGet(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const ann = try mustAnnouncement(ctx, st, id);
    try respond.ok(res, ann);
}

const CreateBody = struct {
    title: []const u8 = "",
    content: []const u8 = "",
    /// 允许建草稿（默认）或直接发布
    status: []const u8 = "draft",
};

pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(CreateBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.title.len == 0 or body.title.len > announcement_repo.max_title_len)
        return ctx.failWith(framework.AppError.badRequest("标题必填，最长 128 字符"));
    if (body.content.len > announcement_repo.max_content_len)
        return ctx.failWith(framework.AppError.badRequest("内容最长 20000 字符"));
    if (!announcement_repo.validStatus(body.status))
        return ctx.failWith(framework.AppError.badRequest("status 仅支持 draft/published"));

    const ann = try announcement_repo.create(st.db, ctx.arena, body.title, body.content, body.status, cu.id, common.nowSec(ctx));
    try respond.ok(res, ann);
}

const UpdateBody = struct {
    title: []const u8 = "",
    content: []const u8 = "",
};

/// 只改文案；发布状态走 publish/unpublish（见 repo 注释）
pub fn adminUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const body = common.readJson(UpdateBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.title.len == 0 or body.title.len > announcement_repo.max_title_len)
        return ctx.failWith(framework.AppError.badRequest("标题必填，最长 128 字符"));
    if (body.content.len > announcement_repo.max_content_len)
        return ctx.failWith(framework.AppError.badRequest("内容最长 20000 字符"));

    const updated = announcement_repo.update(st.db, ctx.arena, id, body.title, body.content) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("公告不存在")),
        else => return err,
    };
    try respond.ok(res, updated);
}

pub fn adminPublish(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const ann = try mustAnnouncement(ctx, st, id);
    if (std.mem.eql(u8, ann.status, "published"))
        return ctx.failWith(framework.AppError.badRequest("该公告已发布"));

    const updated = announcement_repo.publish(st.db, ctx.arena, ann.id, common.nowSec(ctx)) catch |err| switch (err) {
        error.InvalidState => return ctx.failWith(framework.AppError.badRequest("状态已变化，请刷新后重试")),
        error.NotFound => return ctx.failWith(framework.AppError.notFound("公告不存在")),
        else => return err,
    };
    try respond.ok(res, updated);
}

pub fn adminUnpublish(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const ann = try mustAnnouncement(ctx, st, id);
    if (!std.mem.eql(u8, ann.status, "published"))
        return ctx.failWith(framework.AppError.badRequest("该公告尚未发布"));

    const updated = announcement_repo.unpublish(st.db, ctx.arena, ann.id) catch |err| switch (err) {
        error.InvalidState => return ctx.failWith(framework.AppError.badRequest("状态已变化，请刷新后重试")),
        error.NotFound => return ctx.failWith(framework.AppError.notFound("公告不存在")),
        else => return err,
    };
    try respond.ok(res, updated);
}

pub fn adminDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    announcement_repo.deleteSoft(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("公告不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .deleted = true });
}

/// 未删公告；不存在即 404（failWith 以 error 返回，unreachable 兜底）
fn mustAnnouncement(ctx: *framework.Context, st: *state.State, id: i64) !announcement_repo.Announcement {
    const ann = (try announcement_repo.getById(st.db, ctx.arena, id)) orelse {
        try ctx.failWith(framework.AppError.notFound("公告不存在"));
        unreachable;
    };
    return ann;
}
