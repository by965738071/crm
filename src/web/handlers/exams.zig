//! 模拟考试 handler（M-E，第 5 期）。
//!   学员端（study 组，需登录）：
//!     GET  /api/exams                    试卷列表（仅 published + 我的参考统计）
//!     POST /api/exams/:id/start          开考（断线恢复 / 超时惰性自动交卷 / 抽新题）
//!     POST /api/exam-attempts/:id/answer 自动保存整卷作答（全量替换）
//!     POST /api/exam-attempts/:id/submit 交卷判分（空 body 时用已保存作答）
//!     GET  /api/exam-attempts?exam_id=   我的考试历史（可按试卷过滤）
//!     GET  /api/exam-attempts/:id        成绩回顾（仅已交卷）
//!   管理端（admin 组）：/api/admin/exams 的 CRUD（status 随 body 更新，无独立发布接口）。
//!
//! 判分口径（与 exam_repo 头注释一致）：
//! - 全对才得分（第一期不做多选部分分）；
//! - 逐题流水 practice_records（source=exam，session_id=attempt.id）全量记录；
//! - 错题本只动「非空作答」的题，未作答不进本；
//! - 交卷后 answers 列存完整判分记录（correct 为服务端结论），回顾直接读，
//!   不受题目后续编辑影响；判分本身用题库**当前**答案（题目改了会影响已交卷
//!   回顾口径是已知取舍，见 plan.md 第 11 节风险）。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const category_repo = @import("../../db/category_repo.zig");
const question_repo = @import("../../db/question_repo.zig");
const exam_repo = @import("../../db/exam_repo.zig");

// ---------------------------------------------------------------- 视图

const ExamView = struct {
    id: i64,
    category_id: i64,
    title: []const u8,
    duration_min: i64,
    total_score: i64,
    pass_score: i64,
    rules: []const exam_repo.Rule,
    status: []const u8,
    created_at: i64,
    question_count: i64,
};

fn examView(e: exam_repo.Exam) ExamView {
    return .{
        .id = e.id,
        .category_id = e.category_id,
        .title = e.title,
        .duration_min = e.duration_min,
        .total_score = e.total_score,
        .pass_score = e.pass_score,
        .rules = e.rules,
        .status = e.status,
        .created_at = e.created_at,
        .question_count = exam_repo.questionCount(e.rules),
    };
}

const MyExamView = struct {
    exam: ExamView,
    my_attempts: i64,
    my_best_score: i64, // -1 = 无已交卷记录
};

// ---------------------------------------------------------------- 学员端：列表

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);

    const r = try exam_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .category_id = category_id,
        .user_id = cu.id,
        .published_only = true,
    });
    var items: std.ArrayList(MyExamView) = .empty;
    for (r.items.items) |row| {
        try items.append(ctx.arena, .{
            .exam = examView(row.exam),
            .my_attempts = row.my_attempts,
            .my_best_score = row.my_best,
        });
    }
    try respond.ok(res, .{ .items = items.items, .total = r.total, .page = page, .size = size });
}

// ---------------------------------------------------------------- 开考 / 恢复

fn respondStart(
    res: *framework.Response,
    att: exam_repo.Attempt,
    e: exam_repo.Exam,
    now: i64,
    resumed: bool,
) !void {
    const remaining = if (now < att.deadline_at) att.deadline_at - now else 0;
    try respond.ok(res, .{
        .resumed = resumed,
        .attempt_id = att.id,
        .exam = .{
            .id = e.id,
            .title = e.title,
            .duration_min = e.duration_min,
            .total_score = e.total_score,
            .pass_score = e.pass_score,
        },
        .started_at = att.started_at,
        .deadline_at = att.deadline_at,
        .remaining_sec = remaining,
        // 快照题面不含答案（答案只在交卷后的回顾里出现）
        .questions = att.questions,
        .answers = att.answers,
    });
}

