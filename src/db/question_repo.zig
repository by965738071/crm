//! 题库（M-D）：题目 CRUD 与抽题。
//!
//! repo 约定同 course_repo：手写 SQL + 行转换 dupe 到 arena。
//!
//! 答案规范化（入库前，见 validateQuestion）：
//!   judge  → "T" / "F"
//!   single → 单个大写字母 "A".."Z"
//!   multi  → 升序去重大写字母串 "ABD"
//! 判分 = 对学员作答做同样的宽松规范化后与入库答案字符串相等。
//! options 列存 JSON 字符串数组（["..",".."]）；judge 题固定为 "[]"（选项语义内置 对/错）。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");
const colref = @import("colref.zig");

pub const valid_types = [_][]const u8{ "single", "multi", "judge" };

pub const max_options = 12;
pub const min_options = 2;
pub const max_stem_len = 4000;
pub const max_option_len = 500;
pub const max_explanation_len = 8000;

pub const Question = struct {
    id: i64,
    category_id: i64,
    course_id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
    /// 规范化后的正确答案（"A" / "ABD" / "T"/"F"）
    answer: []const u8,
    explanation: []const u8,
    difficulty: i64,
    used_count: i64,
};

pub const QuestionList = struct {
    items: std.ArrayList(Question),
    total: i64,
};

/// 抽题用的「学员视图」行（不含 answer/explanation，防泄漏）
pub const PracticeQuestion = struct {
    id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
};

const question_cols = colref.cols(Question);

// ---------------------------------------------------------------- 校验 / 规范化

pub const ValidationError = error{
    BadType, // type 不在 single/multi/judge
    BadStem, // 题干为空或超长
    BadOptions, // 选项数量/内容/长度不合规
    BadAnswer, // 答案与题型/选项数不匹配
    BadExplanation, // 解析超长
    BadDifficulty, // 不在 1-5
};

/// 注：validateQuestion 可能附加 OOM 类错误，而入参多为 anyerror，无法穷举
/// ValidationError，故兼用 else 兑底（新增校验错误时需补对应 prong）。
pub fn validationMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.BadType => "题型仅支持 single/multi/judge",
        error.BadStem => "题干不能为空且最长 4000 字符",
        error.BadOptions => "选项需 2-12 个且每个非空、最长 500 字符",
        error.BadAnswer => "答案格式不正确（单选 1 个选项字母；多选至少 2 个；判断为 T/F）",
        error.BadExplanation => "解析最长 8000 字符",
        error.BadDifficulty => "难度需在 1-5 之间",
        else => "题目内容不合法",
    };
}

/// 已通过校验、可直接入库的题面
pub const Canonical = struct {
    category_id: i64,
    course_id: i64,
    type: []const u8,
    stem: []const u8,
    /// JSON 字符串数组，可直接落库
    options_json: []const u8,
    /// 规范化答案
    answer: []const u8,
    explanation: []const u8,
    difficulty: i64,
};

pub const QuestionInput = struct {
    category_id: i64 = 0,
    course_id: i64 = 0,
    type: []const u8 = "",
    stem: []const u8 = "",
    options: []const []const u8 = &.{},
    answer: []const u8 = "",
    explanation: []const u8 = "",
    difficulty: i64 = 2,
};

pub fn validType(t: []const u8) bool {
    for (valid_types) |v| {
        if (std.mem.eql(u8, t, v)) return true;
    }
    return false;
}

fn letterIdx(c: u8) ?u8 {
    return if (c >= 'A' and c <= 'Z') c - 'A' else null;
}

/// 把字母集合展开为升序字母串，写入调用方提供的 buf（避免跨帧悬垂）。
pub fn lettersToStr(mask: [26]bool, buf: *[26]u8) []const u8 {
    var n: usize = 0;
    for (0..26) |i| {
        if (mask[i]) {
            buf[n] = 'A' + @as(u8, @intCast(i));
            n += 1;
        }
    }
    return buf[0..n];
}

/// 把 "a,c,b" / "ACB" / "  B " 之类的宽松输入规范为升序去重字母掩码。
/// 不做数量/越界校验（那取决于题型与选项数）。
pub fn normalizeLetters(answer: []const u8) [26]bool {
    var mask: [26]bool = @splat(false);
    for (answer) |c| {
        const up = std.ascii.toUpper(c);
        if (letterIdx(up)) |i| mask[i] = true;
    }
    return mask;
}

