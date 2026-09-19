//! 题库管理 handler（M-D D1，挂 admin 组）：题目 CRUD + 批量导入（JSON/CSV）。
//!
//! 校验/规范化全部下沉 question_repo.validateQuestion（纯函数、可单测），
//! handler 只做「存在性检查 + 错误映射」。导入采取「先全量校验、全对才入库」
//! 的全有成败语义：避免部分导入后前端难以对账。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const category_repo = @import("../../db/category_repo.zig");
const course_repo = @import("../../db/course_repo.zig");
const question_repo = @import("../../db/question_repo.zig");

pub const import_max = 500;
const import_err_show = 10; // 校验错误最多展示前 10 条

const QuestionBody = struct {
    category_id: i64 = 0,
    course_id: i64 = 0,
    type: []const u8 = "",
    stem: []const u8 = "",
    options: []const []const u8 = &.{},
    answer: []const u8 = "",
    explanation: []const u8 = "",
    difficulty: i64 = 2,
};

const csv_header = "type,category_id,course_id,stem,options,answer,explanation,difficulty";
const csv_cols = 8;

fn toInput(b: QuestionBody) question_repo.QuestionInput {
    return .{
        .category_id = b.category_id,
        .course_id = b.course_id,
        .type = b.type,
        .stem = b.stem,
        .options = b.options,
        .answer = b.answer,
        .explanation = b.explanation,
        .difficulty = b.difficulty,
    };
}

/// category/course 存在性校验。失败时已响应，返回 false（约定同 courses.validateCourse）。
fn validateRefs(
    ctx: *framework.Context,
    st: *state.State,
    in: question_repo.QuestionInput,
) !bool {
    if (in.category_id <= 0 or (try category_repo.getById(st.db, ctx.arena, in.category_id)) == null) {
        try ctx.failWith(framework.AppError.badRequest("分类不存在"));
        return false;
    }
    if (in.course_id > 0 and (try course_repo.getById(st.db, ctx.arena, in.course_id)) == null) {
        try ctx.failWith(framework.AppError.badRequest("关联课程不存在"));
        return false;
    }
    return true;
}

fn failValidation(ctx: *framework.Context, err: anyerror) !void {
    return ctx.failWith(framework.AppError.badRequest(question_repo.validationMsg(err)));
}

// ---------------------------------------------------------------- CRUD

pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(QuestionBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    const in = toInput(body);
    if (!try validateRefs(ctx, st, in)) return;
    const q = question_repo.validateQuestion(ctx.arena, in) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return ctx.failWith(framework.AppError.internal("服务器内部错误")),
        else => return failValidation(ctx, err),
    };

    const id = try question_repo.create(st.db, .{ .q = q, .creator_id = cu.id, .now = common.nowSec(ctx) });
    const created = (try question_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, created);
}

pub fn adminUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    if ((try question_repo.getByIdIncludingDeleted(st.db, ctx.arena, id)) == null)
        return ctx.failWith(framework.AppError.notFound("题目不存在"));

    const body = common.readJson(QuestionBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    const in = toInput(body);
    if (!try validateRefs(ctx, st, in)) return;
    const q = question_repo.validateQuestion(ctx.arena, in) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return ctx.failWith(framework.AppError.internal("服务器内部错误")),
        else => return failValidation(ctx, err),
    };

    question_repo.update(st.db, id, q) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("题目不存在")),
        else => return err,
    };
    const updated = (try question_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, updated);
}