pub fn start(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    // 未发布/已删除统一 404（不泄露存在性，口径同课程学员端详情）
    const e = (try exam_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("试卷不存在"));
    if (!std.mem.eql(u8, e.status, "published"))
        return ctx.failWith(framework.AppError.notFound("试卷不存在"));

    const now = common.nowSec(ctx);

    if (try exam_repo.getActiveAttempt(st.db, ctx.arena, id, cu.id)) |att| {
        if (now <= att.deadline_at) {
            // 断线恢复：同一场考试续考，题序与已保存作答原样返回
            try respondStart(res, att, e, now, true);
            return;
        }
        // 超时惰性结算：以已保存作答自动交卷（submitted_at=deadline），再开新场
        try autoFinish(ctx, st, e, att, now);
    }

    switch (try exam_repo.drawSnapshot(st.db, ctx.arena, e.rules)) {
        .shortage => |s| {
            const msg = if (s.qtype.len == 0)
                // qtype="" 也可能是「分类总需求超池」（drawSnapshot 校验 2），文案兼顾两种来源
                try std.fmt.allocPrint(ctx.arena, "题池不足：分类 {d} 共需 {d} 题，仅有 {d} 题", .{ s.category_id, s.need, s.have })
            else
                try std.fmt.allocPrint(ctx.arena, "题池不足：分类 {d} 题型 {s} 需 {d} 题，仅有 {d}", .{ s.category_id, s.qtype, s.need, s.have });
            return ctx.failWith(framework.AppError.badRequest(msg));
        },
        .ok => |snap| {
            const qs_json = try exam_repo.encodeSnapshot(ctx.arena, snap);
            try st.db.exec("BEGIN IMMEDIATE", .{});
            errdefer st.db.exec("ROLLBACK", .{}) catch {};
            var ids: std.ArrayList(i64) = .empty;
            for (snap) |q| try ids.append(ctx.arena, q.id);
            try question_repo.bumpUsed(st.db, ids.items);
            const att_id = try exam_repo.createAttempt(st.db, .{
                .exam_id = id,
                .user_id = cu.id,
                .questions_json = qs_json,
                .started_at = now,
                .deadline_at = now + e.duration_min * 60,
            });
            try st.db.exec("COMMIT", .{});
            const att = (try exam_repo.getAttempt(st.db, ctx.arena, att_id)).?;
            try respondStart(res, att, e, now, false);
        },
    }
}

// ---------------------------------------------------------------- 判分核心

const GradeResult = struct {
    /// 按卷内题序的完整判分记录（入库形态）
    entries: []exam_repo.AnswerEntry,
    /// 流水/错题本用
    items: []exam_repo.GradedItem,
    score: i64,
    total: i64,
    correct_count: i64,
};

/// 对一组作答逐题判分。作答来源 = 客户端本次提交或自动保存的存量；
/// 判分基准 = 题库当前答案（题被删/缺失 → 判错，防御）。
fn gradeExam(
    ctx: *framework.Context,
    st: *state.State,
    snap: []const exam_repo.SnapshotQuestion,
    student: []const exam_repo.AnswerEntry,
) !GradeResult {
    var entries: std.ArrayList(exam_repo.AnswerEntry) = .empty;
    var items: std.ArrayList(exam_repo.GradedItem) = .empty;
    var score: i64 = 0;
    var total: i64 = 0;
    var cc: i64 = 0;
    for (snap) |q| {
        total += q.score;
        const ans = if (exam_repo.findAnswer(student, q.id)) |x| x.answer else "";
        const answered = ans.len > 0;
        var correct = false;
        if (answered) {
            if (try question_repo.getByIdIncludingDeleted(st.db, ctx.arena, q.id)) |row| {
                correct = exam_repo.gradeAnswer(row.type, row.answer, ans);
            }
        }
        if (correct) {
            score += q.score;
            cc += 1;
        }
        try entries.append(ctx.arena, .{ .question_id = q.id, .answer = ans, .correct = correct });
        try items.append(ctx.arena, .{ .question_id = q.id, .correct = correct, .answered = answered });
    }
    return .{
        .entries = try entries.toOwnedSlice(ctx.arena),
        .items = try items.toOwnedSlice(ctx.arena),
        .score = score,
        .total = total,
        .correct_count = cc,
    };
}

/// 超时自动交卷。并发下对方刚好已交（AlreadySubmitted）→ 忽略，继续开新场。
fn autoFinish(ctx: *framework.Context, st: *state.State, e: exam_repo.Exam, att: exam_repo.Attempt, now: i64) !void {
    const g = try gradeExam(ctx, st, att.questions, att.answers);
    exam_repo.finishAttempt(st.db, .{
        .attempt_id = att.id,
        .user_id = att.user_id,
        .answers_json = try exam_repo.encodeAnswers(ctx.arena, g.entries),
        .score = g.score,
        .passed = g.score >= e.pass_score,
        .submitted_at = att.deadline_at,
        .now = now,
        .items = g.items,
    }) catch |err| switch (err) {
        error.AlreadySubmitted => {},
        else => return err,
    };
}

// ---------------------------------------------------------------- 自动保存

const AnswerInput = struct {
    question_id: i64 = 0,
    answer: []const u8 = "",
};

const AnswerBody = struct {
    answers: []const AnswerInput = &.{},
};

fn toEntries(a: std.mem.Allocator, in: []const AnswerInput) ![]exam_repo.AnswerEntry {
    const out = try a.alloc(exam_repo.AnswerEntry, in.len);
    for (in, 0..) |x, i| out[i] = .{ .question_id = x.question_id, .answer = x.answer };
    return out;
}