/// 入库前的严格校验 + 规范化。失败返回带语义的 ValidationError，由 handler 映射成 400 文案。
pub fn validateQuestion(a: std.mem.Allocator, in: QuestionInput) !Canonical {
    if (!validType(in.type)) return error.BadType;
    if (in.stem.len == 0 or in.stem.len > max_stem_len) return error.BadStem;
    if (in.explanation.len > max_explanation_len) return error.BadExplanation;
    if (in.difficulty < 1 or in.difficulty > 5) return error.BadDifficulty;

    // judge：选项固定空，答案 T/F（宽松接受 true/false，大小写随意）
    if (std.mem.eql(u8, in.type, "judge")) {
        // 不用 upperString：定长栈缓冲对超长输入会 debug assert，逐字比较即可
        const ans: []const u8 = if (std.ascii.eqlIgnoreCase(in.answer, "T") or std.ascii.eqlIgnoreCase(in.answer, "TRUE"))
            "T"
        else if (std.ascii.eqlIgnoreCase(in.answer, "F") or std.ascii.eqlIgnoreCase(in.answer, "FALSE"))
            "F"
        else
            return error.BadAnswer;
        return .{
            .category_id = in.category_id,
            .course_id = in.course_id,
            .type = "judge",
            .stem = in.stem,
            .options_json = "[]",
            .answer = ans,
            .explanation = in.explanation,
            .difficulty = in.difficulty,
        };
    }

    // single / multi：选项数量与内容
    if (in.options.len < min_options or in.options.len > max_options) return error.BadOptions;
    for (in.options) |opt| {
        if (opt.len == 0 or opt.len > max_option_len) return error.BadOptions;
    }
    const mask = normalizeLetters(in.answer);
    var str_buf: [26]u8 = undefined;
    const letters = lettersToStr(mask, &str_buf);
    if (letters.len == 0) return error.BadAnswer;
    // 越界字母（超出选项个数的答案）视为非法
    for (in.options.len..26) |i| {
        if (mask[i]) return error.BadAnswer;
    }
    if (std.mem.eql(u8, in.type, "single")) {
        if (letters.len != 1) return error.BadAnswer;
    } else { // multi
        if (letters.len < 2) return error.BadAnswer;
    }

    const options_json = try encodeOptions(a, in.options);
    const answer = try a.dupe(u8, letters);
    return .{
        .category_id = in.category_id,
        .course_id = in.course_id,
        .type = in.type,
        .stem = in.stem,
        .options_json = options_json,
        .answer = answer,
        .explanation = in.explanation,
        .difficulty = in.difficulty,
    };
}

/// 学员作答的宽松规范化（判分用）：字母去重升序写入 out 并返回其切片；
/// judge 接受 T/F/TRUE/FALSE（大小写随意），返回静态串。
/// 格式非法（空答案、judge 乱填）返回 BadAnswer → handler 映射 400。
pub fn normalizeStudentAnswer(
    qtype: []const u8,
    answer: []const u8,
    out: *[26]u8,
) ValidationError![]const u8 {
    if (std.mem.eql(u8, qtype, "judge")) {
        if (std.ascii.eqlIgnoreCase(answer, "T") or std.ascii.eqlIgnoreCase(answer, "TRUE")) return "T";
        if (std.ascii.eqlIgnoreCase(answer, "F") or std.ascii.eqlIgnoreCase(answer, "FALSE")) return "F";
        return error.BadAnswer;
    }
    const mask = normalizeLetters(answer);
    const letters = lettersToStr(mask, out);
    if (letters.len == 0) return error.BadAnswer;
    return letters;
}

pub fn checkAnswer(qtype: []const u8, stored_answer: []const u8, student_answer: []const u8) ValidationError!bool {
    var buf: [26]u8 = undefined;
    const norm = try normalizeStudentAnswer(qtype, student_answer, &buf);
    return std.mem.eql(u8, norm, stored_answer);
}

// ---------------------------------------------------------------- options JSON

pub fn encodeOptions(a: std.mem.Allocator, opts: []const []const u8) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try s.write(opts);
    return buf.written();
}

