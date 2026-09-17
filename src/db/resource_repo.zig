
const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");

pub const Resource = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    orig_name: []const u8,
    rtype: []const u8, // video/audio/pdf/doc/image/markdown
    file_path: []const u8,
    size: i64,
    mime: []const u8,
    uploader_id: i64,
    is_public: i64,
    created_at: i64,
};

pub const ResourceListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    category_id: i64 = 0,
    /// 为 true 且 category_id != 0 时，匹配该分类及其所有子孙分类下的资料
    include_subtree: bool = false,
    rtype: []const u8 = "",
    keyword: []const u8 = "",
};

const select_cols = "id, category_id, name, orig_name, type, file_path, size, mime, uploader_id, is_public, created_at";

fn rowToResource(row: zqlite.Row, a: std.mem.Allocator) !Resource {
    return .{
        .id = row.int(0),
        .category_id = row.int(1),
        .name = try a.dupe(u8, row.text(2)),
        .orig_name = try a.dupe(u8, row.text(3)),
        .rtype = try a.dupe(u8, row.text(4)),
        .file_path = try a.dupe(u8, row.text(5)),
        .size = row.int(6),
        .mime = try a.dupe(u8, row.text(7)),
        .uploader_id = row.int(8),
        .is_public = row.int(9),
        .created_at = row.int(10),
    };
}

