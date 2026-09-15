//! 练习域（M-D）：答题记录、错题本、题目收藏。
//!
//! 判分在 handler 侧用 question_repo.checkAnswer 完成后调本 repo 落库：
//! 一次作答 = practice_records 流水 + wrong_questions 状态机（答错进本/重错计数、
//! 答对从本移除即 mastered=1，符合 D4「答对可从错题本移除」语义）。
//!
//! practice_records.session_id：练习场景恒为 0（章节/随机练习无会话实体，
//! 见 plan.md 第 3 节约定）；考试场景 = exam_attempts.id（第 5 期 M-E 已接入，
//! 由 exam_repo.finishAttempt 在同一事务内经 insertRecord 写入）。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const question_repo = @import("question_repo.zig");

pub const valid_sources = [_][]const u8{ "chapter", "random", "exam" };

pub fn validSource(s: []const u8) bool {
    for (valid_sources) |v| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

pub const SubmitParams = struct {
    user_id: i64,
    question_id: i64,
    is_correct: bool,
    duration: i64,
    source: []const u8,
    now: i64,
    /// 会话归属：练习=0，考试=exam_attempts.id
    session_id: i64 = 0,
};

/// 作答落库（事务）：流水 + 错题本状态。返回错题本当前状态。
pub const SubmitOutcome = struct {
    /// 是否在错题本中（mastered=0 的未掌握错题才算「在」）
    in_wrong_book: bool,
    wrong_count: i64,
};

/// 仅流水行（不含错题本状态）。考试判分需要「只记流水不碰错题本」的空卷分支，
/// 故拆出此原语；recordAnswer 与 exam_repo 共用。
pub fn insertRecord(dbh: *db.Db, p: SubmitParams) !void {
    try dbh.exec(
        "INSERT INTO practice_records (user_id, question_id, is_correct, duration, source, session_id, created_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        .{ p.user_id, p.question_id, @as(i64, if (p.is_correct) 1 else 0), p.duration, p.source, p.session_id, p.now },
    );
}

/// 错题本状态机（须在调用方事务内）：答对→已掌握（不动 wrong_count，保留历史
/// 错误次数）；答错→进本/重错计数 +1 并重置掌握状态。
pub fn applyWrongBook(dbh: *db.Db, user_id: i64, question_id: i64, is_correct: bool, now: i64) !void {
    if (is_correct) {
        try dbh.exec(
            "UPDATE wrong_questions SET mastered = 1 WHERE user_id = ?1 AND question_id = ?2 AND mastered = 0",
            .{ user_id, question_id },
        );
    } else {
        try dbh.exec(
            "INSERT INTO wrong_questions (user_id, question_id, wrong_count, mastered, last_wrong_at) " ++
                "VALUES (?1, ?2, 1, 0, ?3) " ++
                "ON CONFLICT(user_id, question_id) DO UPDATE SET " ++
                "wrong_count = wrong_count + 1, mastered = 0, last_wrong_at = excluded.last_wrong_at",
            .{ user_id, question_id, now },
        );
    }
}

/// 事务内读错题本当前状态（供 SubmitOutcome）。
fn wrongBookState(dbh: *db.Db, user_id: i64, question_id: i64) !SubmitOutcome {
    var outcome = SubmitOutcome{ .in_wrong_book = false, .wrong_count = 0 };
    const row = try dbh.conn.row(
        "SELECT wrong_count, mastered FROM wrong_questions WHERE user_id = ?1 AND question_id = ?2 LIMIT 1",
        .{ user_id, question_id },
    );
    if (row) |r| {
        defer r.deinit();
        outcome.wrong_count = r.int(0);
        outcome.in_wrong_book = r.int(1) == 0;
    }
    return outcome;
}

pub fn recordAnswer(dbh: *db.Db, p: SubmitParams) !SubmitOutcome {
    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try insertRecord(dbh, p);
    try applyWrongBook(dbh, p.user_id, p.question_id, p.is_correct, p.now);
    try dbh.exec("COMMIT", .{});

    return wrongBookState(dbh, p.user_id, p.question_id);
}

// ---------------------------------------------------------------- 错题本

pub const WrongItem = struct {
    id: i64,
    wrong_count: i64,
    mastered: i64,
    last_wrong_at: i64,
    question: question_repo.Question,
};

pub const WrongList = struct {
    items: std.ArrayList(WrongItem),
    total: i64,
};

/// mastered_filter: -1=全部, 0=未掌握, 1=已掌握。
/// 题目被软删后 JOIN 自动过滤（错题本不展示已删题）。
pub fn listWrong(
    dbh: *db.Db,
    a: std.mem.Allocator,
    user_id: i64,
    mastered_filter: i64,
    page: i64,
    size: i64,
) !WrongList {
    const cond = "w.user_id = ?1 AND (?2 = -1 OR w.mastered = ?2) AND q.deleted = 0";
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM wrong_questions w JOIN questions q ON q.id = w.question_id WHERE " ++ cond,
        .{ user_id, mastered_filter },
    )) orelse 0;

    var items: std.ArrayList(WrongItem) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT w.id, w.wrong_count, w.mastered, w.last_wrong_at, " ++
            "q.id, q.category_id, q.course_id, q.type, q.stem, q.options, q.answer, q.explanation, q.difficulty, q.used_count " ++
            "FROM wrong_questions w JOIN questions q ON q.id = w.question_id WHERE " ++ cond ++
            " ORDER BY w.last_wrong_at DESC, w.id DESC LIMIT ?3 OFFSET ?4",
        .{ user_id, mastered_filter, size, (page - 1) * size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{
            .id = row.int(0),
            .wrong_count = row.int(1),
            .mastered = row.int(2),
            .last_wrong_at = row.int(3),
            .question = try rowToQuestion(row, a),
        });
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

