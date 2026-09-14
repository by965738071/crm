//! 用户表数据访问（users）。所有字符串读出来后 dupe 到调用方 allocator，
//! 行内存生命周期不越过当次迭代。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");

pub const RepoError = error{ UserNotFound, UserExists };

pub const User = struct {
    id: i64,
    email: []const u8,
    username: []const u8,
    nickname: []const u8,
    avatar: []const u8,
    role: []const u8,
    status: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const UserWithPassword = struct {
    user: User,
    password_hash: []const u8,
};

pub const ListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    keyword: []const u8 = "",
    role: []const u8 = "",
};

const select_cols = "id, email, username, nickname, avatar, role, status, created_at, updated_at";

fn rowToUser(row: zqlite.Row, a: std.mem.Allocator) !User {
    return .{
        .id = row.int(0),
        .email = try a.dupe(u8, row.text(1)),
        .username = try a.dupe(u8, row.text(2)),
        .nickname = try a.dupe(u8, row.text(3)),
        .avatar = try a.dupe(u8, row.text(4)),
        .role = try a.dupe(u8, row.text(5)),
        .status = try a.dupe(u8, row.text(6)),
        .created_at = row.int(7),
        .updated_at = row.int(8),
    };
}

/// 按邮箱或用户名查（登录用），含 password_hash。
pub fn getByAccount(dbh: *db.Db, a: std.mem.Allocator, account: []const u8) !?UserWithPassword {
    const row = try dbh.conn.row(
        "SELECT " ++ select_cols ++ ", password_hash FROM users WHERE email = ?1 OR username = ?1 LIMIT 1",
        .{account},
    );
    const r = row orelse return null;
    defer r.deinit();
    return .{
        .user = try rowToUser(r, a),
        .password_hash = try a.dupe(u8, r.text(9)),
    };
}

/// 改密校验旧密码用（按 id 取哈希）。
pub fn getPasswordHashById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?[]const u8 {
    const row = try dbh.conn.row("SELECT password_hash FROM users WHERE id = ?1 LIMIT 1", .{id});
    const r = row orelse return null;
    defer r.deinit();
    return try a.dupe(u8, r.text(0));
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?User {
    const row = try dbh.conn.row(
        "SELECT " ++ select_cols ++ " FROM users WHERE id = ?1 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToUser(r, a);
}

/// 注册新角色。捕获 UNIQUE 约束 → error.UserExists。
pub fn create(
    dbh: *db.Db,
    email: []const u8,
    username: []const u8,
    nickname: []const u8,
    password_hash: []const u8,
    role: []const u8,
    now: i64,
) !i64 {
    dbh.conn.exec(
        "INSERT INTO users (email, username, password_hash, nickname, role, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?6)",
        .{ email, username, password_hash, nickname, role, now },
    ) catch |err| {
        // exec 的错误集比 zqlite.Error 宽（多 MultipleStatements 等），不能直接传 zqlite.isUnique
        if (err == error.ConstraintUnique) return error.UserExists;
        return err;
    };
    return dbh.lastInsertId();
}

fn updateExec(dbh: *db.Db, sql: []const u8, values: anytype) !void {
    try dbh.conn.exec(sql, values);
    if (dbh.conn.changes() == 0) return error.UserNotFound;
}

pub fn updateStatus(dbh: *db.Db, id: i64, status: []const u8, now: i64) !void {
    try updateExec(dbh, "UPDATE users SET status = ?1, updated_at = ?2 WHERE id = ?3", .{ status, now, id });
}

pub fn updateRole(dbh: *db.Db, id: i64, role: []const u8, now: i64) !void {
    try updateExec(dbh, "UPDATE users SET role = ?1, updated_at = ?2 WHERE id = ?3", .{ role, now, id });
}

pub fn updatePassword(dbh: *db.Db, id: i64, password_hash: []const u8, now: i64) !void {
    try updateExec(dbh, "UPDATE users SET password_hash = ?1, updated_at = ?2 WHERE id = ?3", .{ password_hash, now, id });
}

/// nickname/avatar 传 null 表示不改。
pub fn updateProfile(dbh: *db.Db, id: i64, nickname: ?[]const u8, avatar: ?[]const u8, now: i64) !void {
    if (nickname == null and avatar == null) return;
    if (nickname) |n| {
        try updateExec(dbh, "UPDATE users SET nickname = ?1, updated_at = ?2 WHERE id = ?3", .{ n, now, id });
    }
    if (avatar) |av| {
        try updateExec(dbh, "UPDATE users SET avatar = ?1, updated_at = ?2 WHERE id = ?3", .{ av, now, id });
    }
}

pub const ListResult = struct {
    items: std.ArrayList(User),
    total: i64,
};

/// 构造 LIKE 包含匹配模式：`%keyword%`，其中 keyword 内的 % _ \ 三个字符转义。
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
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM users WHERE (?1 = '' OR username LIKE ?2 ESCAPE '\\' OR email LIKE ?2 ESCAPE '\\' OR nickname LIKE ?2 ESCAPE '\\') AND (?3 = '' OR role = ?3)",
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.role },
    )) orelse 0;

    var items: std.ArrayList(User) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ select_cols ++ " FROM users WHERE (?1 = '' OR username LIKE ?2 ESCAPE '\\' OR email LIKE ?2 ESCAPE '\\' OR nickname LIKE ?2 ESCAPE '\\') AND (?3 = '' OR role = ?3) ORDER BY id DESC LIMIT ?4 OFFSET ?5",
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.role, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToUser(row, a));
    }
    // 迭代期间吞掉的 step 错误统一在这里暴露（deinit 已 defer，不重复释放）
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------------------

