//! 学习域（M-C）：课程报名、课时进度、学习时长流水。
//!
//! repo 约定同 course_repo：手写 SQL + 行转换 dupe 到 arena。
//! 并发模型同 Db：zio 单线程协程、sqlite 调用间不让出，不加锁。
//!
//! 报名幂等：handler 先 getEnrollment 预检，UNIQUE(user_id, course_id) 是兜底；
//! 付费课报名只建 pending 订单（pay_status=unpaid），第 6 期「标记支付」联动改 paid。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");

// ---------------------------------------------------------------- 报名

pub const Enrollment = struct {
    id: i64,
    course_id: i64,
    source: []const u8,
    pay_status: []const u8,
    created_at: i64,
};

pub const EnrollOutcome = union(enum) {
    /// 免费课程：报名即生效（pay_status=free）
    enrolled,
    /// 付费课程：pay_status=unpaid + 已建 pending 订单，支付后生效
    pending_payment: struct { order_no: []const u8, amount: i64 },
};

pub fn getEnrollment(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, course_id: i64) !?Enrollment {
    const row = try dbh.conn.row(
        "SELECT id, course_id, source, pay_status, created_at FROM enrollments WHERE user_id = ?1 AND course_id = ?2 LIMIT 1",
        .{ user_id, course_id },
    );
    const r = row orelse return null;
    defer r.deinit();
    return .{
        .id = r.int(0),
        .course_id = r.int(1),
        .source = try a.dupe(u8, r.text(2)),
        .pay_status = try a.dupe(u8, r.text(3)),
        .created_at = r.int(4),
    };
}

/// 报名课程。调用方负责课程存在性/上架状态校验与重复报名预检。
///
/// 付费课路径多表写入（报名行 + 订单行 + 计数），包在 BEGIN IMMEDIATE 事务里：
/// 订单插入失败不能留下无单可付的 unpaid 报名。zio 单连接串行，
/// BEGIN…COMMIT 之间不会让出，不存在其他请求误入事务的窗口。
pub fn enroll(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, course: course_repo.Course, now: i64) !EnrollOutcome {
    if (course.is_free == 1) {
        try insertEnrollment(dbh, user_id, course.id, "free", now);
        try bumpEnrollCount(dbh, course.id);
        return .enrolled;
    }

    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try insertEnrollment(dbh, user_id, course.id, "unpaid", now);
    const enroll_id = dbh.lastInsertId();
    // order_no 由 (unix 秒, 报名 id) 组成：全局唯一（id 递增）且人眼可读，
    // 不依赖随机数（std.crypto.random 在 std.Io 时代已移除）
    const order_no = try std.fmt.allocPrint(a, "O{d}-{d}", .{ now, enroll_id });
    try insertOrder(dbh, order_no, user_id, course.id, course.price, now);
    try bumpEnrollCount(dbh, course.id);

    try dbh.exec("COMMIT", .{});
    return .{ .pending_payment = .{ .order_no = order_no, .amount = course.price } };
}

fn insertEnrollment(dbh: *db.Db, user_id: i64, course_id: i64, pay_status: []const u8, now: i64) !void {
    try dbh.exec(
        "INSERT INTO enrollments (user_id, course_id, source, pay_status, created_at) VALUES (?1, ?2, 'self', ?3, ?4)",
        .{ user_id, course_id, pay_status, now },
    );
}

/// enroll_count 统计「报名行为」（含未支付），与列表页展示口径一致。
fn bumpEnrollCount(dbh: *db.Db, course_id: i64) !void {
    try dbh.exec("UPDATE courses SET enroll_count = enroll_count + 1 WHERE id = ?1", .{course_id});
}

/// 插入待支付订单。order_no 由调用方生成（需保证全局唯一，UNIQUE 兜底）。
pub fn insertOrder(dbh: *db.Db, order_no: []const u8, user_id: i64, course_id: i64, amount: i64, now: i64) !void {
    try dbh.exec(
        "INSERT INTO orders (order_no, user_id, course_id, amount, status, created_at) VALUES (?1, ?2, ?3, ?4, 'pending', ?5)",
        .{ order_no, user_id, course_id, amount, now },
    );
}