pub fn saveAnswer(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const att = (try exam_repo.getAttemptForUser(st.db, ctx.arena, id, cu.id)) orelse
        return ctx.failWith(framework.AppError.notFound("考试记录不存在"));
    if (att.submitted_at > 0)
        return ctx.failWith(framework.AppError.badRequest("已交卷，不可再修改作答"));
    const now = common.nowSec(ctx);
    if (now > att.deadline_at)
        return ctx.failWith(framework.AppError.badRequest("考试已超时，请重新开考"));

    const body = common.readJson(AnswerBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    const entries = try toEntries(ctx.arena, body.answers);
    const json = try exam_repo.encodeAnswers(ctx.arena, entries);
    // 全量替换语义；false = 交卷瞬间并发，让前端刷新状态
    if (!(try exam_repo.saveAnswers(st.db, id, cu.id, json)))
        return ctx.failWith(framework.AppError.badRequest("已交卷，不可再修改作答"));
    try respond.ok(res, .{ .status = "ok", .saved = entries.len });
}

// ---------------------------------------------------------------- 交卷

const SubmitBody = struct {
    answers: []const AnswerInput = &.{},
};

pub fn submit(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const att = (try exam_repo.getAttemptForUser(st.db, ctx.arena, id, cu.id)) orelse
        return ctx.failWith(framework.AppError.notFound("考试记录不存在"));
    if (att.submitted_at > 0)
        return ctx.failWith(framework.AppError.badRequest("已交卷"));

    const body = common.readJson(SubmitBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    // 空 answers = 用自动保存的存量（允许超时后补交存量作答，正常判分）
    const student: []const exam_repo.AnswerEntry = if (body.answers.len > 0)
        try toEntries(ctx.arena, body.answers)
    else
        att.answers;

    const e = (try exam_repo.getByIdIncludingDeleted(st.db, ctx.arena, att.exam_id)) orelse
        return ctx.failWith(framework.AppError.internal("exam row missing"));
    const g = try gradeExam(ctx, st, att.questions, student);
    const now = common.nowSec(ctx);
    exam_repo.finishAttempt(st.db, .{
        .attempt_id = id,
        .user_id = cu.id,
        .answers_json = try exam_repo.encodeAnswers(ctx.arena, g.entries),
        .score = g.score,
        .passed = g.score >= e.pass_score,
        .submitted_at = now,
        .now = now,
        .items = g.items,
    }) catch |err| switch (err) {
        error.AlreadySubmitted => return ctx.failWith(framework.AppError.badRequest("已交卷")),
        else => return err,
    };

    try respond.ok(res, .{
        .score = g.score,
        .total_score = g.total, // 快照分值合计（与卷面自洽，可能≠试卷配置 total_score）
        .pass_score = e.pass_score,
        .passed = g.score >= e.pass_score,
        .correct_count = g.correct_count,
        .total_count = att.questions.len,
        .submitted_at = now,
    });
}

// ---------------------------------------------------------------- 考试历史

pub fn attemptList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const exam_id = common.parseQueryInt(ctx, "exam_id", 0, 1 << 40, 0);

    const r = try exam_repo.listAttempts(st.db, ctx.arena, cu.id, exam_id, page, size);
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

// ---------------------------------------------------------------- 成绩回顾

const ReviewItem = struct {
    question_id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
    answer: []const u8, // 正确答案（题库当前值；题已不可得则空）
    explanation: []const u8,
    student_answer: []const u8, // "" = 未作答
    correct: bool,
    score: i64, // 该题本卷分值
    score_gained: i64,
};

pub fn attemptDetail(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const att = (try exam_repo.getAttemptForUser(st.db, ctx.arena, id, cu.id)) orelse
        return ctx.failWith(framework.AppError.notFound("考试记录不存在"));
    if (att.submitted_at == 0)
        return ctx.failWith(framework.AppError.badRequest("尚未交卷，无法回顾"));

    const e = (try exam_repo.getByIdIncludingDeleted(st.db, ctx.arena, att.exam_id)) orelse
        return ctx.failWith(framework.AppError.internal("exam row missing"));

    var items: std.ArrayList(ReviewItem) = .empty;
    var total: i64 = 0;
    var cc: i64 = 0;
    for (att.questions) |q| {
        total += q.score;
        const entry = exam_repo.findAnswer(att.answers, q.id);
        const correct = if (entry) |x| x.correct orelse false else false;
        if (correct) cc += 1;
        const row = try question_repo.getByIdIncludingDeleted(st.db, ctx.arena, q.id);
        try items.append(ctx.arena, .{
            .question_id = q.id,
            .type = q.type,
            .stem = q.stem,
            .options = q.options,
            .answer = if (row) |r| r.answer else "",
            .explanation = if (row) |r| r.explanation else "",
            .student_answer = if (entry) |x| x.answer else "",
            .correct = correct,
            .score = q.score,
            .score_gained = if (correct) q.score else 0,
        });
    }

    try respond.ok(res, .{
        .attempt_id = att.id,
        .exam_id = att.exam_id,
        .exam_title = e.title,
        .score = att.score, // 存库成绩为准
        .total_score = total,
        .pass_score = e.pass_score,
        .passed = att.passed == 1,
        .correct_count = cc,
        .total_count = att.questions.len,
        .started_at = att.started_at,
        .deadline_at = att.deadline_at,
        .submitted_at = att.submitted_at,
        .items = items.items,
    });
}

// ---------------------------------------------------------------- 管理端

const ExamBody = struct {
    category_id: i64 = 0,
    title: []const u8 = "",
    duration_min: i64 = 60,
    total_score: i64 = 100,
    pass_score: i64 = 60,
    status: []const u8 = "draft",
    rules: []const exam_repo.Rule = &.{},
};

fn toInput(b: ExamBody) exam_repo.ExamInput {
    return .{
        .category_id = b.category_id,
        .title = b.title,
        .duration_min = b.duration_min,
        .total_score = b.total_score,
        .pass_score = b.pass_score,
        .status = b.status,
        .rules = b.rules,
    };
}

/// 主分类与各规则分类存在性校验（≤20 次点查）。失败时已响应。
fn validateRefs(ctx: *framework.Context, st: *state.State, in: exam_repo.ExamInput) !bool {
    if (in.category_id <= 0 or (try category_repo.getById(st.db, ctx.arena, in.category_id)) == null) {
        try ctx.failWith(framework.AppError.badRequest("分类不存在"));
        return false;
    }
    for (in.rules) |r| {
        if ((try category_repo.getById(st.db, ctx.arena, r.category_id)) == null) {
            const msg = try std.fmt.allocPrint(ctx.arena, "抽题规则引用的分类 {d} 不存在", .{r.category_id});
            try ctx.failWith(framework.AppError.badRequest(msg));
            return false;
        }
    }
    return true;
}

fn parseValidate(ctx: *framework.Context, st: *state.State) !?exam_repo.CanonicalExam {
    const body = common.readJson(ExamBody, ctx) catch {
        try ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
        return null;
    };
    const in = toInput(body);
    const canon = exam_repo.validateExam(ctx.arena, in) catch |err| switch (err) {
        // 注意：validateExam 错误集不含 OutOfMemory（encodeRules 无 dupe），勿加 prong
        error.WriteFailed => {
            try ctx.failWith(framework.AppError.internal("服务器内部错误"));
            unreachable; // failWith 永远以 error 返回
        },
        else => {
            try ctx.failWith(framework.AppError.badRequest(exam_repo.examValidationMsg(err)));
            return null;
        },
    };
    if (!try validateRefs(ctx, st, in)) return null;
    return canon;
}

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";
    const raw_status = ctx.query("status") orelse "";
    const status = if (exam_repo.validStatus(raw_status)) raw_status else "";
    const include_subtree = common.parseQueryInt(ctx, "sub", 0, 1, 0) == 1;

    const r = try exam_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .category_id = category_id,
        .status = status,
        .keyword = keyword,
        .include_subtree = include_subtree,
    });
    var items: std.ArrayList(ExamView) = .empty;
    for (r.items.items) |row| try items.append(ctx.arena, examView(row.exam));
    try respond.ok(res, .{ .items = items.items, .total = r.total, .page = page, .size = size });
}

