//! 模拟考试域（M-E）：试卷（exams）、抽题规则（rules JSON）、考试会话（exam_attempts）。
//!
//! 设计要点（见 plan.md 第 5/6 节与第 9 期第 5 阶段）：
//! - 抽题规则 rules = `[{type,category_id,count,score_each}]`，type 空串 = 该分类任意题型；
//! - 开考时把题面（含每题分值）整体快照进 exam_attempts.questions，判分只认快照：
//!   题目后续被改/被软删都不影响已开考会话（回顾时用 getByIdIncludingDeleted 兜底）；
//! - 交卷判分：全对才得分（第一期不做多选部分分）；空作答记错但不进错题本，
//!   避免未作答污染错题本（流水 practice_records 仍逐题记录，session_id=attempt.id）；
//! - 服务端计时：deadline_at = started_at + duration_min*60；过期不主动清理，
//!   下次 /start 时惰性自动交卷（submitted_at=deadline_at）后再开新场。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const question_repo = @import("question_repo.zig");
const practice_repo = @import("practice_repo.zig");

// ---------------------------------------------------------------- 试卷

pub const max_title_len = 128;
pub const max_duration_min = 300;
pub const max_total_score = 10_000;
pub const max_rules = 20;
pub const max_questions_per_exam = 100;

pub const Rule = struct {
    /// "" = 该分类任意题型；否则 single/multi/judge
    type: []const u8 = "",
    category_id: i64 = 0,
    count: i64 = 0,
    score_each: i64 = 0,
};

pub const Exam = struct {
    id: i64,
    category_id: i64,
    title: []const u8,
    duration_min: i64,
    total_score: i64,
    pass_score: i64,
    rules: []Rule,
    status: []const u8,
    created_at: i64,
};

pub fn questionCount(rules: []const Rule) i64 {
    var n: i64 = 0;
    for (rules) |r| n += r.count;
    return n;
}

pub const ExamValidationError = error{
    BadTitle,       // 空或超长
    BadDuration,    // 不在 1-300 分钟
    BadTotal,       // 不在 1-10000 分
    BadPass,        // pass_score 不在 0..total_score
    BadStatus,      // 非 draft/published
    BadRules,       // 规则条数为 0 或超上限
    BadRuleField,   // 单条规则字段非法
    BadRuleTotal,   // Σcount 不在 1..100
    BadScoreSum,    // Σ(count*score_each) != total_score
};

/// 注：catch 的 error 集无法穷举 ValidationError 并集，按项目惯例收 anyerror + else 兜底。
pub fn examValidationMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.BadTitle => "试卷标题不能为空且最长 128 字符",
        error.BadDuration => "考试时长需在 1-300 分钟之间",
        error.BadTotal => "总分需在 1-10000 之间",
        error.BadPass => "及格分需在 0 与总分之间",
        error.BadStatus => "status 仅支持 draft/published",
        error.BadRules => "抽题规则需 1-20 条",
        error.BadRuleField => "抽题规则字段非法（分类需存在、count 1-100、score_each 1-100、type 为空或 single/multi/judge）",
        error.BadRuleTotal => "总题数需在 1-100 之间",
        error.BadScoreSum => "各规则分值合计与总分不一致",
        else => "试卷配置不合法",
    };
}

pub const ExamInput = struct {
    category_id: i64 = 0,
    title: []const u8 = "",
    duration_min: i64 = 0,
    total_score: i64 = 0,
    pass_score: i64 = 0,
    status: []const u8 = "",
    rules: []const Rule = &.{},
};

/// 已通过校验、可直接入库的试卷
pub const CanonicalExam = struct {
    category_id: i64,
    title: []const u8,
    duration_min: i64,
    total_score: i64,
    pass_score: i64,
    status: []const u8,
    rules_json: []const u8,
};

pub fn validStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "draft") or std.mem.eql(u8, status, "published");
}

/// 纯校验（不查库）；分类存在性（主分类 + 各规则分类）由 handler 负责。
pub fn validateExam(a: std.mem.Allocator, in: ExamInput) !CanonicalExam {
    if (in.title.len == 0 or in.title.len > max_title_len) return error.BadTitle;
    if (in.duration_min < 1 or in.duration_min > max_duration_min) return error.BadDuration;
    if (in.total_score < 1 or in.total_score > max_total_score) return error.BadTotal;
    if (in.pass_score < 0 or in.pass_score > in.total_score) return error.BadPass;
    if (!validStatus(in.status)) return error.BadStatus;

    if (in.rules.len == 0 or in.rules.len > max_rules) return error.BadRules;
    var sum_count: i64 = 0;
    var sum_score: i64 = 0;
    for (in.rules) |r| {
        if (r.category_id <= 0) return error.BadRuleField;
        if (r.count < 1 or r.count > max_questions_per_exam) return error.BadRuleField;
        if (r.score_each < 1 or r.score_each > 100) return error.BadRuleField;
        if (r.type.len != 0 and !question_repo.validType(r.type)) return error.BadRuleField;
        sum_count += r.count;
        sum_score += r.count * r.score_each;
    }
    if (sum_count < 1 or sum_count > max_questions_per_exam) return error.BadRuleTotal;
    if (sum_score != in.total_score) return error.BadScoreSum;

    return .{
        .category_id = in.category_id,
        .title = in.title,
        .duration_min = in.duration_min,
        .total_score = in.total_score,
        .pass_score = in.pass_score,
        .status = in.status,
        .rules_json = try encodeRules(a, in.rules),
    };
}

// ---------------------------------------------------------------- rules JSON

pub fn encodeRules(a: std.mem.Allocator, rules: []const Rule) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try s.write(rules);
    return buf.written();
}

pub fn decodeRules(a: std.mem.Allocator, json_str: []const u8) ![]Rule {
    if (json_str.len == 0) return &.{};
    // std.json 静态解析借用输入内存；Row 临时文本会在 deinit 后悬垂 → 先 dupe
    const owned = try a.dupe(u8, json_str);
    const parsed = std.json.parseFromSlice([]Rule, a, owned, .{ .ignore_unknown_fields = true }) catch
        return error.BrokenData;
    return parsed.value;
}

// ---------------------------------------------------------------- 试卷 CRUD

const exam_cols = "id, category_id, title, duration_min, total_score, pass_score, rules, status, created_at";