const test_sql =
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

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    try dbh.exec(test_sql, .{});
    return dbh;
}

test "user_repo create/get/update/list" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/user_repo_test.db");
    defer dbh.close();

    const id = try create(&dbh, "a@b.com", "alice", "Alice", "hash1", "student", 100);
    try std.testing.expect(id > 0);

    // 重复注册 → UserExists
    try std.testing.expectError(error.UserExists, create(&dbh, "a@b.com", "alice2", "", "h", "student", 100));

    // 按邮箱 / 用户名都能查到，且含 password_hash
    const by_email = try getByAccount(&dbh, a, "a@b.com");
    try std.testing.expect(by_email != null);
    try std.testing.expectEqualStrings("hash1", by_email.?.password_hash);
    const by_name = try getByAccount(&dbh, a, "alice");
    try std.testing.expect(by_name != null);
    try std.testing.expectEqual(by_email.?.user.id, by_name.?.user.id);

    // getById 更新后字段生效
    try updateStatus(&dbh, id, "disabled", 200);
    const got = (try getById(&dbh, a, id)).?;
    try std.testing.expectEqualStrings("disabled", got.status);

    // 不存在的 id
    try std.testing.expectError(error.UserNotFound, updateStatus(&dbh, 9999, "active", 1));

    // 列表 + 关键字 + 角色过滤 + LIKE 转义
    _ = try create(&dbh, "c@d.com", "carol", "Bob 医生", "h3", "admin", 100);
    const all = try list(&dbh, a, .{});
    try std.testing.expectEqual(@as(i64, 2), all.total);

    const kw = try list(&dbh, a, .{ .keyword = "医生" });
    try std.testing.expectEqual(@as(i64, 1), kw.total);
    try std.testing.expectEqualStrings("carol", kw.items.items[0].username);

    const role_only = try list(&dbh, a, .{ .role = "admin" });
    try std.testing.expectEqual(@as(i64, 1), role_only.total);

    // LIKE 通配转义：keyword="%" 不应匹配全部
    const wild = try list(&dbh, a, .{ .keyword = "%" });
    try std.testing.expectEqual(@as(i64, 0), wild.total);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/user_repo_test.db") catch {};
}