pub fn adminDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    question_repo.deleteSoft(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("题目不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .status = "ok" });
}

pub fn adminGet(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const q = (try question_repo.getById(st.db, ctx.arena, id)) orelse
        return ctx.failWith(framework.AppError.notFound("题目不存在"));
    try respond.ok(res, q);
}

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const ty = ctx.request.getQuery("type") orelse "";
    if (ty.len > 0 and !question_repo.validType(ty))
        return ctx.failWith(framework.AppError.badRequest("题型仅支持 single/multi/judge"));

    const page = common.parseQueryInt(ctx, "page", 1, 100_000, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const include_subtree = common.parseQueryInt(ctx, "sub", 0, 1, 0) == 1;
    const r = try question_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0),
        .course_id = common.parseQueryInt(ctx, "course_id", -1, 1 << 40, -1),
        .type = ty,
        .difficulty = common.parseQueryInt(ctx, "difficulty", 0, 5, 0),
        // keyword 可能含中文：必须走百分号解码，否则拿到的 %E4%B8%8B… 永远匹配不到题干
        .keyword = ctx.queryDecoded("keyword") catch null orelse "",
        .include_subtree = include_subtree,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

/// 分类维度题目计数（供管理后台分类树展示）
pub fn adminCategoryStats(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const stats = try question_repo.countByCategory(st.db, ctx.arena);
    try respond.ok(res, .{ .items = stats });
}

// ---------------------------------------------------------------- 批量导入

const ImportBody = struct {
    /// JSON 模式：题目数组（同单条创建的字段）
    questions: []const QuestionBody = &.{},
    /// CSV 模式：完整 CSV 文本（首行为固定表头，见 csv_header）
    csv: []const u8 = "",
};

pub const CsvError = error{ ColCount, BadInt, OptionCount } || std.mem.Allocator.Error;

/// CSV 行 → QuestionBody。列序同 csv_header；course_id/difficulty 空取默认；
/// options 用 '|' 分隔；多选答案写字母连串（ABD）。
/// fields 各段必须活在 a（解析用的 arena）上，dupe 只搬指针。
fn csvRowToBody(a: std.mem.Allocator, fields: []const []const u8) CsvError!QuestionBody {
    if (fields.len != csv_cols) return error.ColCount;
    var b: QuestionBody = .{};
    b.type = fields[0];
    b.category_id = std.fmt.parseInt(i64, fields[1], 10) catch return error.BadInt;
    if (fields[2].len > 0) b.course_id = std.fmt.parseInt(i64, fields[2], 10) catch return error.BadInt;
    b.stem = fields[3];

    // options ≤ max_options 固定栈数组收集，最后 dupe 切片的「切片」到 arena
    var arr: [question_repo.max_options][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, fields[4], '|');
    while (it.next()) |piece| {
        if (piece.len == 0) continue; // 连续分隔符当空段忽略
        if (n >= question_repo.max_options) return error.OptionCount;
        arr[n] = piece;
        n += 1;
    }
    if (n > 0) b.options = try a.dupe([]const u8, arr[0..n]);

    b.answer = fields[5];
    b.explanation = fields[6];
    if (fields[7].len > 0) b.difficulty = std.fmt.parseInt(i64, fields[7], 10) catch return error.BadInt;
    return b;
}

/// 统一导入流程：bodies 已全部解析好；逐条存在性 + 规范化校验（收集行号错误），
/// 全对才开事务插入。返回已插入条数。
fn importValidated(
    ctx: *framework.Context,
    st: *state.State,
    bodies: []const QuestionBody,
    creator_id: i64,
    now: i64,
) !usize {
    var errors: std.ArrayList([]const u8) = .empty;
    var valid: std.ArrayList(question_repo.Canonical) = .empty;

    for (bodies, 0..) |b, idx| {
        const row_no = idx + 1;
        const in = toInput(b);
        var why: ?[]const u8 = null;
        var canon: ?question_repo.Canonical = null;
        // 存在性：直接查库（≤500 行，单连接串行无压力）
        if (in.category_id <= 0 or (try category_repo.getById(st.db, ctx.arena, in.category_id)) == null) {
            why = "分类不存在";
        } else if (in.course_id > 0 and (try course_repo.getById(st.db, ctx.arena, in.course_id)) == null) {
            why = "关联课程不存在";
        } else {
            // 0.17-dev 移除了 catch-else，用 if-else-capture 表达成功/失败两分支
            if (question_repo.validateQuestion(ctx.arena, in)) |c| {
                canon = c;
            } else |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return err,
                else => why = question_repo.validationMsg(err),
            }
        }
        if (why) |msg| {
            try errors.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "第{d}行: {s}", .{ row_no, msg }));
            continue;
        }
        try valid.append(ctx.arena, canon.?);
    }

    if (errors.items.len > 0) {
        var msg_buf: std.ArrayList(u8) = .empty;
        const show = @min(errors.items.len, import_err_show);
        for (errors.items[0..show], 0..) |e, i| {
            if (i > 0) try msg_buf.append(ctx.arena, '\n');
            try msg_buf.appendSlice(ctx.arena, e);
        }
        if (errors.items.len > show) {
            const tail = try std.fmt.allocPrint(ctx.arena, "\n…共 {d} 条错误", .{errors.items.len});
            try msg_buf.appendSlice(ctx.arena, tail);
        }
        try ctx.failWith(framework.AppError.badRequest(msg_buf.items));
        unreachable; // failWith 永远以 error 返回（见 context.zig）
    }

    try st.db.exec("BEGIN IMMEDIATE", .{});
    errdefer st.db.exec("ROLLBACK", .{}) catch {};
    for (valid.items) |q| {
        _ = try question_repo.create(st.db, .{ .q = q, .creator_id = creator_id, .now = now });
    }
    try st.db.exec("COMMIT", .{});
    return valid.items.len;
}

/// POST /admin/questions/import — {questions:[...]} 或 {csv:"..."} 二选一
pub fn adminImport(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    const now = common.nowSec(ctx);

    const body = common.readJson(ImportBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if ((body.questions.len > 0) == (body.csv.len > 0))
        return ctx.failWith(framework.AppError.badRequest("questions 与 csv 必须二选一"));

    const n = if (body.questions.len > 0) blk: {
        if (body.questions.len > import_max)
            return ctx.failWith(framework.AppError.badRequest("单次导入最多 500 题"));
        break :blk try importValidated(ctx, st, body.questions, cu.id, now);
    } else blk: {
        const rows = question_repo.parseCsv(ctx.arena, body.csv) catch
            return ctx.failWith(framework.AppError.badRequest("CSV 解析失败（引号不闭合？）"));
        if (rows.len < 2)
            return ctx.failWith(framework.AppError.badRequest("CSV 至少需要表头 + 1 行数据"));
        if (rows.len - 1 > import_max)
            return ctx.failWith(framework.AppError.badRequest("单次导入最多 500 题"));
        // BOM 容忍（Excel 导出常带）
        if (rows[0].len != csv_cols or !std.mem.eql(u8, std.mem.trim(u8, rows[0][0], " \xEF\xBB\xBF"), "type"))
            return ctx.failWith(framework.AppError.badRequest("CSV 表头需为 " ++ csv_header));

        var bodies: std.ArrayList(QuestionBody) = .empty;
        for (rows[1..], 0..) |fields, i| {
            const b = csvRowToBody(ctx.arena, fields) catch {
                return ctx.failWith(framework.AppError.badRequest(
                    try std.fmt.allocPrint(ctx.arena, "第{d}行列数/数字格式不正确", .{i + 2}),
                ));
            };
            try bodies.append(ctx.arena, b);
        }
        break :blk try importValidated(ctx, st, bodies.items, cu.id, now);
    };
    try respond.ok(res, .{ .imported = n });
}