fn rowToExam(a: std.mem.Allocator, row: zqlite.Row) !Exam {
    return .{
        .id = row.int(0),
        .category_id = row.int(1),
        .title = try a.dupe(u8, row.text(2)),
        .duration_min = row.int(3),
        .total_score = row.int(4),
        .pass_score = row.int(5),
        .rules = try decodeRules(a, row.text(6)),
        .status = try a.dupe(u8, row.text(7)),
        .created_at = row.int(8),
    };
}

pub fn create(dbh: *db.Db, e: CanonicalExam, now: i64) !i64 {
    try dbh.exec(
        "INSERT INTO exams (category_id, title, duration_min, total_score, pass_score, rules, status, created_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        .{ e.category_id, e.title, e.duration_min, e.total_score, e.pass_score, e.rules_json, e.status, now },
    );
    return dbh.lastInsertId();
}

/// 更新不改 created_at（表无 updated_at 列，见 migrate v1）。
pub fn update(dbh: *db.Db, id: i64, e: CanonicalExam) !void {
    try dbh.exec(
        "UPDATE exams SET category_id=?1, title=?2, duration_min=?3, total_score=?4, pass_score=?5, rules=?6, status=?7 " ++
            "WHERE id=?8 AND deleted=0",
        .{ e.category_id, e.title, e.duration_min, e.total_score, e.pass_score, e.rules_json, e.status, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64) !void {
    try dbh.exec("UPDATE exams SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

fn getByIdWhere(dbh: *db.Db, a: std.mem.Allocator, id: i64, comptime sql: []const u8) !?Exam {
    const row = try dbh.conn.row("SELECT " ++ exam_cols ++ " FROM exams WHERE " ++ sql, .{id});
    const r = row orelse return null;
    defer r.deinit();
    return try rowToExam(a, r);
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Exam {
    return getByIdWhere(dbh, a, id, "id = ?1 AND deleted = 0 LIMIT 1");
}

pub fn getByIdIncludingDeleted(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Exam {
    return getByIdWhere(dbh, a, id, "id = ?1 LIMIT 1");
}

pub const ExamListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    category_id: i64 = 0, // 0 = 不过滤
    status: []const u8 = "", // 管理端过滤；"" = 全部
    keyword: []const u8 = "",
    user_id: i64 = 0, // >0 时附带个人成绩子查询（学员端）
    published_only: bool = false, // 学员端 = true
    /// true = category_id 按分类子树过滤（配合递归 CTE）
    include_subtree: bool = false,
};

pub const ExamRow = struct {
    exam: Exam,
    my_attempts: i64 = 0,
    my_best: i64 = -1,
};

/// LIKE 元字符转义（同 question_repo.likePattern 口径）
fn likePattern(a: std.mem.Allocator, kw: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(a, kw.len * 2 + 2) catch return error.OutOfMemory;
    buf.appendAssumeCapacity('%');
    for (kw) |c| {
        switch (c) {
            '%', '_', '\\' => buf.appendAssumeCapacity('\\'),
            else => {},
        }
        buf.appendAssumeCapacity(c);
    }
    buf.appendAssumeCapacity('%');
    return buf.items;
}

pub const ExamList = struct {
    items: std.ArrayList(ExamRow),
    total: i64,
};

/// 管理端/学员端共用一套 SQL：个人统计子查询恒计算（user_id=0 时结果为 0/-1，
/// 无行可扫，成本与 EXISTS 分支相当），换取单条 SQL 简单性。
/// 子树过滤：各套 SQL 全部在 comptime 拼成常量（参数个数一致 ?1..?8），运行时只做常量选择。
/// 根分类绑 ?1；depth < 20 防 categories 父子环时无限递归。
const cte_subtree =
    "WITH RECURSIVE sub(id, depth) AS (" ++
    " SELECT ?1, 0" ++
    " UNION ALL" ++
    " SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id" ++
    " WHERE c.deleted = 0 AND s.depth < 20) ";

const exam_where =
    "deleted = 0 AND (?1 = 0 OR category_id = ?1) AND " ++
        "(?2 = '' OR status = ?2) AND (?3 = '' OR (?3 = 'published' AND status = 'published')) AND " ++
        "(?4 = '' OR title LIKE ?5 ESCAPE '\\')";

const exam_where_subtree =
    "deleted = 0 AND (?1 = 0 OR category_id IN (SELECT id FROM sub)) AND " ++
        "(?2 = '' OR status = ?2) AND (?3 = '' OR (?3 = 'published' AND status = 'published')) AND " ++
        "(?4 = '' OR title LIKE ?5 ESCAPE '\\')";

const exam_count_exact = "SELECT COUNT(*) FROM exams WHERE " ++ exam_where;
const exam_count_subtree = cte_subtree ++ "SELECT COUNT(*) FROM exams WHERE " ++ exam_where_subtree;
const exam_rows_exact =
    "SELECT " ++ exam_cols ++ ", " ++
        "(SELECT COUNT(*) FROM exam_attempts ea WHERE ea.exam_id = exams.id AND ea.user_id = ?6), " ++
        "(SELECT COALESCE(MAX(score), -1) FROM exam_attempts eb WHERE eb.exam_id = exams.id AND eb.user_id = ?6 AND eb.submitted_at > 0) " ++
        "FROM exams WHERE " ++ exam_where ++ " ORDER BY id DESC LIMIT ?7 OFFSET ?8";
const exam_rows_subtree =
    cte_subtree ++ "SELECT " ++ exam_cols ++ ", " ++
        "(SELECT COUNT(*) FROM exam_attempts ea WHERE ea.exam_id = exams.id AND ea.user_id = ?6), " ++
        "(SELECT COALESCE(MAX(score), -1) FROM exam_attempts eb WHERE eb.exam_id = exams.id AND eb.user_id = ?6 AND eb.submitted_at > 0) " ++
        "FROM exams WHERE " ++ exam_where_subtree ++ " ORDER BY id DESC LIMIT ?7 OFFSET ?8";

/// 分类维度试卷计数（不含软删）。category_id=0 表示未分类。
pub const CategoryCount = struct {
    category_id: i64,
    count: i64,
};

pub fn countByCategory(dbh: *db.Db, a: std.mem.Allocator) ![]CategoryCount {
    var items: std.ArrayList(CategoryCount) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT category_id, COUNT(*) FROM exams WHERE deleted = 0 GROUP BY category_id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{ .category_id = row.int(0), .count = row.int(1) });
    }
    if (rows.err) |e| return e;
    return items.items;
}

pub fn list(dbh: *db.Db, a: std.mem.Allocator, o: ExamListOpts) !ExamList {
    const like = try likePattern(a, o.keyword);
    const total = (try dbh.scalarInt(
        if (o.include_subtree) exam_count_subtree else exam_count_exact,
        .{ o.category_id, if (o.published_only) "" else o.status, if (o.published_only) "published" else "", o.keyword, like },
    )) orelse 0;

    var items: std.ArrayList(ExamRow) = .empty;
    var rows = try dbh.conn.rows(
        if (o.include_subtree) exam_rows_subtree else exam_rows_exact,
        .{
            o.category_id,
            if (o.published_only) "" else o.status,
            if (o.published_only) "published" else "",
            o.keyword,
            like,
            o.user_id,
            o.size,
            (o.page - 1) * o.size,
        },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{
            .exam = try rowToExam(a, row),
            .my_attempts = row.int(9),
            .my_best = row.int(10),
        });
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 抽题

/// 题池不足信息（供 handler 组 400 文案）
pub const PoolShortage = struct {
    category_id: i64,
    qtype: []const u8, // "" = 任意题型
    need: i64,
    have: i64,
};

pub fn countPool(dbh: *db.Db, category_id: i64, qtype: []const u8) !i64 {
    // ++ 编译期拼接，两分支各自拼完整；绑定参数个数不同也必须分支
    if (qtype.len == 0) {
        return (try dbh.scalarInt(
            "SELECT COUNT(*) FROM questions WHERE category_id = ?1 AND deleted = 0",
            .{category_id},
        )) orelse 0;
    }
    return (try dbh.scalarInt(
        "SELECT COUNT(*) FROM questions WHERE category_id = ?1 AND deleted = 0 AND type = ?2",
        .{ category_id, qtype },
    )) orelse 0;
}

/// 快照题面：抽题后与题库解耦（score = 该题在本卷分值）。
pub const SnapshotQuestion = struct {
    id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
    score: i64,
};

/// 学员作答（question_id → answer 原文）。
/// `correct` 是交卷时服务端回写的判分结论（入库形态即完整判分记录）；
/// 自动保存阶段为 null。读取存储时用前校验：客户端传入的 correct 一律丢弃重判，
/// 不存在伪造入口（review 只信存库的 correct）。
pub const AnswerEntry = struct {
    question_id: i64 = 0,
    answer: []const u8 = "",
    correct: ?bool = null,
};

const Drawn = struct {
    id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
};

fn drawPool(dbh: *db.Db, a: std.mem.Allocator, category_id: i64, qtype: []const u8, need: i64) ![]Drawn {
    var items: std.ArrayList(Drawn) = .empty;
    const head = "SELECT id, type, stem, options FROM questions WHERE category_id = ?1 AND deleted = 0";
    if (qtype.len == 0) {
        var rows = try dbh.conn.rows(head ++ " ORDER BY RANDOM() LIMIT ?2", .{ category_id, need });
        defer rows.deinit();
        while (rows.next()) |row| {
            try items.append(a, .{
                .id = row.int(0),
                .type = try a.dupe(u8, row.text(1)),
                .stem = try a.dupe(u8, row.text(2)),
                .options = try question_repo.decodeOptions(a, row.text(3)),
            });
        }
        if (rows.err) |e| return e;
    } else {
        var rows = try dbh.conn.rows(head ++ " AND type = ?2 ORDER BY RANDOM() LIMIT ?3", .{ category_id, qtype, need });
        defer rows.deinit();
        while (rows.next()) |row| {
            try items.append(a, .{
                .id = row.int(0),
                .type = try a.dupe(u8, row.text(1)),
                .stem = try a.dupe(u8, row.text(2)),
                .options = try question_repo.decodeOptions(a, row.text(3)),
            });
        }
        if (rows.err) |e| return e;
    }
    return items.toOwnedSlice(a);
}

pub const DrawResult = union(enum) {
    ok: []SnapshotQuestion,
    shortage: PoolShortage,
};

/// 按规则抽题生成快照。卷内题序 = 规则声明顺序（不额外乱序，题型自然分段，
/// 便于前端渲染，此为有意的产品决策）。
///
/// 可行性两层校验（同一分类的「任意题型」桶与具体题型桶共享物理题池，
/// 若只按桶各自计数会漏判重叠超需）：
/// 1. 每个精确桶 (cat,type)：该题型存量 ≥ 桶需求；
/// 2. 每个分类 cat：Σ该分类所有规则 count ≤ 分类总存量。
/// 两条件同时满足即可行（运输问题的贪心特例）：先抽具体题型桶（同分类下
/// 不同题型的池互斥），再抽「任意」桶：多抽 prev 份候选并排除已用 id，
/// 存活数 ≥ need 由条件 2 保证（见下方推导）。
pub fn drawSnapshot(dbh: *db.Db, a: std.mem.Allocator, rules: []const Rule) !DrawResult {
    const Bucket = struct {
        category_id: i64,
        qtype: []const u8,
        need: i64,
        drawn: []Drawn = &.{},
        cursor: usize = 0,
    };
    var buckets: std.ArrayList(Bucket) = .empty;
    for (rules) |r| {
        var merged = false;
        for (buckets.items) |*b| {
            if (b.category_id == r.category_id and std.mem.eql(u8, b.qtype, r.type)) {
                b.need += r.count;
                merged = true;
                break;
            }
        }
        if (!merged) try buckets.append(a, .{ .category_id = r.category_id, .qtype = r.type, .need = r.count });
    }

    // 校验 1：精确桶（含「任意」桶自身的分类存量）
    for (buckets.items) |b| {
        const have = try countPool(dbh, b.category_id, b.qtype);
        if (have < b.need) return .{ .shortage = .{ .category_id = b.category_id, .qtype = b.qtype, .need = b.need, .have = have } };
    }
    // 校验 2：每分类总需求 ≤ 分类总存量
    var cats: std.ArrayList(i64) = .empty;
    for (rules) |r| {
        if (std.mem.indexOfScalar(i64, cats.items, r.category_id) == null) try cats.append(a, r.category_id);
    }
    for (cats.items) |cat| {
        var demand: i64 = 0;
        for (rules) |r| { // 同一分类可能多条规则，累加全部 count
            if (r.category_id == cat) demand += r.count;
        }
        const have = try countPool(dbh, cat, "");
        if (have < demand) return .{ .shortage = .{ .category_id = cat, .qtype = "", .need = demand, .have = have } };
    }

    // 具体题型桶先抽：同分类内不同题型的池互斥，无需排除
    var used: std.ArrayList(i64) = .empty;
    for (buckets.items) |*b| {
        if (b.qtype.len == 0) continue;
        b.drawn = try drawPool(dbh, a, b.category_id, b.qtype, b.need);
        for (b.drawn) |d| try used.append(a, d.id);
    }
    // 「任意」桶后抽：候选量 = need + 该分类已用数（最坏全撞车），排除后存活 ≥ need：
    //   返回候选 = min(need+prev, pool) = need+prev（由校验 2 保证 pool ≥ need+prev），
    //   撞车数 ≤ prev ⇒ 存活 ≥ need。
    for (buckets.items) |*b| {
        if (b.qtype.len != 0) continue;
        var prev: i64 = 0;
        for (buckets.items) |ob| { // 同分类其余桶已全部抽完；本「任意」桶此时 drawn 为空，
            // 且每分类至多一个「任意」桶（已聚合），故只累加具体题型桶即可
            if (ob.category_id == b.category_id and ob.qtype.len != 0) prev += @intCast(ob.drawn.len);
        }
        const cands = try drawPool(dbh, a, b.category_id, "", b.need + prev);
        var kept: std.ArrayList(Drawn) = .empty;
        for (cands) |d| {
            if (kept.items.len >= @as(usize, @intCast(b.need))) break;
            if (std.mem.indexOfScalar(i64, used.items, d.id) != null) continue;
            try kept.append(a, d);
            try used.append(a, d.id);
        }
        if (kept.items.len < @as(usize, @intCast(b.need))) {
            // 理论上不可达（校验 2 已保证存活足够）；兼作越界防护
            return .{ .shortage = .{ .category_id = b.category_id, .qtype = "", .need = b.need, .have = @intCast(kept.items.len) } };
        }
        b.drawn = try kept.toOwnedSlice(a);
    }

    var items: std.ArrayList(SnapshotQuestion) = .empty;
    for (rules) |r| {
        var b: *Bucket = for (buckets.items) |*bb| {
            if (bb.category_id == r.category_id and std.mem.eql(u8, bb.qtype, r.type)) break bb;
        } else undefined;
        const take: usize = @intCast(r.count);
        for (0..take) |i| {
            const d = b.drawn[b.cursor + i];
            try items.append(a, .{ .id = d.id, .type = d.type, .stem = d.stem, .options = d.options, .score = r.score_each });
        }
        b.cursor += take;
    }
    return .{ .ok = try items.toOwnedSlice(a) };
}

pub fn encodeSnapshot(a: std.mem.Allocator, qs: []const SnapshotQuestion) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try s.write(qs);
    return buf.written();
}

pub fn decodeSnapshot(a: std.mem.Allocator, json_str: []const u8) ![]SnapshotQuestion {
    if (json_str.len == 0) return &.{};
    const owned = try a.dupe(u8, json_str);
    const parsed = std.json.parseFromSlice([]SnapshotQuestion, a, owned, .{ .ignore_unknown_fields = true }) catch
        return error.BrokenData;
    return parsed.value;
}

pub fn encodeAnswers(a: std.mem.Allocator, ans: []const AnswerEntry) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try s.write(ans);
    return buf.written();
}

pub fn decodeAnswers(a: std.mem.Allocator, json_str: []const u8) ![]AnswerEntry {
    if (json_str.len == 0) return &.{};
    const owned = try a.dupe(u8, json_str);
    const parsed = std.json.parseFromSlice([]AnswerEntry, a, owned, .{ .ignore_unknown_fields = true }) catch
        return error.BrokenData;
    return parsed.value;
}

/// 取某题的作答条目：重复条目以**最后一条**为准（扫描到末尾即可，语义定为后写覆盖）。
pub fn findAnswer(answers: []const AnswerEntry, question_id: i64) ?AnswerEntry {
    var found: ?AnswerEntry = null;
    for (answers) |x| {
        if (x.question_id == question_id) found = x;
    }
    return found;
}

// ---------------------------------------------------------------- 判分

/// 单题判分（考试专用共享原语，交卷与回顾都走这里保证确定性一致）：
/// - 空作答/未作答 = 错；
/// - checkAnswer 格式非法（乱填）= 错（不报错，考试场景容忍脏数据）；
/// - judge 的 "true"/"TRUE" 等宽松形式由 normalizeStudentAnswer 处理。
pub fn gradeAnswer(qtype: []const u8, stored_answer: []const u8, student: ?[]const u8) bool {
    const s = student orelse return false;
    if (s.len == 0) return false;
    return question_repo.checkAnswer(qtype, stored_answer, s) catch false;
}

// ---------------------------------------------------------------- 考试会话

pub const Attempt = struct {
    id: i64,
    exam_id: i64,
    user_id: i64,
    questions: []SnapshotQuestion,
    answers: []AnswerEntry,
    score: i64,
    passed: i64,
    started_at: i64,
    deadline_at: i64,
    submitted_at: i64,
};

const attempt_cols = "id, exam_id, user_id, questions, answers, score, passed, started_at, deadline_at, submitted_at";

fn rowToAttempt(a: std.mem.Allocator, row: zqlite.Row) !Attempt {
    return .{
        .id = row.int(0),
        .exam_id = row.int(1),
        .user_id = row.int(2),
        .questions = try decodeSnapshot(a, row.text(3)),
        .answers = try decodeAnswers(a, row.text(4)),
        .score = row.int(5),
        .passed = row.int(6),
        .started_at = row.int(7),
        .deadline_at = row.int(8),
        .submitted_at = row.int(9),
    };
}

fn attemptAtWhere(dbh: *db.Db, a: std.mem.Allocator, comptime sql: []const u8, args: anytype) !?Attempt {
    const row = try dbh.conn.row("SELECT " ++ attempt_cols ++ " FROM exam_attempts WHERE " ++ sql, args);
    const r = row orelse return null;
    defer r.deinit();
    return try rowToAttempt(a, r);
}

pub fn getAttempt(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Attempt {
    return attemptAtWhere(dbh, a, "id = ?1 LIMIT 1", .{id});
}

pub fn getAttemptForUser(dbh: *db.Db, a: std.mem.Allocator, id: i64, user_id: i64) !?Attempt {
    return attemptAtWhere(dbh, a, "id = ?1 AND user_id = ?2 LIMIT 1", .{ id, user_id });
}

/// 该用户在该试卷下进行中的最近一场（submitted_at=0）。
pub fn getActiveAttempt(dbh: *db.Db, a: std.mem.Allocator, exam_id: i64, user_id: i64) !?Attempt {
    const row = try dbh.conn.row(
        "SELECT " ++ attempt_cols ++ " FROM exam_attempts WHERE exam_id = ?1 AND user_id = ?2 AND submitted_at = 0 ORDER BY id DESC LIMIT 1",
        .{ exam_id, user_id },
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToAttempt(a, r);
}

pub const CreateAttemptParams = struct {
    exam_id: i64,
    user_id: i64,
    questions_json: []const u8,
    started_at: i64,
    deadline_at: i64,
};

pub fn createAttempt(dbh: *db.Db, p: CreateAttemptParams) !i64 {
    try dbh.exec(
        "INSERT INTO exam_attempts (exam_id, user_id, questions, answers, started_at, deadline_at) " ++
            "VALUES (?1, ?2, ?3, '[]', ?4, ?5)",
        .{ p.exam_id, p.user_id, p.questions_json, p.started_at, p.deadline_at },
    );
    return dbh.lastInsertId();
}

/// 自动保存：整卷替换 answers。返回 false = 已交卷/不存在/并发交卷（调用方复查）。
pub fn saveAnswers(dbh: *db.Db, id: i64, user_id: i64, answers_json: []const u8) !bool {
    try dbh.exec(
        "UPDATE exam_attempts SET answers = ?2 WHERE id = ?1 AND user_id = ?3 AND submitted_at = 0",
        .{ id, answers_json, user_id },
    );
    return dbh.conn.changes() != 0;
}

/// 每题判分结果（落流水用；answered=false 时不碰错题本）。
pub const GradedItem = struct {
    question_id: i64,
    correct: bool,
    answered: bool,
};

pub const FinishParams = struct {
    attempt_id: i64,
    user_id: i64,
    answers_json: []const u8,
    score: i64,
    passed: bool,
    /// 交卷时间戳（正常交卷=now；超时自动交卷=deadline_at）
    submitted_at: i64,
    now: i64,
    items: []const GradedItem,
};

/// 交卷（单事务）：成绩落库 + 逐题流水（source=exam，session_id=attempt.id）+
/// 错题本（仅非空作答）。UPDATE 带 submitted_at=0 守卫，二次提交 → AlreadySubmitted。
pub fn finishAttempt(dbh: *db.Db, p: FinishParams) !void {
    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "UPDATE exam_attempts SET answers=?2, score=?3, passed=?4, submitted_at=?5 " ++
            "WHERE id=?1 AND submitted_at=0",
        .{ p.attempt_id, p.answers_json, p.score, @as(i64, if (p.passed) 1 else 0), p.submitted_at },
    );
    if (dbh.conn.changes() == 0) return error.AlreadySubmitted;

    for (p.items) |it| {
        try practice_repo.insertRecord(dbh, .{
            .user_id = p.user_id,
            .question_id = it.question_id,
            .is_correct = it.correct,
            .duration = 0,
            .source = "exam",
            .now = p.now,
            .session_id = p.attempt_id,
        });
        if (it.answered) {
            try practice_repo.applyWrongBook(dbh, p.user_id, it.question_id, it.correct, p.now);
        }
    }
    try dbh.exec("COMMIT", .{});
}

pub const AttemptSummary = struct {
    id: i64,
    exam_id: i64,
    exam_title: []const u8,
    score: i64,
    passed: i64,
    question_count: i64,
    started_at: i64,
    deadline_at: i64,
    submitted_at: i64,
};

pub const AttemptSummaryList = struct {
    items: std.ArrayList(AttemptSummary),
    total: i64,
};

/// 个人考试历史。**不排除**已删试卷（JOIN exams 无 deleted 过滤）：历史成绩必须可见。
/// question_count 由快照 JSON 解码得到（交卷后卷面题数是回顾刚需，成本可接受）。
pub fn listAttempts(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, exam_id: i64, page: i64, size: i64) !AttemptSummaryList {
    const cond = "(?1 = 0 OR ea.exam_id = ?1)";
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM exam_attempts ea WHERE ea.user_id = ?2 AND " ++ cond,
        .{ exam_id, user_id },
    )) orelse 0;
    var items: std.ArrayList(AttemptSummary) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT ea.id, ea.exam_id, e.title, ea.score, ea.passed, ea.started_at, ea.deadline_at, ea.submitted_at, ea.questions " ++
            "FROM exam_attempts ea JOIN exams e ON e.id = ea.exam_id " ++
            "WHERE ea.user_id = ?2 AND " ++ cond ++ " ORDER BY ea.id DESC LIMIT ?3 OFFSET ?4",
        .{ exam_id, user_id, size, (page - 1) * size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        const snap = try decodeSnapshot(a, row.text(8));
        try items.append(a, .{
            .id = row.int(0),
            .exam_id = row.int(1),
            .exam_title = try a.dupe(u8, row.text(2)),
            .score = row.int(3),
            .passed = row.int(4),
            .question_count = @intCast(snap.len),
            .started_at = row.int(5),
            .deadline_at = row.int(6),
            .submitted_at = row.int(7),
        });
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------------------
// 测试

const exams_ddl =
    \\CREATE TABLE IF NOT EXISTS exams (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  category_id INTEGER NOT NULL DEFAULT 0,
    \\  title TEXT NOT NULL,
    \\  duration_min INTEGER NOT NULL DEFAULT 60,
    \\  total_score INTEGER NOT NULL DEFAULT 100,
    \\  pass_score INTEGER NOT NULL DEFAULT 60,
    \\  rules TEXT NOT NULL DEFAULT '[]',
    \\  status TEXT NOT NULL DEFAULT 'draft',
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
;

const attempts_ddl =
    \\CREATE TABLE IF NOT EXISTS exam_attempts (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  exam_id INTEGER NOT NULL,
    \\  user_id INTEGER NOT NULL,
    \\  questions TEXT NOT NULL DEFAULT '[]',
    \\  answers TEXT NOT NULL DEFAULT '[]',
    \\  score INTEGER NOT NULL DEFAULT -1,
    \\  passed INTEGER NOT NULL DEFAULT 0,
    \\  started_at INTEGER NOT NULL,
    \\  deadline_at INTEGER NOT NULL,
    \\  submitted_at INTEGER NOT NULL DEFAULT 0
    \\)
;

pub const test_sqls = practice_repo.test_sqls ++ [_][]const u8{ exams_ddl, attempts_ddl };

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    for (test_sqls) |sql| try dbh.exec(sql, .{});
    try dbh.exec(test_sql_cats, .{});
    return dbh;
}

const test_sql_cats =
    \\CREATE TABLE IF NOT EXISTS categories (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  parent_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
;

fn makeQuestion(dbh: *db.Db, a: std.mem.Allocator, cat: i64, qtype: []const u8, stem: []const u8, answer: []const u8) !i64 {
    var opts: []const []const u8 = &.{};
    if (!std.mem.eql(u8, qtype, "judge")) opts = &.{ "opA", "opB", "opC" };
    const c = try question_repo.validateQuestion(a, .{ .category_id = cat, .type = qtype, .stem = stem, .options = opts, .answer = answer });
    return question_repo.create(dbh, .{ .q = c, .creator_id = 1, .now = 1 });
}

test "exam_repo 子树过滤与分类计数" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/exam_repo_subtree_test.db");
    defer dbh.close();

    // 分类树 30 -> 31 -> 32；exam A 挂 cat30（已上架），exam B 挂 cat32（草稿），无关卷挂 cat40
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (30, 0, '根'), (31, 30, '子'), (32, 31, '孙')", .{});
    const rules = [_]Rule{.{ .category_id = 31, .count = 2, .score_each = 10 }};
    const e1 = try validateExam(a, .{ .category_id = 30, .title = "试卷A", .duration_min = 30, .total_score = 20, .pass_score = 12, .status = "published", .rules = &rules });
    _ = try create(&dbh, e1, 1);
    const e2 = try validateExam(a, .{ .category_id = 32, .title = "试卷B", .duration_min = 30, .total_score = 20, .pass_score = 12, .status = "draft", .rules = &rules });
    _ = try create(&dbh, e2, 1);
    const e3 = try validateExam(a, .{ .category_id = 40, .title = "无关卷", .duration_min = 30, .total_score = 20, .pass_score = 12, .status = "published", .rules = &rules });
    _ = try create(&dbh, e3, 1);

    // 精确：cat30 只有试卷A；子树：含 cat32 的试卷B
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 30 })).total);
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{ .category_id = 30, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 32, .include_subtree = true })).total);
    // 子树 + 管理端状态过滤
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 30, .status = "draft", .include_subtree = true })).total);
    // 子树 + 学员端仅已发布
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 30, .published_only = true, .include_subtree = true })).total);

    // 分类计数（未删）
    const stats = try countByCategory(&dbh, a);
    var found = std.AutoHashMap(i64, i64).init(a);
    defer found.deinit();
    for (stats) |s| try found.put(s.category_id, s.count);
    try std.testing.expectEqual(@as(?i64, 1), found.get(30));
    try std.testing.expectEqual(@as(?i64, 1), found.get(32));
    try std.testing.expectEqual(@as(?i64, 1), found.get(40));
    try std.testing.expectEqual(@as(?i64, null), found.get(31));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/exam_repo_subtree_test.db") catch {};
}

