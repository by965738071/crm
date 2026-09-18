//! 练习 handler（M-D D2/D3/D4/D5，挂学员登录态组）：
//!   章节/随机练习、逐题判分、错题本、收藏切换。
//!
//! 「练习会话」采用无状态设计：start 抽题并返回（含题序），submit 逐题作答即时判分。
//! 服务端不持有会话，因此错题/收藏以「题」为粒度，与是否在同一场练习无关。
//! 抽题后 used_count 递增放在事务里，与判分/落库解耦。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const category_repo = @import("../../db/category_repo.zig");
const question_repo = @import("../../db/question_repo.zig");
const practice_repo = @import("../../db/practice_repo.zig");

// ---------------------------------------------------------------- 抽题

const StartBody = struct {
    mode: []const u8 = "chapter", // chapter | random
    category_id: i64 = 0,
    /// 1 = 按分类子树抽题（选专业/父分类时）；0 = 精确分类；category_id=0 恒为全量
    sub: i64 = 0,
    count: i64 = 10,
};

/// 题目视图（学员端：不含答案与解析）
const QuizView = struct {
    id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
};

pub fn start(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    _ = try authm.currentUser(ctx);

    const body = common.readJson(StartBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    const random_order = if (std.mem.eql(u8, body.mode, "random"))
        true
    else if (std.mem.eql(u8, body.mode, "chapter")) false else {
        return ctx.failWith(framework.AppError.badRequest("mode 仅支持 chapter/random"));
    };
    if (body.category_id < 0 or (body.category_id > 0 and (try category_repo.getById(st.db, ctx.arena, body.category_id)) == null))
        return ctx.failWith(framework.AppError.badRequest("分类不存在"));
    const count = @min(50, @max(1, body.count)); // 单次抽题上限 50，防刷

    const drawn = try question_repo.drawForPractice(st.db, ctx.arena, body.category_id, body.sub == 1, random_order, count);
    if (drawn.len == 0)
        return ctx.failWith(framework.AppError.badRequest("当前抽题范围暂无题目"));

    // used_count 事务内递增（与抽题尽量原子；即使失败只影响统计列，不影响抽题结果）
    var ids: std.ArrayList(i64) = .empty;
    for (drawn) |d| try ids.append(ctx.arena, d.id);
    try st.db.exec("BEGIN IMMEDIATE", .{});
    errdefer st.db.exec("ROLLBACK", .{}) catch {};
    try question_repo.bumpUsed(st.db, ids.items);
    try st.db.exec("COMMIT", .{});

    var items: std.ArrayList(QuizView) = .empty;
    for (drawn) |d| {
        try items.append(ctx.arena, .{ .id = d.id, .type = d.type, .stem = d.stem, .options = d.options });
    }
    try respond.ok(res, .{ .count = drawn.len, .items = items.items });
}

// ---------------------------------------------------------------- 逐题判分

const SubmitBody = struct {
    question_id: i64 = 0,
    answer: []const u8 = "",
    duration: i64 = 0,
    source: []const u8 = "chapter",
};

/// 判分结果视图：回显正确答案与解析，附带错题本状态。
const GradeView = struct {
    correct: bool,
    answer: []const u8,
    explanation: []const u8,
    in_wrong_book: bool,
    wrong_count: i64,
};

pub fn submit(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(SubmitBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!practice_repo.validSource(body.source))
        return ctx.failWith(framework.AppError.badRequest("source 仅支持 chapter/random/exam"));
    const qid: i64 = body.question_id;
    if (qid <= 0) {
        // 兼容路径传参：/practice/submit/:id 不存在，这里仍从 body 取；保持简单
        return ctx.failWith(framework.AppError.badRequest("缺少 question_id"));
    }
    const q = (try question_repo.getById(st.db, ctx.arena, qid)) orelse
        return ctx.failWith(framework.AppError.notFound("题目不存在"));
    if (body.answer.len == 0)
        return ctx.failWith(framework.AppError.badRequest("请作答"));
    if (body.duration < 0 or body.duration > 3600)
        return ctx.failWith(framework.AppError.badRequest("duration 需在 0-3600 之间"));

    const correct = question_repo.checkAnswer(q.type, q.answer, body.answer) catch
        return ctx.failWith(framework.AppError.badRequest("作答格式不正确"));
    const outcome = try practice_repo.recordAnswer(st.db, .{
        .user_id = cu.id,
        .question_id = q.id,
        .is_correct = correct,
        .duration = body.duration,
        .source = body.source,
        .now = common.nowSec(ctx),
    });

    try respond.ok(res, GradeView{
        .correct = correct,
        .answer = q.answer,
        .explanation = q.explanation,
        .in_wrong_book = outcome.in_wrong_book,
        .wrong_count = outcome.wrong_count,
    });
}

// ---------------------------------------------------------------- 错题本

const WrongView = struct {
    id: i64,
    wrong_count: i64,
    mastered: i64,
    last_wrong_at: i64,
    question: QuestionWithAnswer,
};

/// 错题本/收藏里的题面带答案与解析（复盘用）
const QuestionWithAnswer = struct {
    id: i64,
    category_id: i64,
    course_id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
    answer: []const u8,
    explanation: []const u8,
    difficulty: i64,
};

fn mapQuestion(q: question_repo.Question) QuestionWithAnswer {
    return .{
        .id = q.id,
        .category_id = q.category_id,
        .course_id = q.course_id,
        .type = q.type,
        .stem = q.stem,
        .options = q.options,
        .answer = q.answer,
        .explanation = q.explanation,
        .difficulty = q.difficulty,
    };
}

pub fn wrongList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    // mastered: 0=只看未掌握(默认) 1=只看已掌握 -1/空=全部
    const mastered = common.parseQueryInt(ctx, "mastered", 0, 1, -1);
    const r = try practice_repo.listWrong(st.db, ctx.arena, cu.id, mastered, page, size);

    var items: std.ArrayList(WrongView) = .empty;
    for (r.items.items) |w| {
        try items.append(ctx.arena, .{
            .id = w.id,
            .wrong_count = w.wrong_count,
            .mastered = w.mastered,
            .last_wrong_at = w.last_wrong_at,
            .question = mapQuestion(w.question),
        });
    }
    try respond.ok(res, .{ .items = items.items, .total = r.total, .page = page, .size = size });
}

pub fn masterWrong(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if (!(try practice_repo.masterWrong(st.db, cu.id, id)))
        return ctx.failWith(framework.AppError.notFound("错题记录不存在"));
    try respond.ok(res, .{ .status = "ok" });
}

// ---------------------------------------------------------------- 收藏

pub fn toggleFavorite(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try question_repo.getById(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("题目不存在"));
    const fav = try practice_repo.toggleFavorite(st.db, cu.id, id, common.nowSec(ctx));
    try respond.ok(res, .{ .favorited = fav });
}

/// 收藏列表（题面带答案与解析，复盘用）。软删题不展示。
const FavView = struct {
    id: i64,
    created_at: i64,
    question: QuestionWithAnswer,
};

pub fn favorites(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const r = try practice_repo.listFavorites(st.db, ctx.arena, cu.id, page, size);

    var items: std.ArrayList(FavView) = .empty;
    for (r.items.items) |f| {
        try items.append(ctx.arena, .{ .id = f.id, .created_at = f.created_at, .question = mapQuestion(f.question) });
    }
    try respond.ok(res, .{ .items = items.items, .total = r.total, .page = page, .size = size });
}