pub fn create(
    dbh: *db.Db,
    category_id: i64,
    name: []const u8,
    orig_name: []const u8,
    rtype: []const u8,
    file_path: []const u8,
    size: i64,
    mime: []const u8,
    uploader_id: i64,
    is_public: i64,
    now: i64,
) !i64 {
    try dbh.conn.exec(
        "INSERT INTO resources (category_id, name, orig_name, type, file_path, size, mime, uploader_id, is_public, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
        .{ category_id, name, orig_name, rtype, file_path, size, mime, uploader_id, is_public, now },
    );
    return dbh.lastInsertId();
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Resource {
    const row = try dbh.conn.row(
        "SELECT " ++ select_cols ++ " FROM resources WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToResource(r, a);
}

pub fn update(
    dbh: *db.Db,
    id: i64,
    category_id: i64,
    name: []const u8,
    rtype: []const u8,
    is_public: i64,
) !void {
    try dbh.conn.exec(
        "UPDATE resources SET category_id = ?1, name = ?2, type = ?3, is_public = ?4 WHERE id = ?5 AND deleted = 0",
        .{ category_id, name, rtype, is_public, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE resources SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub const ResourceList = struct {
    items: std.ArrayList(Resource),
    total: i64,
};

/// 分类维度资料计数（不含软删）。category_id=0 表示未分类。
pub const CategoryCount = struct {
    category_id: i64,
    count: i64,
};

pub fn countByCategory(dbh: *db.Db, a: std.mem.Allocator) ![]CategoryCount {
    var items: std.ArrayList(CategoryCount) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT category_id, COUNT(*) FROM resources WHERE deleted = 0 GROUP BY category_id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{ .category_id = row.int(0), .count = row.int(1) });
    }
    if (rows.err) |e| return e;
    return items.items;
}

// 子树过滤用 SQLite 递归 CTE：两套 SQL 全部在 comptime 拼成常量（参数个数一致 ?1..?6），
// 运行时只做常量选择。depth < 20 既覆盖正常层级，也防 categories 里出现父子环时无限递归。
const cte_subtree =
    "WITH RECURSIVE sub(id, depth) AS (" ++
    " SELECT ?3, 0" ++
    " UNION ALL" ++
    " SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id" ++
    " WHERE c.deleted = 0 AND s.depth < 20) ";

const where_exact =
    "((?1 = '' OR name LIKE ?2 ESCAPE '\\' OR orig_name LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id = ?3) AND (?4 = '' OR type = ?4)) AND deleted = 0";

const where_subtree =
    "((?1 = '' OR name LIKE ?2 ESCAPE '\\' OR orig_name LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id IN (SELECT id FROM sub)) AND (?4 = '' OR type = ?4)) AND deleted = 0";

const public_and = " AND is_public = 1";
const order_limit = " ORDER BY id DESC LIMIT ?5 OFFSET ?6";

const count_exact = "SELECT COUNT(*) FROM resources WHERE " ++ where_exact;
const count_subtree = cte_subtree ++ "SELECT COUNT(*) FROM resources WHERE " ++ where_subtree;
const rows_exact = "SELECT " ++ select_cols ++ " FROM resources WHERE " ++ where_exact ++ order_limit;
const rows_subtree = cte_subtree ++ "SELECT " ++ select_cols ++ " FROM resources WHERE " ++ where_subtree ++ order_limit;

const count_public_exact = "SELECT COUNT(*) FROM resources WHERE " ++ where_exact ++ public_and;
const count_public_subtree = cte_subtree ++ "SELECT COUNT(*) FROM resources WHERE " ++ where_subtree ++ public_and;
const rows_public_exact = "SELECT " ++ select_cols ++ " FROM resources WHERE " ++ where_exact ++ public_and ++ order_limit;
const rows_public_subtree = cte_subtree ++ "SELECT " ++ select_cols ++ " FROM resources WHERE " ++ where_subtree ++ public_and ++ order_limit;

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

pub fn list(dbh: *db.Db, a: std.mem.Allocator, opts: ResourceListOpts) !ResourceList {
    const total = (try dbh.scalarInt(
        if (opts.include_subtree) count_subtree else count_exact,
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.category_id, opts.rtype },
    )) orelse 0;

    var items: std.ArrayList(Resource) = .empty;
    var rows = try dbh.conn.rows(
        if (opts.include_subtree) rows_subtree else rows_exact,
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.category_id, opts.rtype, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToResource(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

/// 游客可见列表：仅 is_public=1
pub fn listPublic(dbh: *db.Db, a: std.mem.Allocator, opts: ResourceListOpts) !ResourceList {
    const total = (try dbh.scalarInt(
        if (opts.include_subtree) count_public_subtree else count_public_exact,
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.category_id, opts.rtype },
    )) orelse 0;

    var items: std.ArrayList(Resource) = .empty;
    var rows = try dbh.conn.rows(
        if (opts.include_subtree) rows_public_subtree else rows_public_exact,
        .{ opts.keyword, try likePattern(a, opts.keyword), opts.category_id, opts.rtype, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToResource(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------------------

const test_sql =
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

const test_sql_cats =
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
    try dbh.exec(test_sql_cats, .{});
    return dbh;
}

test "resource_repo lifecycle + filters" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/resource_repo_test.db");
    defer dbh.close();

    const r1 = try create(&dbh, 1, "操作视频", "video.mp4", "video", "uploads/2026-09/a.mp4", 1024, "video/mp4", 1, 1, 100);
    try std.testing.expect(r1 > 0);
    _ = try create(&dbh, 2, "讲义", "doc.pdf", "pdf", "uploads/2026-09/b.pdf", 500, "application/pdf", 1, 0, 101);

    const got = (try getById(&dbh, a, r1)).?;
    try std.testing.expectEqualStrings("操作视频", got.name);
    try std.testing.expectEqualStrings("video/mp4", got.mime);

    try update(&dbh, r1, 1, "操作视频（改）", "video", 0);
    try std.testing.expectEqualStrings("操作视频（改）", (try getById(&dbh, a, r1)).?.name);

    // 过滤
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{})).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 2 })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .rtype = "video" })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .keyword = "讲义" })).total);
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .keyword = "%" })).total);

    // 分类树 1 -> 2 -> 3，子树过滤
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (1, 0, '根'), (2, 1, '子'), (3, 2, '孙')", .{});
    const r3 = try create(&dbh, 3, "孙子资料", "c.pdf", "pdf", "uploads/2026-09/c.pdf", 10, "application/pdf", 1, 1, 102);
    _ = r3;
    // 精确：cat1 只有 r1；子树：cat1 含 r1(cat1)+r2(cat2)+r3(cat3)
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 1 })).total);
    try std.testing.expectEqual(@as(i64, 3), (try list(&dbh, a, .{ .category_id = 1, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{ .category_id = 2, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 3, .include_subtree = true })).total);
    // 子树 + 其它过滤条件叠加
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{ .category_id = 1, .include_subtree = true, .rtype = "pdf" })).total);
    // listPublic 同样支持子树：此时公开且未删的只有 r3（r1 已改私密，r2 私密）
    try std.testing.expectEqual(@as(i64, 1), (try listPublic(&dbh, a, .{ .category_id = 1, .include_subtree = true })).total);

    try deleteSoft(&dbh, r1);
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{})).total);
    try std.testing.expect((try getById(&dbh, a, r1)) == null);

    // 分类计数（未删）：cat2 → 1，cat3 → 1
    const stats = try countByCategory(&dbh, a);
    var found = std.AutoHashMap(i64, i64).init(a);
    defer found.deinit();
    for (stats) |s| try found.put(s.category_id, s.count);
    try std.testing.expectEqual(@as(?i64, 1), found.get(2));
    try std.testing.expectEqual(@as(?i64, 1), found.get(3));
    try std.testing.expectEqual(@as(?i64, null), found.get(1));

    try std.testing.expectError(error.NotFound, update(&dbh, 9999, 0, "x", "video", 1));
    try std.testing.expectError(error.NotFound, deleteSoft(&dbh, 9999));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/resource_repo_test.db") catch {};
}
