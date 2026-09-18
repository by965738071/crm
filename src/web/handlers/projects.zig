//! 专业（考试项目）handler。
//!   公开：GET /api/projects            启用中的专业列表（供前台频道切换）
//!   管理端（/api/admin，AuthRequired{admin_only}）：
//!     GET    /projects        全部专业（含停用）
//!     POST   /projects        新建 {code,name,logo?,description?,subject_label?,sort?}（自动建根分类）
//!     PUT    /projects/:id    修改（改名同步根分类）
//!     DELETE /projects/:id    删除（树内有科目分类或内容则 409）
//! 专业 = 一棵分类子树；内容按 category_id 归属专业，内容接口以 category_id=专业根 + sub=1 过滤。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const project_repo = @import("../../db/project_repo.zig");
const respond = @import("../respond.zig");
const common = @import("common.zig");

fn validCode(s: []const u8) bool {
    if (s.len < 2 or s.len > 32) return false;
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or (c == '-' and i > 0);
        if (!ok) return false;
    }
    return true;
}

const ProjectBody = struct {
    code: []const u8 = "",
    name: []const u8 = "",
    logo: []const u8 = "",
    description: []const u8 = "",
    subject_label: []const u8 = "科目",
    sort: i64 = 0,
    status: []const u8 = "active",
};

/// 校验公共字段；失败时已写 400 并返回 false
fn validate(ctx: *framework.Context, body: *const ProjectBody, require_status: bool) !bool {
    if (!validCode(body.code)) {
        try ctx.failWith(framework.AppError.badRequest("专业代码需为 2-32 位小写字母/数字，可含中划线且不能开头"));
        return false;
    }
    const name = std.mem.trim(u8, body.name, " \t\r\n");
    if (name.len == 0 or name.len > 64) {
        try ctx.failWith(framework.AppError.badRequest("专业名称需为 1-64 字符"));
        return false;
    }
    if (body.subject_label.len == 0 or body.subject_label.len > 16) {
        try ctx.failWith(framework.AppError.badRequest("科目别称需为 1-16 字符（如：科目/章节/专业实务）"));
        return false;
    }
    if (body.logo.len > 512 or body.description.len > 2000) {
        try ctx.failWith(framework.AppError.badRequest("Logo/简介过长"));
        return false;
    }
    if (require_status and !project_repo.validStatus(body.status)) {
        try ctx.failWith(framework.AppError.badRequest("状态仅支持 active/disabled"));
        return false;
    }
    return true;
}

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const items = try project_repo.findAll(st.db, ctx.arena, true);
    try respond.ok(res, items);
}

// ---------------------------------------------------------------- 管理端

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const items = try project_repo.findAll(st.db, ctx.arena, false);
    try respond.ok(res, items);
}

pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var body = common.readJson(ProjectBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    body.name = std.mem.trim(u8, body.name, " \t\r\n");
    if (!try validate(ctx, &body, false)) return;
    if (try project_repo.codeTaken(st.db, body.code, 0)) {
        return ctx.failWith(framework.AppError.conflict("专业代码已存在"));
    }

    const id = try project_repo.create(st.db, .{
        .code = body.code,
        .name = body.name,
        .logo = body.logo,
        .description = body.description,
        .subject_label = body.subject_label,
        .sort = body.sort,
        .now = common.nowSec(ctx),
    });
    const p = (try project_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, p);
}

pub fn adminUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    var body = common.readJson(ProjectBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    body.name = std.mem.trim(u8, body.name, " \t\r\n");
    if (!try validate(ctx, &body, true)) return;
    if ((try project_repo.getById(st.db, ctx.arena, id)) == null) {
        return ctx.failWith(framework.AppError.notFound("专业不存在"));
    }
    if (try project_repo.codeTaken(st.db, body.code, id)) {
        return ctx.failWith(framework.AppError.conflict("专业代码已存在"));
    }

    project_repo.update(st.db, .{
        .id = id,
        .code = body.code,
        .name = body.name,
        .logo = body.logo,
        .description = body.description,
        .subject_label = body.subject_label,
        .sort = body.sort,
        .status = body.status,
        .now = common.nowSec(ctx),
    }) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("专业不存在")),
        else => return err,
    };
    const p = (try project_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, p);
}

pub fn adminDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const p = (try project_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("专业不存在"));

    if ((try project_repo.rootChildCount(st.db, p.root_category_id)) > 0) {
        return ctx.failWith(framework.AppError.conflict("该专业下还有科目分类，请先删除科目"));
    }
    if (try project_repo.subtreeHasContent(st.db, p.root_category_id)) {
        return ctx.failWith(framework.AppError.conflict("该专业下还有课程/资料/题目/试卷，请先清理"));
    }

    project_repo.deleteSoft(st.db, id, common.nowSec(ctx)) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("专业不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .status = "ok" });
}
