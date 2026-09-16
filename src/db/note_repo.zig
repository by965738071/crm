//! 笔记（M-G G3）：按课程 / 课时记笔记，仅本人可见可改。
//!
//! 越权语义：update/delete/get 的 SQL 一律带 user_id 守卫，非本人笔记与不存在
//! 同样返回 error.NotFound（404），不暴露「存在但不可改」的信息。
//! 课程/资料软删不影响笔记可见性——笔记是用户自己的数据。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const course_repo = @import("course_repo.zig");

pub const max_content_len = 5000;

pub const Note = struct {
    id: i64,
    course_id: i64,
    lesson_id: i64,
    content: []const u8,
    course_title: []const u8,
    /// lesson_id=0（课程级笔记）时为空串
    lesson_title: []const u8,
    updated_at: i64,
    created_at: i64,
};

pub const ListResult = struct {
    items: std.ArrayList(Note),
    total: i64,
};

const note_cols =
    \\SELECT n.id, n.course_id, n.lesson_id, n.content,
    \\       COALESCE(c.title, ''), COALESCE(l.title, ''), n.updated_at, n.created_at
++ "\n";
const note_from =
    \\FROM notes n
    \\LEFT JOIN courses c ON c.id = n.course_id
    \\LEFT JOIN lessons l ON l.id = n.lesson_id
++ "\n";
const note_select = note_cols ++ note_from;

fn rowToNote(row: zqlite.Row, a: std.mem.Allocator) !Note {
    return .{
        .id = row.int(0),
        .course_id = row.int(1),
        .lesson_id = row.int(2),
        .content = try a.dupe(u8, row.text(3)),
        .course_title = try a.dupe(u8, row.text(4)),
        .lesson_title = try a.dupe(u8, row.text(5)),
        .updated_at = row.int(6),
        .created_at = row.int(7),
    };
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64, user_id: i64) !?Note {
    const row = try dbh.conn.row(
        note_select ++ " WHERE n.id = ?1 AND n.user_id = ?2 AND n.deleted = 0 LIMIT 1",
        .{ id, user_id },
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToNote(r, a);
}

/// lesson_id 合法性（归属该课程）由 handler 预检；course_id 存在性同理。
pub fn create(dbh: *db.Db, a: std.mem.Allocator, user_id: i64, course_id: i64, lesson_id: i64, content: []const u8, now: i64) !Note {
    try dbh.exec(
        "INSERT INTO notes (user_id, course_id, lesson_id, content, updated_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
        .{ user_id, course_id, lesson_id, content, now },
    );
    return (try getById(dbh, a, dbh.lastInsertId(), user_id)) orelse return error.BrokenData;
}

pub fn update(dbh: *db.Db, a: std.mem.Allocator, id: i64, user_id: i64, content: []const u8, now: i64) !Note {
    try dbh.exec(
        "UPDATE notes SET content = ?2, updated_at = ?3 WHERE id = ?1 AND user_id = ?4 AND deleted = 0",
        .{ id, content, now, user_id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
    return (try getById(dbh, a, id, user_id)) orelse return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64, user_id: i64) !void {
    try dbh.exec(
        "UPDATE notes SET deleted = 1 WHERE id = ?1 AND user_id = ?2 AND deleted = 0",
        .{ id, user_id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn list(
    dbh: *db.Db,
    a: std.mem.Allocator,
    user_id: i64,
    course_id: i64,
    lesson_id: i64,
    page: i64,
    size: i64,
) !ListResult {
    const where =
        \\ WHERE n.user_id = ?1 AND n.deleted = 0
        \\AND (?2 = 0 OR n.course_id = ?2) AND (?3 = 0 OR n.lesson_id = ?3)
    ;
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) " ++ note_from ++ where,
        .{ user_id, course_id, lesson_id },
    )) orelse 0;

    var items: std.ArrayList(Note) = .empty;
    var rows = try dbh.conn.rows(
        note_cols ++ note_from ++ where ++ " ORDER BY n.id DESC LIMIT ?4 OFFSET ?5",
        .{ user_id, course_id, lesson_id, size, (page - 1) * size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToNote(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 集成测试

const notes_ddl =
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
;

pub const test_sqls = course_repo.test_sqls ++ [_][]const u8{notes_ddl};

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

test "note_repo create / update / list filters / owner isolation / soft delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/crm_note_test.db");
    defer dbh.close();

    try dbh.exec("INSERT INTO courses (id, title, created_at, updated_at) VALUES (11, 'C11', 1, 1)", .{});
    try dbh.exec("INSERT INTO lessons (id, course_id, title) VALUES (31, 11, 'L31')", .{});

    var n = try create(&dbh, a, 5, 11, 31, "note one", 100);
    try std.testing.expectEqualStrings("C11", n.course_title);
    try std.testing.expectEqualStrings("L31", n.lesson_title);
    _ = try create(&dbh, a, 5, 11, 0, "course level", 110);
    _ = try create(&dbh, a, 5, 12, 0, "other course", 120); // course 不存在也行（表无 FK；handler 预检）
    _ = try create(&dbh, a, 6, 11, 0, "user 6 note", 130);

    var r = try list(&dbh, a, 5, 0, 0, 1, 20);
    try std.testing.expectEqual(@as(i64, 3), r.total);
    r = try list(&dbh, a, 5, 11, 0, 1, 20);
    try std.testing.expectEqual(@as(i64, 2), r.total);
    r = try list(&dbh, a, 5, 11, 31, 1, 20);
    try std.testing.expectEqual(@as(i64, 1), r.total);
    try std.testing.expectEqualStrings("note one", r.items.items[0].content);

    // 越权：他人笔记 update/delete → NotFound；get → null（同样 404 语义）
    try std.testing.expectError(error.NotFound, update(&dbh, a, n.id, 6, "hijack", 200));
    try std.testing.expectEqual(@as(?Note, null), try getById(&dbh, a, n.id, 6));
    try std.testing.expectError(error.NotFound, deleteSoft(&dbh, n.id, 6));

    n = try update(&dbh, a, n.id, 5, "note one v2", 210);
    try std.testing.expectEqualStrings("note one v2", n.content);
    try std.testing.expectEqual(@as(i64, 210), n.updated_at);
    try std.testing.expectEqual(@as(i64, 100), n.created_at);

    try deleteSoft(&dbh, n.id, 5);
    try std.testing.expectError(error.NotFound, deleteSoft(&dbh, n.id, 5)); // 幂等防护
    r = try list(&dbh, a, 5, 11, 0, 1, 20);
    try std.testing.expectEqual(@as(i64, 1), r.total);
    try std.testing.expectEqual(@as(?Note, null), try getById(&dbh, a, n.id, 5));
}

test {
    std.testing.refAllDecls(@This());
}
