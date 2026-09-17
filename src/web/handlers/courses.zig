//! 课程 / 章节 / 课时 handler。
//!   公开：GET /api/courses（仅已上架）、GET /api/courses/:id（详情+章节树，课时锁定规则）
//!   管理端：/api/admin/courses|chapters|lessons 的 POST/PUT/DELETE；GET /api/admin/courses（含草稿）

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const course_repo = @import("../../db/course_repo.zig");
const resource_repo = @import("../../db/resource_repo.zig");
const respond = @import("../respond.zig");
const common = @import("common.zig");

// ---------------------------------------------------------------- 视图

pub const CourseView = struct {
    id: i64,
    category_id: i64,
    title: []const u8,
    cover: []const u8,
    summary: []const u8,
    description: []const u8,
    price: i64,
    is_free: i64,
    status: []const u8,
    sort: i64,
    enroll_count: i64,
    created_at: i64,
    updated_at: i64,
};

fn courseView(c: course_repo.Course) CourseView {
    return .{
        .id = c.id,
        .category_id = c.category_id,
        .title = c.title,
        .cover = c.cover,
        .summary = c.summary,
        .description = c.description,
        .price = c.price,
        .is_free = c.is_free,
        .status = c.status,
        .sort = c.sort,
        .enroll_count = c.enroll_count,
        .created_at = c.created_at,
        .updated_at = c.updated_at,
    };
}

/// 公开课时视图：未解锁的课时 content 隐藏（置空 + locked=true）
pub const LessonView = struct {
    id: i64,
    course_id: i64,
    chapter_id: i64,
    title: []const u8,
    content_type: []const u8,
    resource_id: i64,
    content: []const u8,
    duration: i64,
    is_free: i64,
    sort: i64,
    locked: bool = false,
};

fn lessonView(le: course_repo.Lesson, unlocked: bool) LessonView {
    const show = unlocked or le.is_free == 1;
    return .{
        .id = le.id,
        .course_id = le.course_id,
        .chapter_id = le.chapter_id,
        .title = le.title,
        .content_type = le.content_type,
        .resource_id = le.resource_id,
        .content = if (show) le.content else "",
        .duration = le.duration,
        .is_free = le.is_free,
        .sort = le.sort,
        .locked = !show,
    };
}

pub const ChapterView = struct {
    id: i64,
    course_id: i64,
    title: []const u8,
    sort: i64,
    lessons: []LessonView = &.{},
};

fn chapterView(ch: course_repo.Chapter) ChapterView {
    return .{ .id = ch.id, .course_id = ch.course_id, .title = ch.title, .sort = ch.sort };
}

// ---------------------------------------------------------------- 公开接口

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";
    const include_subtree = common.parseQueryInt(ctx, "sub", 0, 1, 0) == 1;

    const r = try course_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .keyword = keyword,
        .category_id = category_id,
        .only_published = true,
        .include_subtree = include_subtree,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn detail(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const course = (try course_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("课程不存在"));
    // 草稿对外不可见（管理后台用 /api/admin/courses 取全量）
    if (!std.mem.eql(u8, course.status, "published")) {
        return ctx.failWith(framework.AppError.notFound("课程不存在"));
    }

    // 可选登录态：登录用户判断是否已报名（决定课时是否解锁）
    const cu = try authm.currentUserOptional(ctx, &st.session);
    const user_id: i64 = if (cu) |u| u.id else 0;
    const unlocked = try course_repo.isEnrolled(st.db, user_id, id);

    const chs = try course_repo.chaptersByCourse(st.db, ctx.arena, id);
    var chapters: std.ArrayList(ChapterView) = .empty;
    for (chs) |ch| {
        var cv = chapterView(ch);
        const lessons = try course_repo.lessonsByChapter(st.db, ctx.arena, ch.id);
        var lvs: std.ArrayList(LessonView) = .empty;
        for (lessons) |le| {
            try lvs.append(ctx.arena, lessonView(le, unlocked));
        }
        cv.lessons = try lvs.toOwnedSlice(ctx.arena);
        try chapters.append(ctx.arena, cv);
    }

    try respond.ok(res, .{
        .course = courseView(course),
        .chapters = try chapters.toOwnedSlice(ctx.arena),
    });
}

// ---------------------------------------------------------------- 校验

fn validStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "draft") or std.mem.eql(u8, status, "published");
}

fn validLessonType(t: []const u8) bool {
    return std.mem.eql(u8, t, "video") or std.mem.eql(u8, t, "audio") or
        std.mem.eql(u8, t, "pdf") or std.mem.eql(u8, t, "markdown") or std.mem.eql(u8, t, "rich");
}

fn titleOk(name: []const u8) bool {
    const len = std.mem.trim(u8, name, " \t\r\n").len;
    return len > 0 and len <= 200;
}