test "validateExam 规则与分值一致性" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok_rules = [_]Rule{ .{ .category_id = 1, .count = 3, .score_each = 10 }, .{ .type = "judge", .category_id = 2, .count = 7, .score_each = 10 } };
    const good = try validateExam(a, .{ .category_id = 1, .title = "模考A", .duration_min = 60, .total_score = 100, .pass_score = 60, .status = "published", .rules = &ok_rules });
    try std.testing.expectEqualStrings("模考A", good.title);

    // 标题/时长/总分/及格分/status
    try std.testing.expectError(error.BadTitle, validateExam(a, .{ .title = "", .duration_min = 60, .total_score = 100, .status = "draft", .rules = &ok_rules }));
    try std.testing.expectError(error.BadDuration, validateExam(a, .{ .title = "t", .duration_min = 0, .total_score = 100, .status = "draft", .rules = &ok_rules }));
    try std.testing.expectError(error.BadTotal, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 0, .status = "draft", .rules = &ok_rules }));
    try std.testing.expectError(error.BadPass, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 100, .pass_score = 101, .status = "draft", .rules = &ok_rules }));
    try std.testing.expectError(error.BadStatus, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 100, .status = "on", .rules = &ok_rules }));

    // 规则条数 / 单条字段
    try std.testing.expectError(error.BadRules, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 100, .status = "draft", .rules = &.{} }));
    try std.testing.expectError(error.BadRuleField, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 30, .status = "draft", .rules = &.{.{ .category_id = 0, .count = 3, .score_each = 10 }} }));
    try std.testing.expectError(error.BadRuleField, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 30, .status = "draft", .rules = &.{.{ .category_id = 1, .count = 0, .score_each = 10 }} }));
    try std.testing.expectError(error.BadRuleField, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 30, .status = "draft", .rules = &.{.{ .category_id = 1, .count = 3, .score_each = 101 }} }));
    try std.testing.expectError(error.BadRuleField, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 30, .status = "draft", .rules = &.{.{ .type = "xxx", .category_id = 1, .count = 3, .score_each = 10 }} }));

    // Σcount 上限：20 条规则（合法上限内）× 6 题 = 120 > 100 → BadRuleTotal
    var many: [max_rules]Rule = undefined;
    for (&many) |*r| r.* = .{ .category_id = 1, .count = 6, .score_each = 1 };
    try std.testing.expectError(error.BadRuleTotal, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 120, .status = "draft", .rules = &many }));
    // 规则条数超上限 → BadRules
    var too_many: [max_rules + 1]Rule = undefined;
    for (&too_many) |*r| r.* = .{ .category_id = 1, .count = 1, .score_each = 1 };
    try std.testing.expectError(error.BadRules, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 21, .status = "draft", .rules = &too_many }));
    try std.testing.expectError(error.BadScoreSum, validateExam(a, .{ .title = "t", .duration_min = 60, .total_score = 99, .status = "draft", .rules = &ok_rules }));
}