/// 行内列 4..13 起为题目列（同 question_repo 的 question_cols 顺序）
fn rowToQuestion(row: zqlite.Row, a: std.mem.Allocator) !question_repo.Question {
    return .{
        .id = row.int(4),
        .category_id = row.int(5),
        .course_id = row.int(6),
        .type = try a.dupe(u8, row.text(7)),
        .stem = try a.dupe(u8, row.text(8)),
        .options = try question_repo.decodeOptions(a, row.text(9)),
        .answer = try a.dupe(u8, row.text(10)),
        .explanation = try a.dupe(u8, row.text(11)),
        .difficulty = row.int(12),
        .used_count = row.int(13),
    };
}

/// 标记已掌握。返回 false = 该错题记录不存在（或不属于该用户）。幂等。
pub fn masterWrong(dbh: *db.Db, user_id: i64, wrong_id: i64) !bool {
    const exists = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM wrong_questions WHERE id = ?1 AND user_id = ?2",
        .{ wrong_id, user_id },
    )) orelse 0;
    if (exists == 0) return false;
    try dbh.exec("UPDATE wrong_questions SET mastered = 1 WHERE id = ?1 AND user_id = ?2", .{ wrong_id, user_id });
    return true;
}

// ---------------------------------------------------------------- 题目收藏

/// 收藏切换。返回 true = 切换后已收藏。
pub fn toggleFavorite(dbh: *db.Db, user_id: i64, question_id: i64, now: i64) !bool {
    const exists = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM question_favorites WHERE user_id = ?1 AND question_id = ?2",
        .{ user_id, question_id },
    )) orelse 0;
    if (exists > 0) {
        try dbh.exec("DELETE FROM question_favorites WHERE user_id = ?1 AND question_id = ?2", .{ user_id, question_id });
        return false;
    }
    try dbh.exec("INSERT INTO question_favorites (user_id, question_id, created_at) VALUES (?1, ?2, ?3)", .{ user_id, question_id, now });
    return true;
}

pub const FavoriteItem = struct {
    id: i64,
    created_at: i64,
    question: question_repo.Question,
};