/// category_id 非 0 时校验存在（未分类=0 允许）
fn categoryExists(ctx: *framework.Context, st: *state.State, category_id: i64) !bool {
    if (category_id == 0) return true;
    const count = (try st.db.scalarInt("SELECT COUNT(*) FROM categories WHERE id = ?1 AND deleted = 0", .{category_id})) orelse 0;
    if (count == 0) {
        try ctx.failWith(framework.AppError.badRequest("分类不存在"));
        return false;
    }
    return true;
}

fn courseMustExist(ctx: *framework.Context, st: *state.State, id: i64) !bool {
    const count = (try st.db.scalarInt("SELECT COUNT(*) FROM courses WHERE id = ?1 AND deleted = 0", .{id})) orelse 0;
    if (count == 0) {
        try ctx.failWith(framework.AppError.badRequest("课程不存在"));
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- 管理端：课程

const CourseBody = struct {
    category_id: i64 = 0,
    title: []const u8 = "",
    cover: []const u8 = "",
    summary: []const u8 = "",
    description: []const u8 = "",
    price: i64 = 0,
    is_free: i64 = 0,
    status: []const u8 = "draft",
    sort: i64 = 0,
};

fn validateCourse(ctx: *framework.Context, st: *state.State, body: *const CourseBody) !bool {
    if (!titleOk(body.title)) {
        try ctx.failWith(framework.AppError.badRequest("课程标题需为 1-200 字符"));
        return false;
    }
    if (body.summary.len > 500) {
        try ctx.failWith(framework.AppError.badRequest("摘要最长 500 字符"));
        return false;
    }
    if (body.cover.len > 512) {
        try ctx.failWith(framework.AppError.badRequest("封面地址最长 512 字符"));
        return false;
    }
    if (body.price < 0 or body.price > 1_000_000_000) {
        try ctx.failWith(framework.AppError.badRequest("价格（分）需在 0-10 亿之间"));
        return false;
    }
    if (body.is_free != 0 and body.is_free != 1) {
        try ctx.failWith(framework.AppError.badRequest("is_free 仅支持 0/1"));
        return false;
    }
    if (!validStatus(body.status)) {
        try ctx.failWith(framework.AppError.badRequest("status 仅支持 draft/published"));
        return false;
    }
    return try categoryExists(ctx, st, body.category_id);
}

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";
    const status = ctx.query("status") orelse "";
    const include_subtree = common.parseQueryInt(ctx, "sub", 0, 1, 0) == 1;

    // 状态过滤单独走一条 SQL：status 为空 = 全部
    var r: course_repo.CourseList = undefined;
    if (status.len > 0 and (std.mem.eql(u8, status, "draft") or std.mem.eql(u8, status, "published"))) {
        // 复用 list 的 only_published=false + 额外 status 条件：手写一个轻量查询
        r = try course_repo.listStatus(st.db, ctx.arena, .{
            .page = page,
            .size = size,
            .keyword = keyword,
            .category_id = category_id,
            .status = status,
            .include_subtree = include_subtree,
        });
    } else {
        r = try course_repo.list(st.db, ctx.arena, .{ .page = page, .size = size, .keyword = keyword, .category_id = category_id, .include_subtree = include_subtree });
    }
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

/// 分类维度课程计数（供管理后台分类树展示）
pub fn adminCourseStats(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const stats = try course_repo.countByCategory(st.db, ctx.arena);
    try respond.ok(res, .{ .items = stats });
}

pub fn adminGet(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const course = (try course_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("课程不存在"));

    const chs = try course_repo.chaptersByCourse(st.db, ctx.arena, id);
    var chapters: std.ArrayList(ChapterView) = .empty;
    for (chs) |ch| {
        var cv = chapterView(ch);
        const lessons = try course_repo.lessonsByChapter(st.db, ctx.arena, ch.id);
        var lvs: std.ArrayList(LessonView) = .empty;
        for (lessons) |le| {
            // 管理端永远不锁定，直接给全量
            try lvs.append(ctx.arena, lessonView(le, true));
        }
        cv.lessons = try lvs.toOwnedSlice(ctx.arena);
        try chapters.append(ctx.arena, cv);
    }
    try respond.ok(res, .{ .course = courseView(course), .chapters = try chapters.toOwnedSlice(ctx.arena) });
}

pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const body = common.readJson(CourseBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateCourse(ctx, st, &body)) return;

    const id = try course_repo.create(st.db, body.category_id, body.title, body.cover, body.summary, body.description, body.price, body.is_free, body.status, body.sort, common.nowSec(ctx));
    const course = (try course_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, courseView(course));
}

pub fn adminUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try course_repo.getByIdIncludingDeleted(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("课程不存在"));

    const body = common.readJson(CourseBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateCourse(ctx, st, &body)) return;

    course_repo.update(st.db, id, body.category_id, body.title, body.cover, body.summary, body.description, body.price, body.is_free, body.status, body.sort, common.nowSec(ctx)) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("课程不存在")),
        else => return err,
    };
    const course = (try course_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, courseView(course));
}