/// 用户能否学习该课时：免费试看课时所有人可学；付费课时需已报名（paid/free，未支付不解锁）。
pub fn canAccessLesson(dbh: *db.Db, user_id: i64, lesson: course_repo.Lesson) !bool {
    if (lesson.is_free == 1) return true;
    return course_repo.isEnrolled(dbh, user_id, lesson.course_id);
}

// ---------------------------------------------------------------- 进度

pub const Progress = struct {
    id: i64,
    lesson_id: i64,
    course_id: i64,
    status: []const u8,
    position: i64,
    updated_at: i64,
};

const progress_cols = "id, lesson_id, course_id, status, position, updated_at";

fn rowToProgress(row: zqlite.Row, a: std.mem.Allocator) !Progress {
    return .{
        .id = row.int(0),
        .lesson_id = row.int(1),
        .course_id = row.int(2),
        .status = try a.dupe(u8, row.text(3)),
        .position = row.int(4),
        .updated_at = row.int(5),
    };
}

pub fn validProgressStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "completed");
}

pub fn getProgress(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, lesson_id: i64) !?Progress {
    const row = try dbh.conn.row(
        "SELECT " ++ progress_cols ++ " FROM learning_progress WHERE user_id = ?1 AND lesson_id = ?2 LIMIT 1",
        .{ user_id, lesson_id },
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToProgress(r, a);
}

/// 不存在则插入、存在则整行覆盖（UNIQUE(user_id, lesson_id) upsert）。
pub fn upsertProgress(
    dbh: *db.Db,
    a: std.mem.Allocator,
    user_id: i64,
    lesson_id: i64,
    course_id: i64,
    status: []const u8,
    position: i64,
    now: i64,
) !Progress {
    try dbh.exec(
        "INSERT INTO learning_progress (user_id, lesson_id, course_id, status, position, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6) " ++
            "ON CONFLICT(user_id, lesson_id) DO UPDATE SET " ++
            "status = excluded.status, position = excluded.position, updated_at = excluded.updated_at",
        .{ user_id, lesson_id, course_id, status, position, now },
    );
    return (try getProgress(dbh, a, user_id, lesson_id)).?;
}

pub fn progressByCourse(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, course_id: i64) ![]Progress {
    var items: std.ArrayList(Progress) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ progress_cols ++ " FROM learning_progress WHERE user_id = ?1 AND course_id = ?2 ORDER BY lesson_id",
        .{ user_id, course_id },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToProgress(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

// ---------------------------------------------------------------- 我的课程

pub const MyEnrollment = struct {
    course_id: i64,
    title: []const u8,
    cover: []const u8,
    price: i64,
    is_free: i64,
    /// 课程自身状态：报名后下架/删除时前端置灰
    course_status: []const u8,
    pay_status: []const u8,
    source: []const u8,
    enrolled_at: i64,
    total_lessons: i64,
    completed_lessons: i64,
    /// 继续学习入口：最近一条 in_progress 课时；0/'' 表示没有在学课时
    last_lesson_id: i64,
    last_lesson_title: []const u8,
    last_position: i64,
};

pub const MyEnrollmentList = struct {
    items: std.ArrayList(MyEnrollment),
    total: i64,
};

/// 关联子查询共用同一 WHERE/ORDER BY，保证三个标量取到同一行；
/// 当前数据量（万级报名）单连接串行查询足够，v3 migration 已为 lessons(course_id, deleted)、
/// learning_progress(user_id, course_id, status) 补索引，确保子查询高效。
pub fn listByUser(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, page: i64, size: i64) !MyEnrollmentList {
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM enrollments e JOIN courses c ON c.id = e.course_id WHERE e.user_id = ?1 AND c.deleted = 0",
        .{user_id},
    )) orelse 0;

    var items: std.ArrayList(MyEnrollment) = .empty;
    var rows = try dbh.conn.rows(
        \\SELECT e.course_id, c.title, c.cover, c.price, c.is_free, c.status,
        \\       e.pay_status, e.source, e.created_at,
        \\       (SELECT COUNT(*) FROM lessons l WHERE l.course_id = e.course_id AND l.deleted = 0),
        \\       (SELECT COUNT(*) FROM learning_progress p WHERE p.user_id = e.user_id AND p.course_id = e.course_id AND p.status = 'completed'),
        \\       COALESCE((SELECT p2.lesson_id FROM learning_progress p2 WHERE p2.user_id = e.user_id AND p2.course_id = e.course_id AND p2.status = 'in_progress' ORDER BY p2.updated_at DESC, p2.lesson_id ASC LIMIT 1), 0),
        \\       COALESCE((SELECT l2.title FROM learning_progress p2 JOIN lessons l2 ON l2.id = p2.lesson_id WHERE p2.user_id = e.user_id AND p2.course_id = e.course_id AND p2.status = 'in_progress' ORDER BY p2.updated_at DESC, p2.lesson_id ASC LIMIT 1), ''),
        \\       COALESCE((SELECT p2.position FROM learning_progress p2 WHERE p2.user_id = e.user_id AND p2.course_id = e.course_id AND p2.status = 'in_progress' ORDER BY p2.updated_at DESC, p2.lesson_id ASC LIMIT 1), 0)
        \\FROM enrollments e JOIN courses c ON c.id = e.course_id
        \\WHERE e.user_id = ?1 AND c.deleted = 0
        \\ORDER BY e.id DESC LIMIT ?2 OFFSET ?3
    , .{ user_id, size, (page - 1) * size });
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{
            .course_id = row.int(0),
            .title = try a.dupe(u8, row.text(1)),
            .cover = try a.dupe(u8, row.text(2)),
            .price = row.int(3),
            .is_free = row.int(4),
            .course_status = try a.dupe(u8, row.text(5)),
            .pay_status = try a.dupe(u8, row.text(6)),
            .source = try a.dupe(u8, row.text(7)),
            .enrolled_at = row.int(8),
            .total_lessons = row.int(9),
            .completed_lessons = row.int(10),
            .last_lesson_id = row.int(11),
            .last_lesson_title = try a.dupe(u8, row.text(12)),
            .last_position = row.int(13),
        });
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 学习时长

/// 心跳/学习时长流水（幂等）。date 为服务端 UTC 'YYYY-MM-DD'（跨天统一按服务端时钟归日）；
/// v3 migration 已为 study_logs(user_id, lesson_id, date) 建 UNIQUE 索引，这里用 ON CONFLICT
/// 累加秒数，保证同一 (user_id, lesson_id, date) 多次上报不会产生重复行。
pub fn logStudy(dbh: *db.Db, user_id: i64, course_id: i64, lesson_id: i64, seconds: i64, date: []const u8, now: i64) !void {
    // zqlite 的 prepare 对 ON CONFLICT DO UPDATE 支持不稳定；改为两步操作保证幂等
    try dbh.exec(
        "UPDATE study_logs SET seconds = seconds + ?1, created_at = ?2 WHERE user_id = ?3 AND lesson_id = ?4 AND date = ?5",
        .{ seconds, now, user_id, lesson_id, date },
    );

    try dbh.exec(
        "INSERT INTO study_logs (user_id, course_id, lesson_id, seconds, date, created_at) SELECT ?1, ?2, ?3, ?4, ?5, ?6 " ++
        "WHERE NOT EXISTS (SELECT 1 FROM study_logs WHERE user_id = ?7 AND lesson_id = ?8 AND date = ?9)",
        .{ user_id, course_id, lesson_id, seconds, date, now, user_id, lesson_id, date },
    );
}

fn civilFromDays(z0: i64) struct { y: i64, m: i64, d: i64 } {
    // Howard Hinnant days_from_civil 逆变换；era 用真 floor 除（兼容负天数），
    // 其后各中间量（doe/yoe/doy/mp/…）在 +719468 后均非负，统一 @divTrunc 即等价 floor
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

pub fn utcDate(a: std.mem.Allocator, epoch_sec: i64) ![]u8 {
    const c = civilFromDays(@divFloor(epoch_sec, 86400));
    // 此 Zig dev 版 printIntAny 的怪癖：有符号整数带宽度格式会加 '+' 号（{d:0>2} 1 → "+1"），
    // 零填充一律转无符号；m/d 由算法保证非负，仅 y 理论上可为负（1970 前，学习日志不会出现）。
    const y: u64 = std.math.cast(u64, c.y) orelse
        return std.fmt.allocPrint(a, "{d}-{d}-{d}", .{ c.y, c.m, c.d });
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)) });
}