pub const FavoriteList = struct {
    items: std.ArrayList(FavoriteItem),
    total: i64,
};

pub fn listFavorites(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, page: i64, size: i64) !FavoriteList {
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM question_favorites f JOIN questions q ON q.id = f.question_id WHERE f.user_id = ?1 AND q.deleted = 0",
        .{user_id},
    )) orelse 0;
    var items: std.ArrayList(FavoriteItem) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT f.id, f.created_at, " ++
            "q.id, q.category_id, q.course_id, q.type, q.stem, q.options, q.answer, q.explanation, q.difficulty, q.used_count " ++
            "FROM question_favorites f JOIN questions q ON q.id = f.question_id WHERE f.user_id = ?1 AND q.deleted = 0 " ++
            "ORDER BY f.id DESC LIMIT ?2 OFFSET ?3",
        .{ user_id, size, (page - 1) * size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{
            .id = row.int(0),
            .created_at = row.int(1),
            .question = try rowToQuestionShift2(row, a),
        });
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

/// 行内列 2..11 起为题目列
fn rowToQuestionShift2(row: zqlite.Row, a: std.mem.Allocator) !question_repo.Question {
    return .{
        .id = row.int(2),
        .category_id = row.int(3),
        .course_id = row.int(4),
        .type = try a.dupe(u8, row.text(5)),
        .stem = try a.dupe(u8, row.text(6)),
        .options = try question_repo.decodeOptions(a, row.text(7)),
        .answer = try a.dupe(u8, row.text(8)),
        .explanation = try a.dupe(u8, row.text(9)),
        .difficulty = row.int(10),
        .used_count = row.int(11),
    };
}

// ---------------------------------------------------------------------------

test "validSource" {
    try std.testing.expect(validSource("chapter"));
    try std.testing.expect(validSource("exam"));
    try std.testing.expect(!validSource(""));
}

// ---------------------------------------------------------------- 集成测试用 DDL

const practice_ddl =
    \\CREATE TABLE IF NOT EXISTS practice_records (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  question_id INTEGER NOT NULL,
    \\  is_correct INTEGER NOT NULL,
    \\  duration INTEGER NOT NULL DEFAULT 0,
    \\  source TEXT NOT NULL,
    \\  session_id INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
;

const wrong_ddl =
    \\CREATE TABLE IF NOT EXISTS wrong_questions (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  question_id INTEGER NOT NULL,
    \\  wrong_count INTEGER NOT NULL DEFAULT 1,
    \\  mastered INTEGER NOT NULL DEFAULT 0,
    \\  last_wrong_at INTEGER NOT NULL DEFAULT 0,
    \\  UNIQUE(user_id, question_id)
    \\)
;

const fav_ddl =
    \\CREATE TABLE IF NOT EXISTS question_favorites (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  question_id INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, question_id)
    \\)
;

pub const test_sqls = question_repo.test_sqls ++ [_][]const u8{ practice_ddl, wrong_ddl, fav_ddl };

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    for (test_sqls) |sql| try dbh.exec(sql, .{});
    return dbh;
}

