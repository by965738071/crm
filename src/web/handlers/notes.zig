//! 笔记 handler（M-G G3，第 7 期）：按课程/课时记笔记，仅本人可见可改。
//!
//! 越权 = 404（repo SQL 带 user_id 守卫，不暴露「存在但不可改」）。
//! course_id 必填且存在；lesson_id > 0 时必须归属该课程。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const note_repo = @import("../../db/note_repo.zig");
const course_repo = @import("../../db/course_repo.zig");

const CreateBody = struct {
    course_id: i64 = 0,
    /// 0 = 课程级笔记
    lesson_id: i64 = 0,
    content: []const u8 = "",
};

fn checkContent(ctx: *framework.Context, content: []const u8) !void {
    if (content.len == 0) {
        try ctx.failWith(framework.AppError.badRequest("笔记内容不能为空"));
        unreachable;
    }
    if (content.len > note_repo.max_content_len) {
        try ctx.failWith(framework.AppError.badRequest("笔记内容最长 5000 字符"));
        unreachable;
    }
}

pub fn create(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(CreateBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.course_id <= 0 or body.lesson_id < 0)
        return ctx.failWith(framework.AppError.badRequest("course_id 必填且为正整数"));
    try checkContent(ctx, body.content);

    _ = (try course_repo.getById(st.db, ctx.arena, body.course_id)) orelse
        return ctx.failWith(framework.AppError.notFound("课程不存在"));
    if (body.lesson_id > 0) {
        const lesson = (try course_repo.lessonGetById(st.db, ctx.arena, body.lesson_id)) orelse
            return ctx.failWith(framework.AppError.notFound("课时不存在"));
        if (lesson.course_id != body.course_id)
            return ctx.failWith(framework.AppError.badRequest("课时不属于该课程"));
    }

    const note = try note_repo.create(st.db, ctx.arena, cu.id, body.course_id, body.lesson_id, body.content, common.nowSec(ctx));
    try respond.ok(res, note);
}

const UpdateBody = struct {
    content: []const u8 = "",
};

pub fn update(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const body = common.readJson(UpdateBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    try checkContent(ctx, body.content);

    const note = note_repo.update(st.db, ctx.arena, id, cu.id, body.content, common.nowSec(ctx)) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("笔记不存在")),
        else => return err,
    };
    try respond.ok(res, note);
}

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const course_id = common.parseQueryInt(ctx, "course_id", 0, 1 << 40, 0);
    const lesson_id = common.parseQueryInt(ctx, "lesson_id", 0, 1 << 40, 0);

    const r = try note_repo.list(st.db, ctx.arena, cu.id, course_id, lesson_id, page, size);
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn delete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    note_repo.deleteSoft(st.db, id, cu.id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("笔记不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .deleted = true });
}