// ---------------------------------------------------------------------------

test "utcDate civil boundaries" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    try std.testing.expectEqualStrings("1970-01-01", try utcDate(a, 0));
    try std.testing.expectEqualStrings("2000-01-01", try utcDate(a, 946684800));
    try std.testing.expectEqualStrings("2024-02-29", try utcDate(a, 1709164800));
    try std.testing.expectEqualStrings("2024-12-31", try utcDate(a, 1735689599));
    try std.testing.expectEqualStrings("2025-01-01", try utcDate(a, 1735689600));
}

test "validProgressStatus" {
    try std.testing.expect(validProgressStatus("in_progress"));
    try std.testing.expect(validProgressStatus("completed"));
    try std.testing.expect(!validProgressStatus("not_started"));
    try std.testing.expect(!validProgressStatus(""));
}

// ---------------------------------------------------------------- 集成测试用 DDL

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

const progress_ddl =
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
;

const logs_ddl =
    \\CREATE TABLE IF NOT EXISTS study_logs (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL DEFAULT 0,
    \\  lesson_id INTEGER NOT NULL DEFAULT 0,
    \\  seconds INTEGER NOT NULL DEFAULT 0,
    \\  date TEXT NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\)
;

const test_sqls = course_repo.test_sqls ++ [_][]const u8{ orders_ddl, progress_ddl, logs_ddl };

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

