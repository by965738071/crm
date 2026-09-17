//! 公告域（M-G G1）：管理员发布/下架，学员端只读已发布。
//!
//! 状态机：draft ↔ published（unpublish 回 draft，published_at 保留原值；
//! 再次 publish 刷新）。deleted 软删独立于状态。
//! 约定同其他 repo：手写 SQL + 行读出 dupe 到 arena，单连接串行不加锁。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const colref = @import("colref.zig");

pub const statuses = [_][]const u8{ "draft", "published" };
pub const max_title_len = 128;
pub const max_content_len = 20000;

pub fn validStatus(s: []const u8) bool {
    for (statuses) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

pub const Announcement = struct {
    id: i64,
    title: []const u8,
    content: []const u8,
    status: []const u8,
    author_id: i64,
    /// 0 = 从未发布
    published_at: i64,
    created_at: i64,
};

// 列清单由 Announcement struct 编译期生成，避免手写串与字段漂移
const ann_cols = colref.cols(Announcement);

fn rowToAnnouncement(row: zqlite.Row, a: std.mem.Allocator) !Announcement {
    return .{
        .id = row.int(0),
        .title = try a.dupe(u8, row.text(1)),
        .content = try a.dupe(u8, row.text(2)),
        .status = try a.dupe(u8, row.text(3)),
        .author_id = row.int(4),
        .published_at = row.int(5),
        .created_at = row.int(6),
    };
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Announcement {
    const row = try dbh.conn.row(
        "SELECT " ++ ann_cols ++ " FROM announcements WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToAnnouncement(r, a);
}

// ---------------------------------------------------------------- 列表

pub const ListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    /// 管理端按状态过滤（'' = 全部；公开端不使用）
    status: []const u8 = "",
    keyword: []const u8 = "",
    /// true = 仅已发布（公开端）；false = 全部未删（管理端）
    only_published: bool = false,
};

pub const ListResult = struct {
    items: std.ArrayList(Announcement),
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
    const only_published: i64 = if (opts.only_published) 1 else 0;
    // ?1 only_published, ?2 status, ?3 keyword, ?4 like, ?5 size, ?6 offset
    const where =
        \\(?1 = 0 OR status = 'published') AND (?2 = '' OR status = ?2)
        \\AND (?3 = '' OR title LIKE ?4 ESCAPE '\' OR content LIKE ?4 ESCAPE '\') AND deleted = 0
    ;
    const pat = try likePattern(a, opts.keyword);
    const total = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM announcements WHERE" ++ where,
        .{ only_published, opts.status, opts.keyword, pat },
    )) orelse 0;

    var items: std.ArrayList(Announcement) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ ann_cols ++ " FROM announcements WHERE" ++ where ++ " ORDER BY published_at DESC, id DESC LIMIT ?5 OFFSET ?6",
        .{ only_published, opts.status, opts.keyword, pat, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToAnnouncement(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- 写路径

pub fn create(
    dbh: *db.Db,
    a: std.mem.Allocator,
    title: []const u8,
    content: []const u8,
    status: []const u8,
    author_id: i64,
    now: i64,
) !Announcement {
    const published_at: i64 = if (std.mem.eql(u8, status, "published")) now else 0;
    try dbh.exec(
        "INSERT INTO announcements (title, content, status, author_id, published_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        .{ title, content, status, author_id, published_at, now },
    );
    return (try getById(dbh, a, dbh.lastInsertId())) orelse return error.BrokenData;
}

/// 更新文案（发布状态只走 publish/unpublish，避免两处入口互相覆盖）
pub fn update(dbh: *db.Db, a: std.mem.Allocator, id: i64, title: []const u8, content: []const u8) !Announcement {
    try dbh.exec(
        "UPDATE announcements SET title = ?2, content = ?3 WHERE id = ?1 AND deleted = 0",
        .{ id, title, content },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
    return (try getById(dbh, a, id)) orelse return error.NotFound;
}

pub fn publish(dbh: *db.Db, a: std.mem.Allocator, id: i64, now: i64) !Announcement {
    try dbh.exec(
        "UPDATE announcements SET status = 'published', published_at = ?2 WHERE id = ?1 AND deleted = 0 AND status = 'draft'",
        .{ id, now },
    );
    if (dbh.conn.changes() == 0) return error.InvalidState;
    return (try getById(dbh, a, id)) orelse return error.NotFound;
}

pub fn unpublish(dbh: *db.Db, a: std.mem.Allocator, id: i64) !Announcement {
    try dbh.exec(
        "UPDATE announcements SET status = 'draft' WHERE id = ?1 AND deleted = 0 AND status = 'published'",
        .{id},
    );
    if (dbh.conn.changes() == 0) return error.InvalidState;
    return (try getById(dbh, a, id)) orelse return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64) !void {
    try dbh.exec("UPDATE announcements SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

// ---------------------------------------------------------------- 集成测试

const announcements_ddl =
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
;

pub const test_sqls = [_][]const u8{announcements_ddl};

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

test "announcement_repo create / publish / unpublish / list / delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/crm_announcement_test.db");
    defer dbh.close();

    var ann = try create(&dbh, a, "t1", "body one", "draft", 1, 100);
    try std.testing.expectEqualStrings("draft", ann.status);
    try std.testing.expectEqual(@as(i64, 0), ann.published_at);

    // 公开端：草稿隐身
    const pub0 = try list(&dbh, a, .{ .only_published = true });
    try std.testing.expectEqual(@as(i64, 0), pub0.total);
    // 直接改 published 只能走 publish（update 不动状态）
    ann = try update(&dbh, a, ann.id, "t1 v2", "body updated");
    try std.testing.expectEqualStrings("t1 v2", ann.title);
    try std.testing.expectEqualStrings("draft", ann.status);

    ann = try publish(&dbh, a, ann.id, 200);
    try std.testing.expectEqualStrings("published", ann.status);
    try std.testing.expectEqual(@as(i64, 200), ann.published_at);
    // 重复 publish → InvalidState
    try std.testing.expectError(error.InvalidState, publish(&dbh, a, ann.id, 201));
    // 公开端可见
    const pub1 = try list(&dbh, a, .{ .only_published = true });
    try std.testing.expectEqual(@as(i64, 1), pub1.total);

    // 第二条：按关键词检索（管理端）
    _ = try create(&dbh, a, "release notes", "upgrade abc", "published", 1, 300);
    const kw = try list(&dbh, a, .{ .keyword = "release" });
    try std.testing.expectEqual(@as(i64, 1), kw.total);
    const kw_body = try list(&dbh, a, .{ .keyword = "abc" });
    try std.testing.expectEqual(@as(i64, 1), kw_body.total);
    const only_pub = try list(&dbh, a, .{ .status = "published" });
    try std.testing.expectEqual(@as(i64, 2), only_pub.total);
    const only_draft0 = try list(&dbh, a, .{ .status = "draft" });
    try std.testing.expectEqual(@as(i64, 0), only_draft0.total);
    // 下架 → 公开端再次隐身
    _ = try unpublish(&dbh, a, ann.id);
    const pub2 = try list(&dbh, a, .{ .only_published = true });
    try std.testing.expectEqual(@as(i64, 1), pub2.total);
    const only_draft = try list(&dbh, a, .{ .status = "draft" });
    try std.testing.expectEqual(@as(i64, 1), only_draft.total);
    try std.testing.expectError(error.InvalidState, unpublish(&dbh, a, ann.id));

    // 软删 → getById 404、两个列表都隐身
    try deleteSoft(&dbh, ann.id);
    try std.testing.expectEqual(@as(?Announcement, null), try getById(&dbh, a, ann.id));
    try std.testing.expectError(error.InvalidState, publish(&dbh, a, ann.id, 400));
    const all = try list(&dbh, a, .{});
    try std.testing.expectEqual(@as(i64, 1), all.total);
}

test {
    std.testing.refAllDecls(@This());
}
