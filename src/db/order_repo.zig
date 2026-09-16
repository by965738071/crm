//! 订单域（M-F，第 6 期）：订单列表 / 管理端代下单 / 状态机（pending → paid | cancelled）。
//!
//! repo 约定同 learning_repo：手写 SQL + 行读出 dupe 到 arena；zio 单连接串行不加锁。
//! 订单产生路径有二：学员报名（learning_repo.enroll，source=self）与管理端代下单
//! （createByAdmin，source=admin）；两者都只对付费课建 pending 订单，order_no 同规则
//! `O{now}-{enroll_id}`（enrollments.id 全局递增，唯一且可读）。
//!
//! 状态机：pending 是唯一可操作态，paid/cancelled 为终态（改态 UPDATE 带
//! `status='pending'` 守卫，changes==0 → error.InvalidState，幂等防重复标记）。
//! 支付联动：enrollments.pay_status unpaid→paid（课时解锁走 isEnrolled 的 paid/free 判定）。
//! 取消联动：删除对应 unpaid 报名行并回退 enroll_count——不删则旧报名永远命中
//! already_enrolled 预检，学员无法重新报名（重报名再产生新订单，旧订单已 cancelled）。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");

pub const statuses = [_][]const u8{ "pending", "paid", "cancelled" };

pub fn validStatus(s: []const u8) bool {
    for (statuses) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

pub const Order = struct {
    id: i64,
    order_no: []const u8,
    user_id: i64,
    course_id: i64,
    /// 金额，单位：分（与 courses.price 同口径；元换算属前端展示）
    amount: i64,
    status: []const u8,
    pay_method: []const u8,
    remark: []const u8,
    /// 标记支付/取消的管理员 id；0 = 系统（无管理端操作时）
    operator_id: i64,
    paid_at: i64,
    created_at: i64,
    // ---- JOIN 展示字段（LEFT JOIN：用户/课程行缺失时为空串，不隐藏订单）----
    username: []const u8 = "",
    nickname: []const u8 = "",
    course_title: []const u8 = "",
};

const order_cols =
    \\o.id, o.order_no, o.user_id, o.course_id, o.amount, o.status, o.pay_method,
    \\o.remark, o.operator_id, o.paid_at, o.created_at,
    \\COALESCE(u.username, ''), COALESCE(u.nickname, ''), COALESCE(c.title, '')
;
const order_join =
    \\ FROM orders o
    \\LEFT JOIN users u ON u.id = o.user_id
    \\LEFT JOIN courses c ON c.id = o.course_id
;

fn rowToOrder(row: zqlite.Row, a: std.mem.Allocator) !Order {
    return .{
        .id = row.int(0),
        .order_no = try a.dupe(u8, row.text(1)),
        .user_id = row.int(2),
        .course_id = row.int(3),
        .amount = row.int(4),
        .status = try a.dupe(u8, row.text(5)),
        .pay_method = try a.dupe(u8, row.text(6)),
        .remark = try a.dupe(u8, row.text(7)),
        .operator_id = row.int(8),
        .paid_at = row.int(9),
        .created_at = row.int(10),
        .username = try a.dupe(u8, row.text(11)),
        .nickname = try a.dupe(u8, row.text(12)),
        .course_title = try a.dupe(u8, row.text(13)),
    };
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Order {
    const row = try dbh.conn.row(
        "SELECT " ++ order_cols ++ order_join ++ " WHERE o.id = ?1 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToOrder(r, a);
}

// ---------------------------------------------------------------- 列表

pub const ListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    /// 0 = 不限用户（管理端）；>0 = 仅该用户（学员端由 handler 强制为本人）
    user_id: i64 = 0,
    status: []const u8 = "",
    /// 匹配订单号或课程标题（ LIKE，转义 %_\\）
    keyword: []const u8 = "",
};

pub const ListResult = struct {
    items: std.ArrayList(Order),
    total: i64,
};

fn likePattern(a: std.mem.Allocator, kw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '%');
    for (kw) |c| {
        switch (c) {
            '%', '_', '\\' => try out.append(a, '\\'),
            else => {},
        }
        try out.append(a, c);
    }
    try out.append(a, '%');
    return out.toOwnedSlice(a);
}

pub fn list(dbh: *db.Db, a: std.mem.Allocator, opts: ListOpts) !ListResult {
    const where =
        \\(?1 = 0 OR o.user_id = ?1) AND (?2 = '' OR o.status = ?2)
        \\AND (?3 = '' OR o.order_no LIKE ?4 ESCAPE '\' OR COALESCE(c.title, '') LIKE ?4 ESCAPE '\')
    ;
    const pat = try likePattern(a, opts.keyword);
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*)" ++ order_join ++ " WHERE" ++ where,
        .{ opts.user_id, opts.status, opts.keyword, pat },
    )) orelse 0;

    var items: std.ArrayList(Order) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ order_cols ++ order_join ++ " WHERE" ++ where ++ " ORDER BY o.id DESC LIMIT ?5 OFFSET ?6",
        .{ opts.user_id, opts.status, opts.keyword, pat, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToOrder(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 代下单

/// 管理端代下单：建 unpaid 报名行（source=admin）+ pending 订单，全程一个事务。
/// 免费课/重复报名在事务外预检（UNIQUE(user_id,course_id) 兜底，同 enroll() 约定）。
pub fn createByAdmin(
    dbh: *db.Db,
    a: std.mem.Allocator,
    user_id: i64,
    course: course_repo.Course,
    operator_id: i64,
    now: i64,
) !Order {
    if (course.is_free == 1) return error.FreeCourse;
    if (((try dbh.scalarInt(
        "SELECT COUNT(*) FROM enrollments WHERE user_id = ?1 AND course_id = ?2",
        .{ user_id, course.id },
    )) orelse 0) > 0) return error.AlreadyEnrolled;

    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "INSERT INTO enrollments (user_id, course_id, source, pay_status, created_at) VALUES (?1, ?2, 'admin', 'unpaid', ?3)",
        .{ user_id, course.id, now },
    );
    const enroll_id = dbh.lastInsertId();
    const order_no = try std.fmt.allocPrint(a, "O{d}-{d}", .{ now, enroll_id });
    try dbh.exec(
        "INSERT INTO orders (order_no, user_id, course_id, amount, status, operator_id, created_at) VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?6)",
        .{ order_no, user_id, course.id, course.price, operator_id, now },
    );
    const order_id = dbh.lastInsertId();
    try dbh.exec("UPDATE courses SET enroll_count = enroll_count + 1 WHERE id = ?1", .{course.id});

    try dbh.exec("COMMIT", .{});
    return (try getById(dbh, a, order_id)) orelse return error.InvalidState;
}

// ---------------------------------------------------------------- 状态流转

pub const PayOpts = struct {
    order_id: i64,
    pay_method: []const u8 = "",
    /// 空 = 保留订单原备注（COALESCE(NULLIF)）
    remark: []const u8 = "",
    operator_id: i64 = 0,
    now: i64,
};

/// 标记已支付（现金/转账等线下收款的管理端登记）。事务内联动报名行解锁。
pub fn markPaid(dbh: *db.Db, a: std.mem.Allocator, opts: PayOpts) !Order {
    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "UPDATE orders SET status = 'paid', pay_method = ?2, remark = COALESCE(NULLIF(?3, ''), remark), operator_id = ?4, paid_at = ?5 WHERE id = ?1 AND status = 'pending'",
        .{ opts.order_id, opts.pay_method, opts.remark, opts.operator_id, opts.now },
    );
    if (dbh.conn.changes() == 0) return error.InvalidState;

    const row = try dbh.conn.row("SELECT user_id, course_id FROM orders WHERE id = ?1", .{opts.order_id});
    const r = row orelse return error.InvalidState;
    defer r.deinit();
    const user_id = r.int(0);
    const course_id = r.int(1);

    // 只翻 unpaid 行；代下单后学员不可能有 free/paid 旧行，防御性保留该守卫
    try dbh.exec(
        "UPDATE enrollments SET pay_status = 'paid' WHERE user_id = ?1 AND course_id = ?2 AND pay_status = 'unpaid'",
        .{ user_id, course_id },
    );
    try dbh.exec("COMMIT", .{});
    return (try getById(dbh, a, opts.order_id)) orelse return error.InvalidState;
}