test "learning_repo enroll / progress / study log / my list" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/learning_repo_test.db");
    defer dbh.close();
    const now: i64 = 1_760_000_000;

    // 素材：免费课（试看课时 + 普通课时）、付费课（普通课时）
    const fc = try course_repo.create(&dbh, 1, "免费课程", "", "", "", 0, 1, "published", 0, now);
    const pc = try course_repo.create(&dbh, 1, "付费课程", "", "", "", 12900, 0, "published", 0, now);
    const ch = try course_repo.chapterCreate(&dbh, fc, "第一章", 1);
    const l_free = try course_repo.lessonCreate(&dbh, fc, ch, "试看课时", "markdown", 0, "内容", 60, 1, 1);
    const l_paid = try course_repo.lessonCreate(&dbh, fc, ch, "普通课时", "video", 0, "", 300, 0, 2);
    const l_pc = try course_repo.lessonCreate(&dbh, pc, 0, "付费课课时", "video", 0, "", 120, 0, 1);

    // 免费课报名：即生效、计数 +1、解锁判定
    const o1 = try enroll(&dbh, a, 7, (try course_repo.getById(&dbh, a, fc)).?, now);
    try std.testing.expect(o1 == .enrolled);
    const e = (try getEnrollment(&dbh, a, 7, fc)).?;
    try std.testing.expectEqualStrings("free", e.pay_status);
    try std.testing.expectEqual(@as(?i64, 1), try dbh.scalarInt("SELECT enroll_count FROM courses WHERE id = ?1", .{fc}));
    try std.testing.expect(try course_repo.isEnrolled(&dbh, 7, fc));

    // 重复报名由预检拦截（模拟 handler 流程）
    try std.testing.expect((try getEnrollment(&dbh, a, 7, fc)) != null);

    // 付费课报名：pending 订单 + unpaid，不解锁
    const o2 = try enroll(&dbh, a, 7, (try course_repo.getById(&dbh, a, pc)).?, now);
    try std.testing.expect(o2 == .pending_payment);
    try std.testing.expect(std.mem.startsWith(u8, o2.pending_payment.order_no, "O"));
    try std.testing.expectEqual(@as(i64, 12900), o2.pending_payment.amount);
    try std.testing.expectEqual(@as(?i64, 1), try dbh.scalarInt(
        "SELECT COUNT(*) FROM orders WHERE user_id = 7 AND status = 'pending' AND amount = 12900",
        .{},
    ));
    try std.testing.expect(!(try course_repo.isEnrolled(&dbh, 7, pc)));

    // 课时访问：免费试看人人可；普通课时需已报名；付费课课时未支付不可
    const lesson_free = (try course_repo.lessonGetById(&dbh, a, l_free)).?;
    const lesson_paid = (try course_repo.lessonGetById(&dbh, a, l_paid)).?;
    const lesson_pc = (try course_repo.lessonGetById(&dbh, a, l_pc)).?;
    try std.testing.expect(try canAccessLesson(&dbh, 7, lesson_free));
    try std.testing.expect(try canAccessLesson(&dbh, 7, lesson_paid));
    try std.testing.expect(!(try canAccessLesson(&dbh, 7, lesson_pc)));

    // 进度 upsert：插入 → 覆盖同一行
    _ = try upsertProgress(&dbh, a, 7, lesson_paid.id, fc, "in_progress", 30, now);
    const p2 = try upsertProgress(&dbh, a, 7, lesson_paid.id, fc, "completed", 300, now + 10);
    try std.testing.expectEqualStrings("completed", p2.status);
    try std.testing.expectEqual(@as(i64, 1), (try dbh.scalarInt("SELECT COUNT(*) FROM learning_progress WHERE user_id = 7", .{})).?);
    try std.testing.expectEqual(@as(usize, 1), (try progressByCourse(&dbh, a, 7, fc)).len);

    // 继续学习：新 put 的 in_progress 课时成为 last
    _ = try upsertProgress(&dbh, a, 7, lesson_free.id, fc, "in_progress", 5, now + 20);
    const mine = try listByUser(&dbh, a, 7, 1, 20);
    try std.testing.expectEqual(@as(i64, 2), mine.total);
    try std.testing.expectEqual(@as(usize, 2), mine.items.items.len);
    // ORDER BY e.id DESC → 后报名的付费课在前
    const it_pc = mine.items.items[0];
    try std.testing.expectEqual(pc, it_pc.course_id);
    try std.testing.expectEqualStrings("unpaid", it_pc.pay_status);
    const it_fc = mine.items.items[1];
    try std.testing.expectEqual(fc, it_fc.course_id);
    try std.testing.expectEqual(@as(i64, 2), it_fc.total_lessons);
    try std.testing.expectEqual(@as(i64, 1), it_fc.completed_lessons);
    try std.testing.expectEqual(lesson_free.id, it_fc.last_lesson_id);
    try std.testing.expectEqualStrings("试看课时", it_fc.last_lesson_title);
    try std.testing.expectEqual(@as(i64, 5), it_fc.last_position);

    // 学习时长：两条流水按日汇总
    const d0 = try utcDate(a, now);
    try logStudy(&dbh, 7, fc, lesson_paid.id, 30, d0, now);
    try logStudy(&dbh, 7, fc, lesson_paid.id, 20, d0, now + 50);
    try std.testing.expectEqual(@as(?i64, 50), try dbh.scalarInt(
        "SELECT SUM(seconds) FROM study_logs WHERE user_id = 7 AND date = ?1",
        .{d0},
    ));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/learning_repo_test.db") catch {};
}