test "rules / snapshot / answers JSON round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rules = [_]Rule{ .{ .type = "single", .category_id = 2, .count = 5, .score_each = 10 }, .{ .category_id = 3, .count = 2, .score_each = 25 } };
    const js = try encodeRules(a, &rules);
    const back = try decodeRules(a, js);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("single", back[0].type);
    try std.testing.expectEqual(@as(i64, 3), back[1].category_id);
    try std.testing.expectEqual(@as(i64, 25), back[1].score_each);

    const snap = [_]SnapshotQuestion{.{ .id = 7, .type = "multi", .stem = "s?", .options = &.{ "甲", "乙" }, .score = 10 }};
    const sj = try encodeSnapshot(a, &snap);
    const sback = try decodeSnapshot(a, sj);
    try std.testing.expectEqualStrings("s?", sback[0].stem);
    try std.testing.expectEqualStrings("甲", sback[0].options[0]);
    try std.testing.expectEqual(@as(i64, 10), sback[0].score);

    const ans = [_]AnswerEntry{ .{ .question_id = 7, .answer = "AB" }, .{ .question_id = 7, .answer = "A" } };
    const aj = try encodeAnswers(a, &ans);
    const aback = try decodeAnswers(a, aj);
    try std.testing.expectEqual(@as(usize, 2), aback.len);
    // 重复条目 → 后写覆盖；未设 correct → 默认 null
    try std.testing.expectEqualStrings("A", findAnswer(aback, 7).?.answer);
    try std.testing.expect(findAnswer(aback, 7).?.correct == null);
    try std.testing.expect(findAnswer(aback, 8) == null);

    try std.testing.expectError(error.BrokenData, decodeRules(a, "not json"));
}