pub fn adminDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try course_repo.getByIdIncludingDeleted(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("课程不存在"));

    // 级联软删章节/课时
    course_repo.deleteSoft(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("课程不存在")),
        else => return err,
    };
    try st.db.exec("UPDATE chapters SET deleted = 1 WHERE course_id = ?1 AND deleted = 0", .{id});
    try st.db.exec("UPDATE lessons SET deleted = 1 WHERE course_id = ?1 AND deleted = 0", .{id});
    try respond.ok(res, .{ .status = "ok" });
}

// ---------------------------------------------------------------- 管理端：章节

const ChapterBody = struct {
    course_id: i64 = 0,
    title: []const u8 = "",
    sort: i64 = 0,
};

pub fn chapterCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const body = common.readJson(ChapterBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try courseMustExist(ctx, st, body.course_id)) return;
    if (!titleOk(body.title)) return ctx.failWith(framework.AppError.badRequest("章节标题需为 1-200 字符"));

    const id = try course_repo.chapterCreate(st.db, body.course_id, body.title, body.sort);
    const ch = (try course_repo.chapterGetById(st.db, ctx.arena, id)).?;
    try respond.ok(res, chapterView(ch));
}

pub fn chapterUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try course_repo.chapterGetById(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("章节不存在"));

    const body = common.readJson(ChapterBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try courseMustExist(ctx, st, body.course_id)) return;
    if (!titleOk(body.title)) return ctx.failWith(framework.AppError.badRequest("章节标题需为 1-200 字符"));

    course_repo.chapterUpdate(st.db, id, body.title, body.sort) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("章节不存在")),
        else => return err,
    };
    const ch = (try course_repo.chapterGetById(st.db, ctx.arena, id)).?;
    try respond.ok(res, chapterView(ch));
}

pub fn chapterDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    course_repo.chapterDelete(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("章节不存在")),
        else => return err,
    };
    // 级联软删课时
    try course_repo.lessonsDeleteByChapter(st.db, id);
    try respond.ok(res, .{ .status = "ok" });
}

// ---------------------------------------------------------------- 管理端：课时

const LessonBody = struct {
    course_id: i64 = 0,
    chapter_id: i64 = 0,
    title: []const u8 = "",
    content_type: []const u8 = "markdown",
    resource_id: i64 = 0,
    content: []const u8 = "",
    duration: i64 = 0,
    is_free: i64 = 0,
    sort: i64 = 0,
};

fn validateLesson(ctx: *framework.Context, st: *state.State, body: *const LessonBody) !bool {
    if (!try courseMustExist(ctx, st, body.course_id)) return false;
    if (body.chapter_id == 0) {
        try ctx.failWith(framework.AppError.badRequest("课时必须挂在章节下"));
        return false;
    }
    const chapter = (try course_repo.chapterGetById(st.db, ctx.arena, body.chapter_id)) orelse {
        try ctx.failWith(framework.AppError.badRequest("章节不存在"));
        return false;
    };
    if (chapter.course_id != body.course_id) {
        try ctx.failWith(framework.AppError.badRequest("章节不属于该课程"));
        return false;
    }
    if (!titleOk(body.title)) {
        try ctx.failWith(framework.AppError.badRequest("课时标题需为 1-200 字符"));
        return false;
    }
    if (!validLessonType(body.content_type)) {
        try ctx.failWith(framework.AppError.badRequest("content_type 仅支持 video/audio/pdf/markdown/rich"));
        return false;
    }
    if (body.resource_id != 0 and (try resource_repo.getById(st.db, ctx.arena, body.resource_id)) == null) {
        try ctx.failWith(framework.AppError.badRequest("关联的资料不存在"));
        return false;
    }
    if (body.duration < 0 or body.duration > 3600 * 24) {
        try ctx.failWith(framework.AppError.badRequest("课时时长（秒）超出范围"));
        return false;
    }
    if (body.is_free != 0 and body.is_free != 1) {
        try ctx.failWith(framework.AppError.badRequest("is_free 仅支持 0/1"));
        return false;
    }
    return true;
}

pub fn lessonCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const body = common.readJson(LessonBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateLesson(ctx, st, &body)) return;

    const id = try course_repo.lessonCreate(st.db, body.course_id, body.chapter_id, body.title, body.content_type, body.resource_id, body.content, body.duration, body.is_free, body.sort);
    const le = (try course_repo.lessonGetById(st.db, ctx.arena, id)).?;
    try respond.ok(res, lessonView(le, true));
}

pub fn lessonUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try course_repo.lessonGetById(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("课时不存在"));

    const body = common.readJson(LessonBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateLesson(ctx, st, &body)) return;

    course_repo.lessonUpdate(st.db, id, body.course_id, body.chapter_id, body.title, body.content_type, body.resource_id, body.content, body.duration, body.is_free, body.sort) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("课时不存在")),
        else => return err,
    };
    const le = (try course_repo.lessonGetById(st.db, ctx.arena, id)).?;
    try respond.ok(res, lessonView(le, true));
}

pub fn lessonDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    course_repo.lessonDelete(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("课时不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .status = "ok" });
}
