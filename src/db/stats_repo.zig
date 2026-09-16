//! 后台首页统计（M-H H1）：基础版聚合计数。
//!
//! 口径：courses/questions 排除软删；orders_pending 为待支付订单数；
//! users_today / users_7d 按 UTC 日历日（与 study_logs 归日口径一致）：
//! 7 日 = 含今日在内最近 7 个完整 UTC 日窗口的起点。

const std = @import("std");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");

pub const Overview = struct {
    users: i64,
    courses: i64,
    questions: i64,
    orders_pending: i64,
    users_today: i64,
    users_7d: i64,
};

const day_sec: i64 = 24 * 3600;

pub fn overview(dbh: *db.Db, now: i64) !Overview {
    const today_start = @divTrunc(now, day_sec) * day_sec;
    const w7_start = today_start - 6 * day_sec;
    return .{
        .users = (try dbh.scalarInt("SELECT COUNT(*) FROM users", .{})) orelse 0,
        .courses = (try dbh.scalarInt("SELECT COUNT(*) FROM courses WHERE deleted = 0", .{})) orelse 0,
        .questions = (try dbh.scalarInt("SELECT COUNT(*) FROM questions WHERE deleted = 0", .{})) orelse 0,
        .orders_pending = (try dbh.scalarInt("SELECT COUNT(*) FROM orders WHERE status = 'pending'", .{})) orelse 0,
        .users_today = (try dbh.scalarInt("SELECT COUNT(*) FROM users WHERE created_at >= ?1", .{today_start})) orelse 0,
        .users_7d = (try dbh.scalarInt("SELECT COUNT(*) FROM users WHERE created_at >= ?1", .{w7_start})) orelse 0,
    };
}

// ---------------------------------------------------------------- 集成测试

const users_ddl =
    \\CREATE TABLE IF NOT EXISTS users (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  email TEXT NOT NULL UNIQUE,
    \\  username TEXT NOT NULL UNIQUE,
    \\  password_hash TEXT NOT NULL,
    \\  nickname TEXT NOT NULL DEFAULT '',
    \\  avatar TEXT NOT NULL DEFAULT '',
    \\  role TEXT NOT NULL DEFAULT 'student',
    \\  status TEXT NOT NULL DEFAULT 'active',
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\)
;

const orders_ddl =
    \\CREATE TABLE IF NOT EXISTS orders (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  order_no TEXT NOT NULL UNIQUE,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL,
    \\  amount INTEGER NOT NULL DEFAULT 0,
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  pay_method TEXT NOT NULL DEFAULT '',
    \\  remark TEXT NOT NULL DEFAULT '',
    \\  operator_id INTEGER NOT NULL DEFAULT 0,
    \\  paid_at INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
;

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

pub const test_sqls = course_repo.test_sqls ++ [_][]const u8{ users_ddl, orders_ddl, questions_ddl };

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

test "stats_repo overview counts with UTC-day windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/crm_stats_test.db");
    defer dbh.close();

    // 固定到某 UTC 正午，避开跨日抖动
    const now: i64 = 1_758_000_000; // 2025-09-16 ~06:40 UTC（任意秒也行，只需确定）
    const day: i64 = 24 * 3600;

    // 3 用户：今日 1、7 日窗口内 1、窗口外 1
    try dbh.exec("INSERT INTO users (email, username, password_hash, created_at, updated_at) VALUES ('a', 'a', 'h', ?1, ?1)", .{now});
    try dbh.exec("INSERT INTO users (email, username, password_hash, created_at, updated_at) VALUES ('b', 'b', 'h', ?1, ?1)", .{now - day});
    try dbh.exec("INSERT INTO users (email, username, password_hash, created_at, updated_at) VALUES ('c', 'c', 'h', ?1, ?1)", .{now - 10 * day});
    try dbh.exec("INSERT INTO orders (order_no, user_id, course_id, amount, status, created_at) VALUES ('O1', 1, 1, 10, 'pending', ?1)", .{now});
    try dbh.exec("INSERT INTO orders (order_no, user_id, course_id, amount, status, created_at) VALUES ('O2', 1, 2, 10, 'paid', ?1)", .{now});
    try dbh.exec("INSERT INTO questions (type, stem, answer, deleted, created_at) VALUES ('single', 'q1', 'A', 0, ?1)", .{now});
    try dbh.exec("INSERT INTO questions (type, stem, answer, deleted, created_at) VALUES ('single', 'q2', 'A', 1, ?1)", .{now});
    try dbh.exec("INSERT INTO courses (title, status, deleted, created_at, updated_at) VALUES ('c1', 'published', 0, 1, 1)", .{});
    try dbh.exec("INSERT INTO courses (title, status, deleted, created_at, updated_at) VALUES ('c2', 'published', 1, 1, 1)", .{});

    const ov = try overview(&dbh, now);
    try std.testing.expectEqual(@as(i64, 3), ov.users);
    try std.testing.expectEqual(@as(i64, 1), ov.courses);
    try std.testing.expectEqual(@as(i64, 1), ov.questions);
    try std.testing.expectEqual(@as(i64, 1), ov.orders_pending);
    // 固定时钟下手算 UTC 日窗口：today=1 人，7 日窗口=2 人（10 天前的在窗口外）
    try std.testing.expectEqual(@as(i64, 1), ov.users_today);
    try std.testing.expectEqual(@as(i64, 2), ov.users_7d);
}

test {
    std.testing.refAllDecls(@This());
}