pub fn decodeOptions(a: std.mem.Allocator, json_str: []const u8) ![]const []const u8 {
    if (json_str.len == 0) return &.{};
    // std.json 解析结果借用输入内存：调用方传入的可能是 zqlite Row 的临时文本
    // （Row.deinit 后悬垂），解析前先 dupe 到目标 arena。
    const owned = try a.dupe(u8, json_str);
    const parsed = std.json.parseFromSlice(std.json.Value, a, owned, .{}) catch return error.BrokenData;
    const arr = switch (parsed.value) {
        .array => |x| x,
        else => return error.BrokenData,
    };
    const out = try a.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => return error.BrokenData,
        };
    }
    return out;
}

// ---------------------------------------------------------------- CRUD

pub const CreateParams = struct {
    q: Canonical,
    creator_id: i64,
    now: i64,
};

pub fn create(dbh: *db.Db, p: CreateParams) !i64 {
    try dbh.exec(
        "INSERT INTO questions (category_id, course_id, type, stem, options, answer, explanation, difficulty, creator_id, created_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        .{ p.q.category_id, p.q.course_id, p.q.type, p.q.stem, p.q.options_json, p.q.answer, p.q.explanation, p.q.difficulty, p.creator_id, p.now },
    );
    return dbh.lastInsertId();
}

