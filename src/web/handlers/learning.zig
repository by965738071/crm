//! 学习域 handler（M-C，第 3 期）：报名 / 我的课程 / 进度 / 学习时长。
//!
//! 全部挂在学员登录态组（AuthRequired）。课时访问控制统一走
//! learning_repo.canAccessLesson：免费试看课时人人可学，付费课时需已报名（paid/free）。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const course_repo = @import("../../db/course_repo.zig");
const learning_repo = @import("../../db/learning_repo.zig");

// ---------------------------------------------------------------- 报名

pub fn enroll(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const course = (try course_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("课程不存在"));
    if (!std.mem.eql(u8, course.status, "published"))
        return ctx.failWith(framework.AppError.notFound("课程未上架"));

    // 幂等：已报名直接返回当前状态，不报错（前端按 pay_status 决定下一步）
    if (try learning_repo.getEnrollment(st.db, ctx.arena, cu.id, id)) |e| {
        return try respond.ok(res, .{ .status = "already_enrolled", .pay_status = e.pay_status });
    }

    const outcome = try learning_repo.enroll(st.db, ctx.arena, cu.id, course, common.nowSec(ctx));
    switch (outcome) {
        .enrolled => try respond.ok(res, .{ .status = "enrolled", .pay_status = "free" }),
        .pending_payment => |p| try respond.ok(res, .{
            .status = "pending_payment",
            .pay_status = "unpaid",
            .order_no = p.order_no,
            .amount = p.amount,
        }),
    }
}

// ---------------------------------------------------------------- 我的课程

pub fn myEnrollments(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const r = try learning_repo.listByUser(st.db, ctx.arena, cu.id, page, size);
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn myProgress(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const course_id = common.parseQueryInt(ctx, "course_id", 0, 1 << 40, 0);
    if (course_id <= 0) return ctx.failWith(framework.AppError.badRequest("缺少 course_id"));
    const rows = try learning_repo.progressByCourse(st.db, ctx.arena, cu.id, course_id);
    try respond.ok(res, rows);
}

// ---------------------------------------------------------------- 进度 / 心跳

const ProgressBody = struct {
    lesson_id: i64 = 0,
    status: []const u8 = "",
    position: i64 = 0,
};

pub fn reportProgress(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(ProgressBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!learning_repo.validProgressStatus(body.status)) {
        return ctx.failWith(framework.AppError.badRequest("status 仅支持 in_progress/completed"));
    }
    var lesson: course_repo.Lesson = undefined;
    if (!try mustAccessibleLesson(ctx, st, cu.id, body.lesson_id, &lesson)) return;

    const position = @max(@as(i64, 0), body.position);
    const p = try learning_repo.upsertProgress(
        st.db,
        ctx.arena,
        cu.id,
        lesson.id,
        lesson.course_id,
        body.status,
        position,
        common.nowSec(ctx),
    );
    try respond.ok(res, p);
}

const HeartbeatBody = struct {
    lesson_id: i64 = 0,
    seconds: i64 = 0,
};

pub fn heartbeat(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(HeartbeatBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    // 上限 600s：心跳节奏由前端定时控制，超界视为客户端异常/刷量，拒绝而非截断
    if (body.seconds < 1 or body.seconds > 600) {
        return ctx.failWith(framework.AppError.badRequest("seconds 需在 1-600 之间"));
    }
    var lesson: course_repo.Lesson = undefined;
    if (!try mustAccessibleLesson(ctx, st, cu.id, body.lesson_id, &lesson)) return;

    const now = common.nowSec(ctx);
    const date = try learning_repo.utcDate(ctx.arena, now);
    try learning_repo.logStudy(st.db, cu.id, lesson.course_id, lesson.id, body.seconds, date, now);
    try respond.ok(res, .{ .logged = body.seconds, .date = date });
}

/// 取课时并校验访问权：id 非法 400；不存在 404；付费课时未报名 403。
/// 返回 false = 已响应错误（约定同 admin_users.mustGetTarget）。
fn mustAccessibleLesson(
    ctx: *framework.Context,
    st: *state.State,
    user_id: i64,
    lesson_id: i64,
    out: *course_repo.Lesson,
) !bool {
    if (lesson_id <= 0) {
        try ctx.failWith(framework.AppError.badRequest("缺少 lesson_id"));
        return false;
    }
    out.* = (try course_repo.lessonGetById(st.db, ctx.arena, lesson_id)) orelse {
        try ctx.failWith(framework.AppError.notFound("课时不存在"));
        return false;
    };
    if (!try learning_repo.canAccessLesson(st.db, user_id, out.*)) {
        try ctx.failWith(framework.AppError.forbidden("请先报名课程再学习该课时"));
        return false;
    }
    return true;
}