/// 取消订单：仅 pending 可取消；联动删除 unpaid 报名并回退 enroll_count，
/// 使学员可重新报名（重新报名会生成全新订单）。
pub fn cancel(dbh: *db.Db, a: std.mem.Allocator, order_id: i64, operator_id: i64, remark: []const u8) !Order {
    try dbh.exec("BEGIN IMMEDIATE", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "UPDATE orders SET status = 'cancelled', remark = COALESCE(NULLIF(?2, ''), remark), operator_id = ?3 WHERE id = ?1 AND status = 'pending'",
        .{ order_id, remark, operator_id },
    );
    if (dbh.conn.changes() == 0) return error.InvalidState;

    const row = try dbh.conn.row("SELECT user_id, course_id FROM orders WHERE id = ?1", .{order_id});
    const r = row orelse return error.InvalidState;
    defer r.deinit();
    const user_id = r.int(0);
    const course_id = r.int(1);

    try dbh.exec(
        "DELETE FROM enrollments WHERE user_id = ?1 AND course_id = ?2 AND pay_status = 'unpaid'",
        .{ user_id, course_id },
    );
    if (dbh.conn.changes() > 0) {
        try dbh.exec(
            "UPDATE courses SET enroll_count = CASE WHEN enroll_count > 0 THEN enroll_count - 1 ELSE 0 END WHERE id = ?1",
            .{course_id},
        );
    }
    try dbh.exec("COMMIT", .{});
    return (try getById(dbh, a, order_id)) orelse return error.InvalidState;
}