test "gradeAnswer" {
    try std.testing.expect(gradeAnswer("single", "B", "b"));
    try std.testing.expect(!gradeAnswer("single", "B", "A"));
    try std.testing.expect(gradeAnswer("judge", "T", "true")); // 宽松形式
    try std.testing.expect(!gradeAnswer("judge", "T", "")); // 空作答 = 错
    try std.testing.expect(!gradeAnswer("judge", "T", null)); // 未作答 = 错
    try std.testing.expect(!gradeAnswer("multi", "AC", "A")); // 不全对 = 0 分
    try std.testing.expect(!gradeAnswer("single", "B", "zzz")); // 乱填（规范化后为空）= 错
}

test "drawSnapshot 池校验 / 同桶去重 / 顺序" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/exam_repo_draw_test.db");
    defer dbh.close();

    // cat7: 5 道 single + 3 道 judge；cat8: 1 道 multi
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = try makeQuestion(&dbh, a, 7, "single", "s7", "A");
    while (i < 8) : (i += 1) _ = try makeQuestion(&dbh, a, 7, "judge", "j7", "T");
    _ = try makeQuestion(&dbh, a, 8, "multi", "m8", "AB");

    try std.testing.expectEqual(@as(i64, 5), try countPool(&dbh, 7, "single"));
    try std.testing.expectEqual(@as(i64, 8), try countPool(&dbh, 7, ""));
    try std.testing.expectEqual(@as(i64, 0), try countPool(&dbh, 99, ""));

    // 池不足：single 要 6 道只有 5
    const shortage = [_]Rule{.{ .type = "single", .category_id = 7, .count = 6, .score_each = 10 }};
    switch (try drawSnapshot(&dbh, a, &shortage)) {
        .shortage => |s| {
            try std.testing.expectEqual(@as(i64, 7), s.category_id);
            try std.testing.expectEqualStrings("single", s.qtype);
            try std.testing.expectEqual(@as(i64, 6), s.need);
            try std.testing.expectEqual(@as(i64, 5), s.have);
        },
        .ok => return error.TestUnexpectedResult,
    }

    // 同桶两规则：各抽 2，合计 4；必须两两不重复
    const two_rules = [_]Rule{
        .{ .type = "single", .category_id = 7, .count = 2, .score_each = 10 },
        .{ .type = "single", .category_id = 7, .count = 2, .score_each = 20 },
        .{ .category_id = 8, .count = 1, .score_each = 5 },
    };
    switch (try drawSnapshot(&dbh, a, &two_rules)) {
        .ok => |snap| {
            try std.testing.expectEqual(@as(usize, 5), snap.len);
            try std.testing.expectEqual(@as(i64, 10), snap[0].score);
            try std.testing.expectEqual(@as(i64, 20), snap[2].score);
            try std.testing.expectEqualStrings("multi", snap[4].type);
            try std.testing.expectEqual(@as(usize, 0), dupCount(snap)); // 无重复题
        },
        .shortage => return error.TestUnexpectedResult,
    }

    // 具体题型桶与「任意」桶共享物理池：single 3 + any 5，池 single5/judge3（共 8）
    // 需求 8 ≤ 8 → 可行；且不得出现重复题（旧版单桶校验会重复抽中）
    const overlap = [_]Rule{
        .{ .type = "single", .category_id = 7, .count = 3, .score_each = 10 },
        .{ .category_id = 7, .count = 5, .score_each = 10 },
    };
    switch (try drawSnapshot(&dbh, a, &overlap)) {
        .ok => |snap| {
            try std.testing.expectEqual(@as(usize, 8), snap.len);
            try std.testing.expectEqual(@as(usize, 0), dupCount(snap));
        },
        .shortage => return error.TestUnexpectedResult,
    }
    // 总需求超分类池（即便各精确桶单独看都够）→ 报分类级不足（qtype=""）
    const over_total = [_]Rule{
        .{ .type = "single", .category_id = 7, .count = 5, .score_each = 10 },
        .{ .category_id = 7, .count = 4, .score_each = 10 },
    };
    switch (try drawSnapshot(&dbh, a, &over_total)) {
        .ok => return error.TestUnexpectedResult,
        .shortage => |s| {
            try std.testing.expectEqual(@as(i64, 7), s.category_id);
            try std.testing.expectEqualStrings("", s.qtype);
            try std.testing.expectEqual(@as(i64, 9), s.need);
            try std.testing.expectEqual(@as(i64, 8), s.have);
        },
    }
}