/// 分类维度试卷计数（供管理后台分类树展示）
pub fn adminCategoryStats(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const stats = try exam_repo.countByCategory(st.db, ctx.arena);
    try respond.ok(res, .{ .items = stats });
}

pub fn adminGet(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const e = (try exam_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("试卷不存在"));
    try respond.ok(res, examView(e));
}

pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const canon = (try parseValidate(ctx, st)) orelse return;
    const id = try exam_repo.create(st.db, canon, common.nowSec(ctx));
    const e = (try exam_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, examView(e));
}

pub fn adminUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try exam_repo.getByIdIncludingDeleted(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("试卷不存在"));
    const canon = (try parseValidate(ctx, st)) orelse return;

    // 已有考试记录的试卷允许改（快照机制使历史不受影响）
    exam_repo.update(st.db, id, canon) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("试卷不存在")),
        else => return err,
    };
    const e = (try exam_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, examView(e));
}

pub fn adminDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try exam_repo.getByIdIncludingDeleted(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("试卷不存在"));
    exam_repo.deleteSoft(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("试卷不存在")),
        else => return err,
    };
    // 历史记录不删：exam_attempts 与成绩永久保留（回顾时 JOIN 不过滤 deleted）
    try respond.ok(res, .{ .status = "ok" });
}
