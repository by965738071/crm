//! 数据库迁移 + 种子数据。
//! 版本机制：PRAGMA user_version，从 0 递增；migrations 数组只增不改。

const std = @import("std");
const db = @import("db.zig");

pub const Migration = struct { sql: []const []const u8 };

/// v1：全量建表（见 plan.md 第 6 节）
const v1 = [_][]const u8{
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
    ,
    \\CREATE TABLE IF NOT EXISTS categories (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  parent_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_categories_parent ON categories(parent_id)",
    \\CREATE TABLE IF NOT EXISTS courses (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  category_id INTEGER NOT NULL DEFAULT 0,
    \\  title TEXT NOT NULL,
    \\  cover TEXT NOT NULL DEFAULT '',
    \\  summary TEXT NOT NULL DEFAULT '',
    \\  description TEXT NOT NULL DEFAULT '',
    \\  price INTEGER NOT NULL DEFAULT 0,
    \\  is_free INTEGER NOT NULL DEFAULT 0,
    \\  status TEXT NOT NULL DEFAULT 'draft',
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  enroll_count INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_courses_category ON courses(category_id)",
    \\CREATE TABLE IF NOT EXISTS chapters (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  course_id INTEGER NOT NULL,
    \\  title TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_chapters_course ON chapters(course_id)",
    \\CREATE TABLE IF NOT EXISTS lessons (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  course_id INTEGER NOT NULL,
    \\  chapter_id INTEGER NOT NULL DEFAULT 0,
    \\  title TEXT NOT NULL,
    \\  content_type TEXT NOT NULL DEFAULT 'video',
    \\  resource_id INTEGER NOT NULL DEFAULT 0,
    \\  content TEXT NOT NULL DEFAULT '',
    \\  duration INTEGER NOT NULL DEFAULT 0,
    \\  is_free INTEGER NOT NULL DEFAULT 0,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_lessons_chapter ON lessons(chapter_id)",
    \\CREATE TABLE IF NOT EXISTS resources (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  category_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  orig_name TEXT NOT NULL DEFAULT '',
    \\  type TEXT NOT NULL,
    \\  file_path TEXT NOT NULL,
    \\  size INTEGER NOT NULL DEFAULT 0,
    \\  mime TEXT NOT NULL DEFAULT '',
    \\  uploader_id INTEGER NOT NULL DEFAULT 0,
    \\  is_public INTEGER NOT NULL DEFAULT 1,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS enrollments (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL,
    \\  source TEXT NOT NULL DEFAULT 'self',
    \\  pay_status TEXT NOT NULL DEFAULT 'unpaid',
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, course_id)
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_enrollments_user ON enrollments(user_id)",
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
    ,
    "CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id)",
    "CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status)",
    \\CREATE TABLE IF NOT EXISTS learning_progress (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  lesson_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL DEFAULT 0,
    \\  status TEXT NOT NULL DEFAULT 'not_started',
    \\  position INTEGER NOT NULL DEFAULT 0,
    \\  updated_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, lesson_id)
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS study_logs (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL DEFAULT 0,
    \\  lesson_id INTEGER NOT NULL DEFAULT 0,
    \\  seconds INTEGER NOT NULL DEFAULT 0,
    \\  date TEXT NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_study_logs_user_date ON study_logs(user_id, date)",
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
    ,
    "CREATE INDEX IF NOT EXISTS idx_questions_category ON questions(category_id)",
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
    ,
    "CREATE INDEX IF NOT EXISTS idx_practice_user_question ON practice_records(user_id, question_id)",
    \\CREATE TABLE IF NOT EXISTS wrong_questions (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  question_id INTEGER NOT NULL,
    \\  wrong_count INTEGER NOT NULL DEFAULT 1,
    \\  mastered INTEGER NOT NULL DEFAULT 0,
    \\  last_wrong_at INTEGER NOT NULL DEFAULT 0,
    \\  UNIQUE(user_id, question_id)
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS question_favorites (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  question_id INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, question_id)
    \\)
    ,
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
    ,
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
    ,
    "CREATE INDEX IF NOT EXISTS idx_attempts_user ON exam_attempts(user_id)",
    \\CREATE TABLE IF NOT EXISTS favorites (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  target_type TEXT NOT NULL,
    \\  target_id INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, target_type, target_id)
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS notes (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL DEFAULT 0,
    \\  lesson_id INTEGER NOT NULL DEFAULT 0,
    \\  content TEXT NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_notes_user_course ON notes(user_id, course_id)",
    \\CREATE TABLE IF NOT EXISTS announcements (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  title TEXT NOT NULL,
    \\  content TEXT NOT NULL DEFAULT '',
    \\  status TEXT NOT NULL DEFAULT 'draft',
    \\  author_id INTEGER NOT NULL DEFAULT 0,
    \\  published_at INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL
    \\)
    ,
};

/// v2：审计日志表（应用运行日志走框架 Logger 文件输出 data/logs/app.log，不入库）
const v2 = [_][]const u8{
    \\CREATE TABLE IF NOT EXISTS audit_logs (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL DEFAULT 0,
    \\  action TEXT NOT NULL,
    \\  target_type TEXT NOT NULL DEFAULT '',
    \\  target_id INTEGER NOT NULL DEFAULT 0,
    \\  request_summary TEXT NOT NULL DEFAULT '',
    \\  ip TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL
    \\)
    ,
    "CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON audit_logs(user_id)",
    "CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action)",
    "CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at)",
};

/// v3：学习域性能索引 + heartbeat 幂等性唯一约束（BUG-009 / BUG-014）
const v3 = [_][]const u8{
    // BUG-009: 优化「我的课程」列表查询性能
    "CREATE INDEX IF NOT EXISTS idx_lessons_course_deleted ON lessons(course_id, deleted)",
    "CREATE INDEX IF NOT EXISTS idx_progress_user_course_status ON learning_progress(user_id, course_id, status, updated_at DESC)",
    // BUG-014: heartbeat 幂等性——先清理可能存在的重复，再建唯一索引
    "DELETE FROM study_logs WHERE id > (SELECT MIN(id) FROM study_logs s2 WHERE s2.user_id = study_logs.user_id AND s2.lesson_id = study_logs.lesson_id AND s2.date = study_logs.date)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_study_logs_user_lesson_date ON study_logs(user_id, lesson_id, date)",
};

/// v4：审计日志补充请求参数（query 字符串）与独立响应状态列
const v4 = [_][]const u8{
    "ALTER TABLE audit_logs ADD COLUMN query TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE audit_logs ADD COLUMN status INTEGER NOT NULL DEFAULT 0",
};

pub const migrations = [_]Migration{
    .{ .sql = &v1 },
    .{ .sql = &v2 },
    .{ .sql = &v3 },
    .{ .sql = &v4 },
};

/// 执行所有未应用的迁移，并写入种子数据
pub fn run(dbh: *db.Db, io: std.Io, allocator: std.mem.Allocator) !void {
    var v: u32 = try dbh.schemaVersion();
    while (v < migrations.len) : (v += 1) {
        for (migrations[v].sql) |stmt| try dbh.exec(stmt, .{});
        try dbh.setSchemaVersion(v + 1);
        std.log.info("migrate: schema -> v{d}", .{v + 1});
    }
    try seed(dbh, io, allocator);
}

/// 幂等种子泡：仅缺失时写入超管账号（不再自动预置分类，保持干净环境）
pub fn seed(dbh: *db.Db, io: std.Io, allocator: std.mem.Allocator) !void {
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

    // 超管账号（默认密码仅用于首次启动，日志中提示尽快修改）
    if (((try dbh.scalarInt("SELECT COUNT(*) FROM users WHERE role = 'superadmin'", .{})) orelse 0) == 0) {
        const password = "admin123456";
        var hash_buf: [512]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = allocator,
            .params = .owasp_2id,
            .mode = .argon2id,
        }, &hash_buf, io);

        try dbh.exec(
            "INSERT INTO users (email, username, password_hash, nickname, role, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'superadmin', 'active', ?5, ?5)",
            .{ "admin@example.com", "admin", hash, "超级管理员", now },
        );
        std.log.warn("seed: created superadmin 'admin' (admin@example.com) with default password — 请尽快登录修改！", .{});
    }
}

test "migrate creates schema and idempotent seed" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    std.Io.Dir.cwd().createDirPath(io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const path = ".test_data/crm_migrate_test.db";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var dbh = try db.Db.open(alloc, path);
    defer dbh.close();

    try run(&dbh, io, alloc);
    // 幂等：跑两遍不报错、不重复
    try run(&dbh, io, alloc);

    try std.testing.expectEqual(@as(u32, migrations.len), try dbh.schemaVersion());
    try std.testing.expectEqual(@as(?i64, 1), try dbh.scalarInt("SELECT COUNT(*) FROM users WHERE role = 'superadmin'", .{}));
    try std.testing.expectEqual(@as(?i64, 0), try dbh.scalarInt("SELECT COUNT(*) FROM categories", .{}));

    // 测试结束后清理文件（macOS 允许对未关闭连接的文件 unlink，连接由 defer 关闭）
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
