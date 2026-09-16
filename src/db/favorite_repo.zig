//! 通用收藏（M-G G2）：课程、资料。题目收藏在题库模块（question_favorites），不并表。
//!
//! 约定：target_type ∈ {course, resource}；add 用 INSERT OR IGNORE 幂等；
//! 列表 LEFT JOIN 目标表并过滤软删内容（目标下架/删除 → 收藏隐身，与第 4 期题收藏语义一致）。
//! 行的物理删除由收藏接口负责；目标课程被硬删（本项目不会发生）时同样隐身。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");

pub const target_types = [_][]const u8{ "course", "resource" };

pub fn validTargetType(s: []const u8) bool {
    for (target_types) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

pub const Favorite = struct {
    id: i64,
    target_type: []const u8,
    target_id: i64,
    /// 课程 title / 资料 name；缺失兜底空串（列表 SQL 已过滤，仅防御）
    title: []const u8,
    cover: []const u8,
    /// 课程价格（分）；资料恒 0
    price: i64,
    /// 资料文件类型（video/audio/pdf/...）；课程恒空串
    rtype: []const u8,
    created_at: i64,
};

pub const ListResult = struct {
    items: std.ArrayList(Favorite),
    total: i64,
};

const fav_cols =
    \\SELECT f.id, f.target_type, f.target_id,
    \\       COALESCE(c.title, r.name, ''), COALESCE(c.cover, ''), COALESCE(c.price, 0),
    \\       COALESCE(r.type, ''), f.created_at
++ "\n";
const fav_from =
    \\FROM favorites f
    \\LEFT JOIN courses c ON f.target_type = 'course' AND c.id = f.target_id
    \\LEFT JOIN resources r ON f.target_type = 'resource' AND r.id = f.target_id
++ "\n";
const fav_select = fav_cols ++ fav_from;
// 隐身条件：目标行存在且未软删；未知 target_type 的行（理论不存在）也隐身
const fav_live =
    \\( (f.target_type = 'course' AND c.id IS NOT NULL AND c.deleted = 0)
    \\   OR (f.target_type = 'resource' AND r.id IS NOT NULL AND r.deleted = 0) )
;

fn rowToFavorite(row: zqlite.Row, a: std.mem.Allocator) !Favorite {
    return .{
        .id = row.int(0),
        .target_type = try a.dupe(u8, row.text(1)),
        .target_id = row.int(2),
        .title = try a.dupe(u8, row.text(3)),
        .cover = try a.dupe(u8, row.text(4)),
        .price = row.int(5),
        .rtype = try a.dupe(u8, row.text(6)),
        .created_at = row.int(7),
    };
}

/// 幂等收藏（目标存在性由 handler 预检，UNIQUE 兜底并发重复）
pub fn add(dbh: *db.Db, user_id: i64, target_type: []const u8, target_id: i64, now: i64) !void {
    try dbh.exec(
        "INSERT OR IGNORE INTO favorites (user_id, target_type, target_id, created_at) VALUES (?1, ?2, ?3, ?4)",
        .{ user_id, target_type, target_id, now },
    );
}

pub fn remove(dbh: *db.Db, user_id: i64, target_type: []const u8, target_id: i64) !void {
    try dbh.exec(
        "DELETE FROM favorites WHERE user_id = ?1 AND target_type = ?2 AND target_id = ?3",
        .{ user_id, target_type, target_id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn list(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, target_type: []const u8, page: i64, size: i64) !ListResult {
    const where = " WHERE f.user_id = ?1 AND (?2 = '' OR f.target_type = ?2) AND " ++ fav_live;
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) " ++ fav_from ++ where,
        .{ user_id, target_type },
    )) orelse 0;

    var items: std.ArrayList(Favorite) = .empty;
    var rows = try dbh.conn.rows(
        fav_select ++ where ++ " ORDER BY f.id DESC LIMIT ?3 OFFSET ?4",
        .{ user_id, target_type, size, (page - 1) * size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToFavorite(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 集成测试

const favorites_ddl =
    \\CREATE TABLE IF NOT EXISTS favorites (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  target_type TEXT NOT NULL,
    \\  target_id INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, target_type, target_id)
    \\)
;

const resources_ddl =
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
;

pub const test_sqls = course_repo.test_sqls ++ [_][]const u8{ favorites_ddl, resources_ddl };

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

test "favorite_repo add idempotent / remove / list filters soft-deleted targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/crm_favorite_test.db");
    defer dbh.close();

    try dbh.exec("INSERT INTO courses (id, title, cover, price, deleted, created_at, updated_at) VALUES (11, 'C11', 'cv', 9900, 0, 1, 1)", .{});
    try dbh.exec("INSERT INTO resources (id, name, type, file_path, deleted, created_at) VALUES (21, 'R21', 'pdf', '/f', 0, 1)", .{});
    try dbh.exec("INSERT INTO resources (id, name, type, file_path, deleted, created_at) VALUES (22, 'R22', 'video', '/g', 1, 1)", .{});

    try add(&dbh, 5, "course", 11, 100);
    try add(&dbh, 5, "course", 11, 101); // 幂等
    try add(&dbh, 5, "resource", 21, 102);
    try add(&dbh, 5, "resource", 22, 103); // 目标已软删 → 列表隐身
    try std.testing.expectEqual(@as(i64, 3), try dbh.scalarInt("SELECT COUNT(*) FROM favorites WHERE user_id = 5", .{}) orelse 0); // 重复 add 被 IGNORE

    var r = try list(&dbh, a, 5, "", 1, 20);
    try std.testing.expectEqual(@as(i64, 2), r.total); // 物理 3 行，软删资料 22 隐身
    try std.testing.expectEqualStrings("R21", r.items.items[0].title); // id DESC
    try std.testing.expectEqualStrings("pdf", r.items.items[0].rtype);
    try std.testing.expectEqualStrings("C11", r.items.items[1].title);
    try std.testing.expectEqual(@as(i64, 9900), r.items.items[1].price);
    try std.testing.expectEqualStrings("cv", r.items.items[1].cover);

    r = try list(&dbh, a, 5, "course", 1, 20);
    try std.testing.expectEqual(@as(i64, 1), r.total);
    r = try list(&dbh, a, 6, "", 1, 20); // 他人不可见
    try std.testing.expectEqual(@as(i64, 0), r.total);

    try remove(&dbh, 5, "course", 11);
    try std.testing.expectError(error.NotFound, remove(&dbh, 5, "course", 11));
    r = try list(&dbh, a, 5, "", 1, 20);
    try std.testing.expectEqual(@as(i64, 1), r.total); // 仅剩 R21（22 隐身）

    // 目标课后续被软删 → 收藏隐身
    try dbh.exec("UPDATE courses SET deleted = 1 WHERE id = 11", .{});
    try dbh.exec("UPDATE resources SET deleted = 1 WHERE id = 21", .{});
    r = try list(&dbh, a, 5, "", 1, 20);
    try std.testing.expectEqual(@as(i64, 0), r.total);
}

test {
    std.testing.refAllDecls(@This());
}