// ---------------------------------------------------------------- 集成测试用 DDL

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

pub const test_sqls = course_repo.test_sqls ++ [_][]const u8{ users_ddl, orders_ddl };

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

test "order_repo proxy order / pay / cancel state machine and enrollment linkage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/crm_order_test.db");
    defer dbh.close();

    try dbh.exec(
        "INSERT INTO users (email, username, password_hash, nickname, role, status, created_at, updated_at) VALUES ('o@ex.com', 'stu1', 'h', 'S1', 'student', 'active', 1, 1)",
        .{},
    );
    const uid = dbh.lastInsertId();
    try dbh.exec("INSERT INTO courses (title, price, is_free, status, created_at, updated_at) VALUES ('c1', 9900, 0, 'published', 1, 1)", .{});
    const c1 = dbh.lastInsertId();
    try dbh.exec("INSERT INTO courses (title, price, is_free, status, created_at, updated_at) VALUES ('cf', 0, 1, 'published', 1, 1)", .{});
    const cf = dbh.lastInsertId();

    const course1 = (try course_repo.getById(&dbh, a, c1)) orelse return error.TestUnexpectedResult;
    var o1 = try createByAdmin(&dbh, a, uid, course1, 9, 100);
    try std.testing.expectEqualStrings("pending", o1.status);
    try std.testing.expectEqual(@as(i64, 9900), o1.amount);
    try std.testing.expectEqualStrings("stu1", o1.username);
    try std.testing.expectEqualStrings("S1", o1.nickname);
    try std.testing.expectEqualStrings("c1", o1.course_title);
    try std.testing.expectEqual(@as(i64, 1), try dbh.scalarInt("SELECT COUNT(*) FROM enrollments WHERE user_id = ?1 AND source = 'admin' AND pay_status = 'unpaid'", .{uid}) orelse 0);

    // 免费课拒绝 / 重复报名拒绝
    const coursef = (try course_repo.getById(&dbh, a, cf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.FreeCourse, createByAdmin(&dbh, a, uid, coursef, 9, 101));
    try std.testing.expectError(error.AlreadyEnrolled, createByAdmin(&dbh, a, uid, course1, 9, 102));

    // 标记支付 → 订单 paid + 报名解锁
    o1 = try markPaid(&dbh, a, .{ .order_id = o1.id, .pay_method = "cash", .remark = "r1", .operator_id = 9, .now = 200 });
    try std.testing.expectEqualStrings("paid", o1.status);
    try std.testing.expectEqual(@as(i64, 200), o1.paid_at);
    try std.testing.expectEqualStrings("cash", o1.pay_method);
    try std.testing.expectEqualStrings("r1", o1.remark);
    try std.testing.expectEqual(@as(i64, 1), try dbh.scalarInt("SELECT COUNT(*) FROM enrollments WHERE user_id = ?1 AND pay_status = 'paid'", .{uid}) orelse 0);
    // 终态守卫：paid 不可再支付/取消
    try std.testing.expectError(error.InvalidState, markPaid(&dbh, a, .{ .order_id = o1.id, .now = 201 }));
    try std.testing.expectError(error.InvalidState, cancel(&dbh, a, o1.id, 9, ""));

    // 取消 → 报名回滚 + enroll_count 回退，可重新代下单
    try dbh.exec("INSERT INTO courses (title, price, is_free, status, created_at, updated_at) VALUES ('c2', 100, 0, 'published', 1, 1)", .{});
    const c2 = dbh.lastInsertId();
    const course2 = (try course_repo.getById(&dbh, a, c2)) orelse return error.TestUnexpectedResult;
    var o2 = try createByAdmin(&dbh, a, uid, course2, 9, 300);
    o2 = try cancel(&dbh, a, o2.id, 9, "offline refund");
    try std.testing.expectEqualStrings("cancelled", o2.status);
    try std.testing.expectEqualStrings("offline refund", o2.remark);
    try std.testing.expectEqual(@as(i64, 1), try dbh.scalarInt("SELECT COUNT(*) FROM enrollments WHERE user_id = ?1", .{uid}) orelse 0);
    try std.testing.expectEqual(@as(i64, 0), try dbh.scalarInt("SELECT enroll_count FROM courses WHERE id = ?1", .{c2}) orelse 0);
    try std.testing.expectError(error.InvalidState, cancel(&dbh, a, o2.id, 9, ""));
    _ = try createByAdmin(&dbh, a, uid, course2, 9, 301); // 取消后重新下单成功

    // 列表过滤：用户 / 状态 / 关键词（订单号、课程标题）/ 分页
    const all = try list(&dbh, a, .{});
    try std.testing.expectEqual(@as(i64, 3), all.total);
    const pending = try list(&dbh, a, .{ .status = "pending" });
    try std.testing.expectEqual(@as(i64, 1), pending.total);
    try std.testing.expectEqualStrings("O301-3", pending.items.items[0].order_no);
    const mine = try list(&dbh, a, .{ .user_id = uid, .status = "paid" });
    try std.testing.expectEqual(@as(i64, 1), mine.total);
    const other = try list(&dbh, a, .{ .user_id = 999 });
    try std.testing.expectEqual(@as(i64, 0), other.total);
    const kw_no = try list(&dbh, a, .{ .keyword = "O300" });
    try std.testing.expectEqual(@as(i64, 1), kw_no.total);
    const kw_title = try list(&dbh, a, .{ .keyword = "c2" });
    try std.testing.expectEqual(@as(i64, 2), kw_title.total);
    const paged = try list(&dbh, a, .{ .size = 1, .page = 2 });
    try std.testing.expectEqual(@as(i64, 3), paged.total);
    try std.testing.expectEqual(@as(usize, 1), paged.items.items.len);
    try std.testing.expectEqual(o2.id, paged.items.items[0].id); // id DESC = [o3, o2, o1] → 第二条 = o2
}

test {
    std.testing.refAllDecls(@This());
}
