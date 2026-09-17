//! 分类表数据访问（categories）。
//! 字符串 dupe 到调用方 allocator，行内存不越过当次迭代。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const colref = @import("colref.zig");

pub const Category = struct {
    id: i64,
    parent_id: i64,
    name: []const u8,
    sort: i64,
    deleted: i64,
};

// 列清单由 Category struct 编译期生成，避免手写串与字段漂移
const select_cols = colref.cols(Category);

fn rowToCategory(row: zqlite.Row, a: std.mem.Allocator) !Category {
    return .{
        .id = row.int(0),
        .parent_id = row.int(1),
        .name = try a.dupe(u8, row.text(2)),
        .sort = row.int(3),
        .deleted = row.int(4),
    };
}

pub fn create(dbh: *db.Db, a: std.mem.Allocator, parent_id: i64, name: []const u8, sort: i64) !i64 {
    _ = a;
    try dbh.conn.exec(
        "INSERT INTO categories (parent_id, name, sort) VALUES (?1, ?2, ?3)",
        .{ parent_id, name, sort },
    );
    return dbh.lastInsertId();
}

pub fn update(dbh: *db.Db, a: std.mem.Allocator, id: i64, parent_id: i64, name: []const u8, sort: i64) !void {
    _ = a;
    try dbh.conn.exec(
        "UPDATE categories SET parent_id = ?1, name = ?2, sort = ?3 WHERE id = ?4",
        .{ parent_id, name, sort, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn delete(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE categories SET deleted = 1 WHERE id = ?1", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn findAll(dbh: *db.Db, a: std.mem.Allocator) ![]Category {
    var items: std.ArrayList(Category) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ select_cols ++ " FROM categories WHERE deleted = 0 ORDER BY sort, id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToCategory(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Category {
    const row = try dbh.conn.row(
        "SELECT " ++ select_cols ++ " FROM categories WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToCategory(r, a);
}

// ---------------------------------------------------------------------------

const test_sql =
    \\CREATE TABLE IF NOT EXISTS categories (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  parent_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
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

test "category_repo create/get/update/findAll/delete" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/category_repo_test.db");
    defer dbh.close();

    const id1 = try create(&dbh, a, 0, "临床执业医师", 1);
    try std.testing.expect(id1 > 0);
    const id2 = try create(&dbh, a, id1, "内科学", 2);

    const got = (try getById(&dbh, a, id2)).?;
    try std.testing.expectEqualStrings("内科学", got.name);
    try std.testing.expectEqual(id1, got.parent_id);
    try std.testing.expectEqual(@as(i64, 2), got.sort);

    try update(&dbh, a, id2, id1, "外科学", 5);
    const updated = (try getById(&dbh, a, id2)).?;
    try std.testing.expectEqualStrings("外科学", updated.name);
    try std.testing.expectEqual(@as(i64, 5), updated.sort);

    const all = try findAll(&dbh, a);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("临床执业医师", all[0].name);

    try delete(&dbh, id2);
    const after_del = try findAll(&dbh, a);
    try std.testing.expectEqual(@as(usize, 1), after_del.len);

    try std.testing.expectError(error.NotFound, update(&dbh, a, 9999, 0, "x", 0));
    try std.testing.expectError(error.NotFound, delete(&dbh, 9999));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/category_repo_test.db") catch {};
}