test "practice_repo wrong book / master / favorites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/practice_repo_test.db");
    defer dbh.close();
    const now: i64 = 1_760_000_000;

    const opts = [_][]const u8{ "甲", "乙", "丙" };
    const c1 = try question_repo.validateQuestion(a, .{ .category_id = 3, .type = "single", .stem = "Q1?", .options = &opts, .answer = "A" });
    const q1 = try question_repo.create(&dbh, .{ .q = c1, .creator_id = 1, .now = now });
    const c2 = try question_repo.validateQuestion(a, .{ .category_id = 3, .type = "judge", .stem = "Q2?", .answer = "T" });
    const q2 = try question_repo.create(&dbh, .{ .q = c2, .creator_id = 1, .now = now });

    // 答错 → 进错题本
    var o = try recordAnswer(&dbh, .{ .user_id = 9, .question_id = q1, .is_correct = false, .duration = 10, .source = "chapter", .now = now });
    try std.testing.expect(o.in_wrong_book);
    try std.testing.expectEqual(@as(i64, 1), o.wrong_count);

    // 重错 → 计数 +1；答对 → mastered=1（在列口径：mastered=0 才算在错题本）
    o = try recordAnswer(&dbh, .{ .user_id = 9, .question_id = q1, .is_correct = false, .duration = 5, .source = "random", .now = now + 1 });
    try std.testing.expectEqual(@as(i64, 2), o.wrong_count);
    o = try recordAnswer(&dbh, .{ .user_id = 9, .question_id = q1, .is_correct = true, .duration = 8, .source = "chapter", .now = now + 2 });
    try std.testing.expect(!o.in_wrong_book);
    try std.testing.expectEqual(@as(i64, 2), o.wrong_count); // 历史次数保留

    // 掌握后再次答错 → 重新进本（mastered 归 0）
    o = try recordAnswer(&dbh, .{ .user_id = 9, .question_id = q1, .is_correct = false, .duration = 3, .source = "chapter", .now = now + 3 });
    try std.testing.expect(o.in_wrong_book);
    try std.testing.expectEqual(@as(i64, 3), o.wrong_count);

    // 错题列表：默认全部；mastered=0 只剩 q1（q2 从未错，无行）
    const wl = try listWrong(&dbh, a, 9, -1, 1, 20);
    try std.testing.expectEqual(@as(i64, 1), wl.total);
    try std.testing.expectEqualStrings("Q1?", wl.items.items[0].question.stem);
    try std.testing.expectEqual(@as(i64, 0), wl.items.items[0].mastered);
    const wl0 = try listWrong(&dbh, a, 9, 0, 1, 20);
    try std.testing.expectEqual(@as(i64, 1), wl0.total);
    const wl1 = try listWrong(&dbh, a, 9, 1, 1, 20);
    try std.testing.expectEqual(@as(i64, 0), wl1.total);

    // masterWrong：标记 q1 → mastered 列表可见
    try std.testing.expect(try masterWrong(&dbh, 9, wl.items.items[0].id));
    try std.testing.expectEqual(@as(i64, 0), (try listWrong(&dbh, a, 9, 0, 1, 20)).total);
    try std.testing.expectEqual(@as(i64, 1), (try listWrong(&dbh, a, 9, 1, 1, 20)).total);
    try std.testing.expect(!(try masterWrong(&dbh, 9, 99999))); // 不存在/非本人 → false
    try std.testing.expect(!(try masterWrong(&dbh, 100, wl.items.items[0].id))); // 越权

    // 收藏切换 + 列表 + 软删联动
    try std.testing.expect(try toggleFavorite(&dbh, 9, q2, now));
    try std.testing.expect(try toggleFavorite(&dbh, 9, q1, now + 1));
    var fl = try listFavorites(&dbh, a, 9, 1, 20);
    try std.testing.expectEqual(@as(i64, 2), fl.total);
    try std.testing.expectEqual(q1, fl.items.items[0].question.id); // f.id DESC → 后收藏在前
    try std.testing.expect(!(try toggleFavorite(&dbh, 9, q2, now + 2))); // 取消
    fl = try listFavorites(&dbh, a, 9, 1, 20);
    try std.testing.expectEqual(@as(i64, 1), fl.total);

    // 题目软删后，错题本/收藏列表自动隐藏
    try question_repo.deleteSoft(&dbh, q1);
    try std.testing.expectEqual(@as(i64, 0), (try listFavorites(&dbh, a, 9, 1, 20)).total);
    try std.testing.expectEqual(@as(i64, 0), (try listWrong(&dbh, a, 9, -1, 1, 20)).total);

    // 流水计数
    try std.testing.expectEqual(@as(i64, 4), (try dbh.scalarInt("SELECT COUNT(*) FROM practice_records WHERE user_id = 9", .{})).?);
}