fn dupCount(snap: []const SnapshotQuestion) usize {
    var n: usize = 0;
    for (snap, 0..) |q, x| {
        var y: usize = x + 1;
        while (y < snap.len) : (y += 1) {
            if (q.id == snap[y].id) n += 1;
        }
    }
    return n;
}

test "试卷 CRUD / 考试全流程（交卷判分 + 流水 + 错题本 + 重复交卷）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/exam_repo_crud_test.db");
    defer dbh.close();
    const now: i64 = 1_760_100_000;

    const canon = try validateExam(a, .{
        .category_id = 1,
        .title = "期末模考",
        .duration_min = 90,
        .total_score = 40,
        .pass_score = 24,
        .status = "published",
        .rules = &.{.{ .category_id = 1, .count = 4, .score_each = 10 }},
    });
    const exam_id = try create(&dbh, canon, now);
    const e = (try getById(&dbh, a, exam_id)).?;
    try std.testing.expectEqualStrings("期末模考", e.title);
    try std.testing.expectEqual(@as(usize, 1), e.rules.len);
    try std.testing.expectEqual(@as(i64, 4), questionCount(e.rules));

    // 列表（学员/管理端口径共用）
    const ls = try list(&dbh, a, .{ .published_only = true, .user_id = 42 });
    try std.testing.expectEqual(@as(i64, 1), ls.total);
    try std.testing.expectEqual(@as(i64, 0), ls.items.items[0].my_attempts);
    try std.testing.expectEqual(@as(i64, -1), ls.items.items[0].my_best);

    // 软删后不可见，但 IncludingDeleted 仍可得
    try deleteSoft(&dbh, exam_id);
    try std.testing.expect((try getById(&dbh, a, exam_id)) == null);
    try std.testing.expect((try getByIdIncludingDeleted(&dbh, a, exam_id)) != null);
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .published_only = true })).total);
    // update 影响 0 行 → NotFound（已软删）
    try std.testing.expectError(error.NotFound, update(&dbh, exam_id + 999, canon));
    try dbh.exec("UPDATE exams SET deleted = 0 WHERE id = ?1", .{exam_id}); // 还原，供后续流程

    // 抽题快照 → 开考
    const qs = [_]SnapshotQuestion{
        .{ .id = 101, .type = "single", .stem = "A?", .options = &.{ "x", "y" }, .score = 10 },
        .{ .id = 102, .type = "judge", .stem = "B?", .options = &.{}, .score = 10 },
        .{ .id = 103, .type = "single", .stem = "C?", .options = &.{ "x", "y" }, .score = 10 },
        .{ .id = 104, .type = "multi", .stem = "D?", .options = &.{ "x", "y", "z" }, .score = 10 },
    };
    const att_id = try createAttempt(&dbh, .{
        .exam_id = exam_id,
        .user_id = 42,
        .questions_json = try encodeSnapshot(a, &qs),
        .started_at = now,
        .deadline_at = now + 90 * 60,
    });
    try std.testing.expect((try getActiveAttempt(&dbh, a, exam_id, 42)).?.id == att_id);
    try std.testing.expect((try getActiveAttempt(&dbh, a, exam_id, 43)) == null);

    // 自动保存
    const ans = [_]AnswerEntry{
        .{ .question_id = 101, .answer = "x" }, // 错（合法字母）
        .{ .question_id = 102, .answer = "T" }, // 对
        .{ .question_id = 103, .answer = "A" }, // 对（题不存在 → 防御判错）
    };
    try std.testing.expect(try saveAnswers(&dbh, att_id, 42, try encodeAnswers(a, &ans)));
    try std.testing.expect(!(try saveAnswers(&dbh, att_id, 43, "[]"))); // 非本人

    // 判分：101 错、102 对、103 题不存在→错（防御）、104 未作答→错。
    // （判分在 handler/repo 边界之上，repo 测落库；这里直接构造 GradedItem）
    const items = [_]GradedItem{
        .{ .question_id = 101, .correct = false, .answered = true },
        .{ .question_id = 102, .correct = true, .answered = true },
        .{ .question_id = 103, .correct = false, .answered = true },
        .{ .question_id = 104, .correct = false, .answered = false },
    };
    try finishAttempt(&dbh, .{
        .attempt_id = att_id,
        .user_id = 42,
        .answers_json = try encodeAnswers(a, &ans),
        .score = 10,
        .passed = false,
        .submitted_at = now + 600,
        .now = now + 600,
        .items = &items,
    });
    const att = (try getAttemptForUser(&dbh, a, att_id, 42)).?;
    try std.testing.expectEqual(@as(i64, 10), att.score);
    try std.testing.expectEqual(@as(i64, now + 600), att.submitted_at);
    try std.testing.expect((try getActiveAttempt(&dbh, a, exam_id, 42)) == null);

    // 重复交卷 → AlreadySubmitted
    try std.testing.expectError(error.AlreadySubmitted, finishAttempt(&dbh, .{
        .attempt_id = att_id,
        .user_id = 42,
        .answers_json = "[]",
        .score = 0,
        .passed = false,
        .submitted_at = now + 700,
        .now = now + 700,
        .items = &.{},
    }));
    // 交卷后不可再保存
    try std.testing.expect(!(try saveAnswers(&dbh, att_id, 42, "[]")));

    // 流水：4 行，session_id=attempt.id
    try std.testing.expectEqual(@as(i64, 4), (try dbh.scalarInt("SELECT COUNT(*) FROM practice_records WHERE session_id = ?1 AND source = 'exam'", .{att_id})).?);
    // 错题本：只进 answered 的错题（101、103）；104 空作答不进
    try std.testing.expectEqual(@as(i64, 1), (try dbh.scalarInt("SELECT COUNT(*) FROM wrong_questions WHERE user_id = 42 AND question_id = 101", .{})).?);
    try std.testing.expectEqual(@as(i64, 1), (try dbh.scalarInt("SELECT COUNT(*) FROM wrong_questions WHERE user_id = 42 AND question_id = 103", .{})).?);
    try std.testing.expectEqual(@as(i64, 0), (try dbh.scalarInt("SELECT COUNT(*) FROM wrong_questions WHERE user_id = 42 AND question_id = 104", .{})).?);
    // 答对 102 不进本、若有历史记录则标已掌握（无 → 0 行）
    try std.testing.expectEqual(@as(i64, 0), (try dbh.scalarInt("SELECT COUNT(*) FROM wrong_questions WHERE user_id = 42 AND question_id = 102", .{})).?);

    // 历史列表（试卷不可见时也能查）
    const hist = try listAttempts(&dbh, a, 42, 0, 1, 10);
    try std.testing.expectEqual(@as(i64, 1), hist.total);
    try std.testing.expectEqualStrings("期末模考", hist.items.items[0].exam_title);
    try std.testing.expectEqual(@as(i64, 4), hist.items.items[0].question_count);
    try std.testing.expectEqual(@as(i64, 0), (try listAttempts(&dbh, a, 43, 0, 1, 10)).total);

    // 学员端统计子查询
    const ls2 = try list(&dbh, a, .{ .published_only = true, .user_id = 42 });
    try std.testing.expectEqual(@as(i64, 1), ls2.items.items[0].my_attempts);
    try std.testing.expectEqual(@as(i64, 10), ls2.items.items[0].my_best);
}