pub fn update(dbh: *db.Db, id: i64, q: Canonical) !void {
    try dbh.conn.exec(
        "UPDATE questions SET category_id=?1, course_id=?2, type=?3, stem=?4, options=?5, answer=?6, explanation=?7, difficulty=?8 WHERE id=?9 AND deleted=0",
        .{ q.category_id, q.course_id, q.type, q.stem, q.options_json, q.answer, q.explanation, q.difficulty, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE questions SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

fn rowToQuestion(row: zqlite.Row, a: std.mem.Allocator) !Question {
    return .{
        .id = row.int(0),
        .category_id = row.int(1),
        .course_id = row.int(2),
        .type = try a.dupe(u8, row.text(3)),
        .stem = try a.dupe(u8, row.text(4)),
        .options = try decodeOptions(a, row.text(5)),
        .answer = try a.dupe(u8, row.text(6)),
        .explanation = try a.dupe(u8, row.text(7)),
        .difficulty = row.int(8),
        .used_count = row.int(9),
    };
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Question {
    const row = try dbh.conn.row("SELECT " ++ question_cols ++ " FROM questions WHERE id = ?1 AND deleted = 0 LIMIT 1", .{id});
    const r = row orelse return null;
    defer r.deinit();
    return try rowToQuestion(r, a);
}

pub fn getByIdIncludingDeleted(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Question {
    const row = try dbh.conn.row("SELECT " ++ question_cols ++ " FROM questions WHERE id = ?1 LIMIT 1", .{id});
    const r = row orelse return null;
    defer r.deinit();
    return try rowToQuestion(r, a);
}

pub const ListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    category_id: i64 = 0,
    course_id: i64 = -1, // -1 = 不过滤；0 = 只看公共题
    type: []const u8 = "",
    difficulty: i64 = 0, // 0 = 不过滤
    keyword: []const u8 = "",
    /// true = category_id 按分类子树过滤（配合递归 CTE）
    include_subtree: bool = false,
};

fn likePattern(a: std.mem.Allocator, kw: []const u8) ![]const u8 {
    // 转义 LIKE 元字符，避免 keyword 里的 %/_ 变成通配
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

const list_where =
    "(?1 = 0 OR category_id = ?1) AND (?2 = -1 OR course_id = ?2) AND " ++
    "(?3 = '' OR type = ?3) AND (?4 = 0 OR difficulty = ?4) AND " ++
    "(?5 = '' OR stem LIKE ?6 ESCAPE '\\') AND deleted = 0";

// 子树过滤用 SQLite 递归 CTE：各套 SQL 全部在 comptime 拼成常量（参数个数一致 ?1..?8），
// 运行时只做常量选择。根分类绑 ?1；depth < 20 防 categories 父子环时无限递归。
const cte_subtree =
    "WITH RECURSIVE sub(id, depth) AS (" ++
    " SELECT ?1, 0" ++
    " UNION ALL" ++
    " SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id" ++
    " WHERE c.deleted = 0 AND s.depth < 20) ";

const list_where_subtree =
    "(?1 = 0 OR category_id IN (SELECT id FROM sub)) AND (?2 = -1 OR course_id = ?2) AND " ++
    "(?3 = '' OR type = ?3) AND (?4 = 0 OR difficulty = ?4) AND " ++
    "(?5 = '' OR stem LIKE ?6 ESCAPE '\\') AND deleted = 0";

const order_limit = " ORDER BY id DESC LIMIT ?7 OFFSET ?8";

const count_exact = "SELECT COUNT(*) FROM questions WHERE " ++ list_where;
const count_subtree = cte_subtree ++ "SELECT COUNT(*) FROM questions WHERE " ++ list_where_subtree;
const rows_exact = "SELECT " ++ question_cols ++ " FROM questions WHERE " ++ list_where ++ order_limit;
const rows_subtree = cte_subtree ++ "SELECT " ++ question_cols ++ " FROM questions WHERE " ++ list_where_subtree ++ order_limit;

/// 分类维度题目计数（不含软删）。category_id=0 表示未分类。
pub const CategoryCount = struct {
    category_id: i64,
    count: i64,
};

pub fn countByCategory(dbh: *db.Db, a: std.mem.Allocator) ![]CategoryCount {
    var items: std.ArrayList(CategoryCount) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT category_id, COUNT(*) FROM questions WHERE deleted = 0 GROUP BY category_id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{ .category_id = row.int(0), .count = row.int(1) });
    }
    if (rows.err) |e| return e;
    return items.items;
}

pub fn list(dbh: *db.Db, a: std.mem.Allocator, opts: ListOpts) !QuestionList {
    const like = try likePattern(a, opts.keyword);
    const total = (try dbh.scalarInt(
        if (opts.include_subtree) count_subtree else count_exact,
        .{ opts.category_id, opts.course_id, opts.type, opts.difficulty, opts.keyword, like },
    )) orelse 0;
    var items: std.ArrayList(Question) = .empty;
    var rows = try dbh.conn.rows(
        if (opts.include_subtree) rows_subtree else rows_exact,
        .{ opts.category_id, opts.course_id, opts.type, opts.difficulty, opts.keyword, like, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToQuestion(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 抽题 / 计数

/// 抽题。random_order=true 用 RANDOM()（随机练习）；false 按 id 升序（章节练习顺序刷）。
/// 注意：抽到的题面不含答案，由 handler 转成 PracticeQuestion 输出。
pub const DrawnQuestion = struct {
    id: i64,
    type: []const u8,
    stem: []const u8,
    options: []const []const u8,
};

const draw_head_exact = "SELECT id, type, stem, options FROM questions WHERE (?1 = 0 OR category_id = ?1) AND deleted = 0";
const draw_head_sub =
    "WITH RECURSIVE sub(id, depth) AS (" ++
    " SELECT ?1, 0" ++
    " UNION ALL" ++
    " SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id" ++
    " WHERE c.deleted = 0 AND s.depth < 20) " ++
    "SELECT id, type, stem, options FROM questions WHERE category_id IN (SELECT id FROM sub) AND deleted = 0";
const draw_tail_rand = " ORDER BY RANDOM() LIMIT ?2";
const draw_tail_seq = " ORDER BY id ASC LIMIT ?2";

// ++ 是编译期拼接，运行时只选常量
const draw_sql_exact_rand = draw_head_exact ++ draw_tail_rand;
const draw_sql_exact_seq = draw_head_exact ++ draw_tail_seq;
const draw_sql_sub_rand = draw_head_sub ++ draw_tail_rand;
const draw_sql_sub_seq = draw_head_sub ++ draw_tail_seq;

/// category_id=0 全量；subtree=false 精确匹配分类（?1=0 即全量），true 含所有子孙分类（按专业子树抽题）
pub fn drawForPractice(
    dbh: *db.Db,
    a: std.mem.Allocator,
    category_id: i64,
    subtree: bool,
    random_order: bool,
    count: i64,
) ![]DrawnQuestion {
    var items: std.ArrayList(DrawnQuestion) = .empty;
    const use_sub = subtree and category_id > 0;
    const sql = if (use_sub)
        (if (random_order) draw_sql_sub_rand else draw_sql_sub_seq)
    else
        (if (random_order) draw_sql_exact_rand else draw_sql_exact_seq);
    var rows = try dbh.conn.rows(sql, .{ @max(category_id, 0), count });
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{
            .id = row.int(0),
            .type = try a.dupe(u8, row.text(1)),
            .stem = try a.dupe(u8, row.text(2)),
            .options = try decodeOptions(a, row.text(3)),
        });
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

/// 抽中后使用次数 +1。≤50 条逐条 UPDATE（单连接事务内，无性能问题）。
pub fn bumpUsed(dbh: *db.Db, ids: []const i64) !void {
    for (ids) |id| {
        try dbh.exec("UPDATE questions SET used_count = used_count + 1 WHERE id = ?1", .{id});
    }
}

// ---------------------------------------------------------------- 批量导入 CSV

/// RFC4180 子集解析：逗号分隔、双引号包裹、"" 转义、\r\n / \n 行尾。
/// 返回行×列（字段 dupe 到 a）。空文本 → 空列表。
pub const CsvRow = [][]const u8;

pub fn parseCsv(a: std.mem.Allocator, text: []const u8) ![]CsvRow {
    var rows: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var field_buf: std.ArrayList(u8) = .empty;
    var cur_row: std.ArrayList([]const u8) = .empty;
    var in_quotes = false;
    // RFC4180：引号只在字段开头有意义；字段中间的引号按字面量处理
    var at_field_start = true;
    var i: usize = 0;

    const endField = struct {
        fn f(alloc: std.mem.Allocator, fb: *std.ArrayList(u8), row: *std.ArrayList([]const u8)) !void {
            try row.append(alloc, try fb.toOwnedSlice(alloc));
        }
    }.f;
    const endRow = struct {
        fn f(alloc: std.mem.Allocator, fb: *std.ArrayList(u8), row: *std.ArrayList([]const u8), out: *std.ArrayList(std.ArrayList([]const u8))) !void {
            if (fb.items.len > 0 or row.items.len > 0) {
                try endField(alloc, fb, row);
                try out.append(alloc, row.*);
                row.* = .empty;
            }
        }
    }.f;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_quotes) {
            switch (c) {
                '"' => {
                    if (i + 1 < text.len and text[i + 1] == '"') {
                        try field_buf.append(a, '"');
                        i += 1;
                    } else in_quotes = false;
                },
                else => try field_buf.append(a, c),
            }
            continue;
        }
        switch (c) {
            '"' => {
                if (at_field_start) {
                    in_quotes = true;
                    at_field_start = false;
                } else {
                    try field_buf.append(a, '"'); // 非开头的引号：字面量
                }
            },
            ',' => {
                try endField(a, &field_buf, &cur_row);
                at_field_start = true;
            },
            '\r' => {}, // 交给紧随的 \n；单独的 \r 忽略
            '\n' => {
                try endRow(a, &field_buf, &cur_row, &rows);
                at_field_start = true;
            },
            else => {
                try field_buf.append(a, c);
                at_field_start = false;
            },
        }
    }
    if (in_quotes) return error.CsvSyntax; // 引号不闭合
    try endRow(a, &field_buf, &cur_row, &rows);
    // 行缓冲所有权直接移交（字段均 alloc 自 a，行表随 a 失效）
    const out = try a.alloc(CsvRow, rows.items.len);
    for (rows.items, 0..) |*r, idx| out[idx] = r.items;
    return out;
}

// ---------------------------------------------------------------------------

test "validateQuestion single/multi/judge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opts = [_][]const u8{ "甲", "乙", "丙", "丁" };
    const single = try validateQuestion(a, .{ .category_id = 1, .type = "single", .stem = "S?", .options = &opts, .answer = " b " });
    // single 答案给 "b" → 规范化 "B"
    try std.testing.expectEqualStrings("B", single.answer);
    try std.testing.expectEqualStrings("[\"甲\",\"乙\",\"丙\",\"丁\"]", single.options_json);

    // 多选乱序/重复 → 升序去重
    const multi = try validateQuestion(a, .{ .category_id = 1, .type = "multi", .stem = "S?", .options = &opts, .answer = "dbb, a" });
    try std.testing.expectEqualStrings("ABD", multi.answer);

    const judge = try validateQuestion(a, .{ .category_id = 1, .type = "judge", .stem = "S?", .answer = "true" });
    try std.testing.expectEqualStrings("T", judge.answer);
    try std.testing.expectEqualStrings("[]", judge.options_json);

    // 错误用例
    try std.testing.expectError(error.BadType, validateQuestion(a, .{ .type = "fill", .stem = "S?" }));
    try std.testing.expectError(error.BadStem, validateQuestion(a, .{ .type = "single", .stem = "" }));
    try std.testing.expectError(error.BadOptions, validateQuestion(a, .{ .type = "single", .stem = "S", .options = &[_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m" } }));
    try std.testing.expectError(error.BadAnswer, validateQuestion(a, .{ .category_id = 1, .type = "single", .stem = "S?", .options = &opts, .answer = "AC" }));
    try std.testing.expectError(error.BadAnswer, validateQuestion(a, .{ .category_id = 1, .type = "multi", .stem = "S?", .options = &opts, .answer = "A" }));
    try std.testing.expectError(error.BadAnswer, validateQuestion(a, .{ .category_id = 1, .type = "single", .stem = "S?", .options = &opts, .answer = "E" })); // 越界字母
    try std.testing.expectError(error.BadAnswer, validateQuestion(a, .{ .type = "judge", .stem = "S?", .answer = "X" }));
    try std.testing.expectError(error.BadDifficulty, validateQuestion(a, .{ .type = "judge", .stem = "S?", .answer = "T", .difficulty = 9 }));
}

test "checkAnswer grading" {
    try std.testing.expect(try checkAnswer("single", "B", "b"));
    try std.testing.expect(!(try checkAnswer("single", "B", "A")));
    try std.testing.expect(try checkAnswer("multi", "ABD", "d,a,b"));
    try std.testing.expect(!(try checkAnswer("multi", "ABD", "ab"))); // 漏选 → 错（严格集相等）
    try std.testing.expect(try checkAnswer("judge", "F", "false"));
    try std.testing.expectError(error.BadAnswer, checkAnswer("judge", "F", ""));
    try std.testing.expectError(error.BadAnswer, checkAnswer("multi", "AB", "!!"));
}

test "encodeOptions/decodeOptions round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = [_][]const u8{ "选项\"一\"", "a,b", "换行\n", "正常" };
    const json_str = try encodeOptions(a, &opts);
    const back = try decodeOptions(a, json_str);
    try std.testing.expectEqual(opts.len, back.len);
    for (opts, back) |o, b| try std.testing.expectEqualStrings(o, b);
}

test "parseCsv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = try parseCsv(a, "type,stem,answer\r\nsingle,他说: \"对,不对\",A\nmulti,\"带\n换行\",\"x|y\",BD\n");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].len);
    try std.testing.expectEqualStrings("single,他说: \"对,不对\",A", std.mem.join(a, ",", rows[1]) catch unreachable);
    try std.testing.expectEqualStrings("带\n换行", rows[2][1]);
    try std.testing.expectEqualStrings("x|y", rows[2][2]);

    try std.testing.expectError(error.CsvSyntax, parseCsv(a, "a,\"unclosed"));
    try std.testing.expectEqual(@as(usize, 0), (try parseCsv(a, "")).len);
}

// ---------------------------------------------------------------- 集成测试用 DDL

const questions_ddl =
    \\CREATE TABLE IF NOT EXISTS questions (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  category_id INTEGER NOT NULL DEFAULT 0,
    \\  course_id INTEGER NOT NULL DEFAULT 0,
    \\  type TEXT NOT NULL,
    \\  stem TEXT NOT NULL,
    \\  options TEXT NOT NULL DEFAULT '[]',
    \\  answer TEXT NOT NULL,
    \\  explanation TEXT NOT NULL DEFAULT '',
    \\  difficulty INTEGER NOT NULL DEFAULT 2,
    \\  used_count INTEGER NOT NULL DEFAULT 0,
    \\  creator_id INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
;

pub const test_sqls = course_repo.test_sqls ++ [_][]const u8{questions_ddl};

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

test "question_repo CRUD / list / draw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/question_repo_test.db");
    defer dbh.close();
    const now: i64 = 1_760_000_000;

    const opts = [_][]const u8{ "甲", "乙", "丙", "丁" };
    const c1 = try validateQuestion(a, .{ .category_id = 7, .type = "single", .stem = "1+1=?", .options = &opts, .answer = "B" });
    const id1 = try create(&dbh, .{ .q = c1, .creator_id = 1, .now = now });
    const c2 = try validateQuestion(a, .{ .category_id = 7, .type = "multi", .course_id = 5, .stem = "2+2=?", .options = &opts, .answer = "AC", .difficulty = 4 });
    _ = try create(&dbh, .{ .q = c2, .creator_id = 1, .now = now });

    const q = (try getById(&dbh, a, id1)).?;
    try std.testing.expectEqualStrings("B", q.answer);
    try std.testing.expectEqual(@as(usize, 4), q.options.len);

    // update：答案与难度变更
    const c3 = try validateQuestion(a, .{ .category_id = 7, .type = "single", .stem = "1+1=?", .options = &opts, .answer = "C", .difficulty = 3 });
    try update(&dbh, id1, c3);
    try std.testing.expectEqualStrings("C", (try getById(&dbh, a, id1)).?.answer);

    // list：按分类 + 关键字过滤
    const l1 = try list(&dbh, a, .{ .category_id = 7 });
    try std.testing.expectEqual(@as(i64, 2), l1.total);
    const l2 = try list(&dbh, a, .{ .keyword = "2+" });
    try std.testing.expectEqual(@as(i64, 1), l2.total);
    const l3 = try list(&dbh, a, .{ .course_id = 5 });
    try std.testing.expectEqual(@as(i64, 1), l3.total);
    const l4 = try list(&dbh, a, .{ .type = "single" });
    try std.testing.expectEqual(@as(i64, 1), l4.total);

    // 分类树 10 -> 11 -> 12，子树过滤（新题挂 cat 11）
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (10, 0, '根'), (11, 10, '子'), (12, 11, '孙')", .{});
    const csub = try validateQuestion(a, .{ .category_id = 11, .type = "judge", .stem = "3+3=6?", .answer = "T" });
    _ = try create(&dbh, .{ .q = csub, .creator_id = 1, .now = now });
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .category_id = 10 })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 10, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 11, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .category_id = 12, .include_subtree = true })).total);
    // 子树 + 其它过滤条件叠加
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 10, .include_subtree = true, .type = "judge" })).total);
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .category_id = 10, .include_subtree = true, .type = "single" })).total);

    // 抽题：章节顺序抽（id 升序）；随机抽也在池内；used_count 联动
    const drawn = try drawForPractice(&dbh, a, 7, false, false, 10);
    try std.testing.expectEqual(@as(usize, 2), drawn.len);
    try std.testing.expect(drawn[0].id < drawn[1].id);
    try std.testing.expectEqualStrings("C", (try getById(&dbh, a, id1)).?.answer); // 抽题不影响答案列
    var ids: [2]i64 = .{ drawn[0].id, drawn[1].id };
    try bumpUsed(&dbh, &ids);
    try std.testing.expectEqual(@as(i64, 1), (try getById(&dbh, a, id1)).?.used_count);
    // 题池不足时返回现有全部
    try std.testing.expectEqual(@as(usize, 2), (try drawForPractice(&dbh, a, 7, false, true, 99)).len);
    try std.testing.expectEqual(@as(usize, 0), (try drawForPractice(&dbh, a, 999, false, false, 5)).len);
    // 子树抽题：cat 在根分类子树内应能抽到；category_id=0 全量
    try std.testing.expect((try drawForPractice(&dbh, a, 7, true, false, 10)).len > 0);
    try std.testing.expect((try drawForPractice(&dbh, a, 0, false, false, 10)).len > 0);

    // 软删：列表/抽题/详情全部隐身
    try deleteSoft(&dbh, id1);
    try std.testing.expect((try getById(&dbh, a, id1)) == null);
    try std.testing.expect((try getByIdIncludingDeleted(&dbh, a, id1)) != null);
    try std.testing.expectEqual(@as(usize, 1), (try drawForPractice(&dbh, a, 7, false, false, 10)).len);

    // 分类计数（未删）：cat7 只剩多选题 1 道，cat11 判断题 1 道
    const stats = try countByCategory(&dbh, a);
    var found = std.AutoHashMap(i64, i64).init(a);
    defer found.deinit();
    for (stats) |s| try found.put(s.category_id, s.count);
    try std.testing.expectEqual(@as(?i64, 1), found.get(7));
    try std.testing.expectEqual(@as(?i64, 1), found.get(11));
    try std.testing.expectEqual(@as(?i64, null), found.get(10));
}
