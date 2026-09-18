//! courses / chapters / lessons 数据访问（分类见 category_repo.zig）。
//! 字符串 dupe 到调用方 allocator，行内存不越过当次迭代。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const colref = @import("colref.zig");

pub const Course = struct {
    id: i64,
    category_id: i64,
    title: []const u8,
    cover: []const u8,
    summary: []const u8,
    description: []const u8,
    price: i64,
    is_free: i64,
    status: []const u8, // draft/published
    sort: i64,
    enroll_count: i64,
    created_at: i64,
    updated_at: i64,
};

pub const Chapter = struct {
    id: i64,
    course_id: i64,
    title: []const u8,
    sort: i64,
};

pub const Lesson = struct {
    id: i64,
    course_id: i64,
    chapter_id: i64,
    title: []const u8,
    content_type: []const u8, // video/audio/pdf/markdown/rich
    resource_id: i64,
    content: []const u8,
    duration: i64,
    is_free: i64,
    sort: i64,
};

pub const CourseListOpts = struct {
    page: i64 = 1,
    size: i64 = 20,
    keyword: []const u8 = "",
    category_id: i64 = 0,
    /// true = 只列出已上架（公开接口）；false = 全部（管理后台）
    only_published: bool = false,
    /// 管理后台按状态过滤（listStatus 用）
    status: []const u8 = "",
    /// true = category_id 按分类子树过滤（配合递归 CTE）
    include_subtree: bool = false,
};

const course_cols = colref.cols(Course);
const chapter_cols = colref.cols(Chapter);
const lesson_cols = colref.cols(Lesson);

fn rowToCourse(row: zqlite.Row, a: std.mem.Allocator) !Course {
    return .{
        .id = row.int(0),
        .category_id = row.int(1),
        .title = try a.dupe(u8, row.text(2)),
        .cover = try a.dupe(u8, row.text(3)),
        .summary = try a.dupe(u8, row.text(4)),
        .description = try a.dupe(u8, row.text(5)),
        .price = row.int(6),
        .is_free = row.int(7),
        .status = try a.dupe(u8, row.text(8)),
        .sort = row.int(9),
        .enroll_count = row.int(10),
        .created_at = row.int(11),
        .updated_at = row.int(12),
    };
}

fn rowToChapter(row: zqlite.Row, a: std.mem.Allocator) !Chapter {
    return .{
        .id = row.int(0),
        .course_id = row.int(1),
        .title = try a.dupe(u8, row.text(2)),
        .sort = row.int(3),
    };
}

fn rowToLesson(row: zqlite.Row, a: std.mem.Allocator) !Lesson {
    return .{
        .id = row.int(0),
        .course_id = row.int(1),
        .chapter_id = row.int(2),
        .title = try a.dupe(u8, row.text(3)),
        .content_type = try a.dupe(u8, row.text(4)),
        .resource_id = row.int(5),
        .content = try a.dupe(u8, row.text(6)),
        .duration = row.int(7),
        .is_free = row.int(8),
        .sort = row.int(9),
    };
}

// ---------------------------------------------------------------- courses

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Course {
    const row = try dbh.conn.row(
        "SELECT " ++ course_cols ++ " FROM courses WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToCourse(r, a);
}

pub fn getByIdIncludingDeleted(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Course {
    const row = try dbh.conn.row("SELECT " ++ course_cols ++ " FROM courses WHERE id = ?1 LIMIT 1", .{id});
    const r = row orelse return null;
    defer r.deinit();
    return try rowToCourse(r, a);
}

pub fn create(
    dbh: *db.Db,
    category_id: i64,
    title: []const u8,
    cover: []const u8,
    summary: []const u8,
    description: []const u8,
    price: i64,
    is_free: i64,
    status: []const u8,
    sort: i64,
    now: i64,
) !i64 {
    try dbh.conn.exec(
        "INSERT INTO courses (category_id, title, cover, summary, description, price, is_free, status, sort, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)",
        .{ category_id, title, cover, summary, description, price, is_free, status, sort, now },
    );
    return dbh.lastInsertId();
}

pub fn update(
    dbh: *db.Db,
    id: i64,
    category_id: i64,
    title: []const u8,
    cover: []const u8,
    summary: []const u8,
    description: []const u8,
    price: i64,
    is_free: i64,
    status: []const u8,
    sort: i64,
    now: i64,
) !void {
    try dbh.conn.exec(
        "UPDATE courses SET category_id=?1, title=?2, cover=?3, summary=?4, description=?5, price=?6, is_free=?7, status=?8, sort=?9, updated_at=?10 WHERE id=?11 AND deleted=0",
        .{ category_id, title, cover, summary, description, price, is_free, status, sort, now, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn deleteSoft(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE courses SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub const CourseList = struct {
    items: std.ArrayList(Course),
    total: i64,
};

/// 分类维度课程计数（不含软删）。category_id=0 表示未分类。
pub const CategoryCount = struct {
    category_id: i64,
    count: i64,
};

pub fn countByCategory(dbh: *db.Db, a: std.mem.Allocator) ![]CategoryCount {
    var items: std.ArrayList(CategoryCount) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT category_id, COUNT(*) FROM courses WHERE deleted = 0 GROUP BY category_id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, .{ .category_id = row.int(0), .count = row.int(1) });
    }
    if (rows.err) |e| return e;
    return items.items;
}

// 子树过滤用 SQLite 递归 CTE：各套 SQL 全部在 comptime 拼成常量（参数个数一致 ?1..?6），
// 运行时只做常量选择。depth < 20 既覆盖正常层级，也防 categories 里出现父子环时无限递归。
const cte_subtree =
    "WITH RECURSIVE sub(id, depth) AS (" ++
    " SELECT ?3, 0" ++
    " UNION ALL" ++
    " SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id" ++
    " WHERE c.deleted = 0 AND s.depth < 20) ";

const order_limit = " ORDER BY sort, id DESC LIMIT ?5 OFFSET ?6";

// listStatus：?4 = status 文本参数
const cond_status_exact =
    "((?1 = '' OR title LIKE ?2 ESCAPE '\\' OR summary LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id = ?3) AND (?4 = '' OR status = ?4)) AND deleted = 0";
const cond_status_subtree =
    "((?1 = '' OR title LIKE ?2 ESCAPE '\\' OR summary LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id IN (SELECT id FROM sub)) AND (?4 = '' OR status = ?4)) AND deleted = 0";

const count_status_exact = "SELECT COUNT(*) FROM courses WHERE " ++ cond_status_exact;
const count_status_subtree = cte_subtree ++ "SELECT COUNT(*) FROM courses WHERE " ++ cond_status_subtree;
const rows_status_exact = "SELECT " ++ course_cols ++ " FROM courses WHERE " ++ cond_status_exact ++ order_limit;
const rows_status_subtree = cte_subtree ++ "SELECT " ++ course_cols ++ " FROM courses WHERE " ++ cond_status_subtree ++ order_limit;

// list：only_published 用 ?4 参数开关（=1 仅已上架，=0 全部）
const cond_pub_exact =
    "((?1 = '' OR title LIKE ?2 ESCAPE '\\' OR summary LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id = ?3) AND (?4 = 1 AND status = 'published' OR ?4 = 0)) AND deleted = 0";
const cond_pub_subtree =
    "((?1 = '' OR title LIKE ?2 ESCAPE '\\' OR summary LIKE ?2 ESCAPE '\\') AND (?3 = 0 OR category_id IN (SELECT id FROM sub)) AND (?4 = 1 AND status = 'published' OR ?4 = 0)) AND deleted = 0";

const count_pub_exact = "SELECT COUNT(*) FROM courses WHERE " ++ cond_pub_exact;
const count_pub_subtree = cte_subtree ++ "SELECT COUNT(*) FROM courses WHERE " ++ cond_pub_subtree;
const rows_pub_exact = "SELECT " ++ course_cols ++ " FROM courses WHERE " ++ cond_pub_exact ++ order_limit;
const rows_pub_subtree = cte_subtree ++ "SELECT " ++ course_cols ++ " FROM courses WHERE " ++ cond_pub_subtree ++ order_limit;

/// 管理后台专用：按状态过滤的全量列表（status="" 时等同 list only_published=false）
pub fn listStatus(dbh: *db.Db, a: std.mem.Allocator, opts: CourseListOpts) !CourseList {
    const total = (try dbh.scalarInt(
        if (opts.include_subtree) count_status_subtree else count_status_exact,
        .{ opts.keyword, try courseLikePattern(a, opts.keyword), opts.category_id, opts.status },
    )) orelse 0;
    var items: std.ArrayList(Course) = .empty;
    var rows = try dbh.conn.rows(
        if (opts.include_subtree) rows_status_subtree else rows_status_exact,
        .{ opts.keyword, try courseLikePattern(a, opts.keyword), opts.category_id, opts.status, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToCourse(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

fn courseLikePattern(a: std.mem.Allocator, kw: []const u8) ![]u8 {
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

pub fn list(dbh: *db.Db, a: std.mem.Allocator, opts: CourseListOpts) !CourseList {
    // only_published=1：仅已上架；=0：全部（含草稿）。用参数避免运行时拼 SQL。
    const only_published: i64 = if (opts.only_published) 1 else 0;

    const total = (try dbh.scalarInt(
        if (opts.include_subtree) count_pub_subtree else count_pub_exact,
        .{ opts.keyword, try courseLikePattern(a, opts.keyword), opts.category_id, only_published },
    )) orelse 0;

    var items: std.ArrayList(Course) = .empty;
    var rows = try dbh.conn.rows(
        if (opts.include_subtree) rows_pub_subtree else rows_pub_exact,
        .{ opts.keyword, try courseLikePattern(a, opts.keyword), opts.category_id, only_published, opts.size, (opts.page - 1) * opts.size },
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToCourse(row, a));
    }
    if (rows.err) |e| return e;
    return .{ .items = items, .total = total };
}

// ---------------------------------------------------------------- chapters

pub fn chaptersByCourse(dbh: *db.Db, a: std.mem.Allocator, course_id: i64) ![]Chapter {
    var items: std.ArrayList(Chapter) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ chapter_cols ++ " FROM chapters WHERE course_id = ?1 AND deleted = 0 ORDER BY sort DESC, id",
        .{course_id},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToChapter(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

pub fn chapterGetById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Chapter {
    const row = try dbh.conn.row(
        "SELECT " ++ chapter_cols ++ " FROM chapters WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToChapter(r, a);
}

pub fn chapterCreate(dbh: *db.Db, course_id: i64, title: []const u8, sort: i64) !i64 {
    try dbh.conn.exec(
        "INSERT INTO chapters (course_id, title, sort) VALUES (?1, ?2, ?3)",
        .{ course_id, title, sort },
    );
    return dbh.lastInsertId();
}

pub fn chapterUpdate(dbh: *db.Db, id: i64, title: []const u8, sort: i64) !void {
    try dbh.conn.exec("UPDATE chapters SET title = ?1, sort = ?2 WHERE id = ?3 AND deleted = 0", .{ title, sort, id });
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn chapterDelete(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE chapters SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

/// 删除章节时级联软删其下课时（不落外键，靠软删一致性）
pub fn lessonsDeleteByChapter(dbh: *db.Db, chapter_id: i64) !void {
    try dbh.conn.exec("UPDATE lessons SET deleted = 1 WHERE chapter_id = ?1 AND deleted = 0", .{chapter_id});
}

// ---------------------------------------------------------------- lessons

pub fn lessonsByCourse(dbh: *db.Db, a: std.mem.Allocator, course_id: i64) ![]Lesson {
    var items: std.ArrayList(Lesson) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ lesson_cols ++ " FROM lessons WHERE course_id = ?1 AND deleted = 0 ORDER BY sort DESC, id",
        .{course_id},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToLesson(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

pub fn lessonsByChapter(dbh: *db.Db, a: std.mem.Allocator, chapter_id: i64) ![]Lesson {
    var items: std.ArrayList(Lesson) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ lesson_cols ++ " FROM lessons WHERE chapter_id = ?1 AND deleted = 0 ORDER BY sort DESC, id",
        .{chapter_id},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToLesson(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

pub fn lessonGetById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Lesson {
    const row = try dbh.conn.row(
        "SELECT " ++ lesson_cols ++ " FROM lessons WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToLesson(r, a);
}

pub fn lessonCreate(
    dbh: *db.Db,
    course_id: i64,
    chapter_id: i64,
    title: []const u8,
    content_type: []const u8,
    resource_id: i64,
    content: []const u8,
    duration: i64,
    is_free: i64,
    sort: i64,
) !i64 {
    try dbh.conn.exec(
        "INSERT INTO lessons (course_id, chapter_id, title, content_type, resource_id, content, duration, is_free, sort) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        .{ course_id, chapter_id, title, content_type, resource_id, content, duration, is_free, sort },
    );
    return dbh.lastInsertId();
}

pub fn lessonUpdate(
    dbh: *db.Db,
    id: i64,
    course_id: i64,
    chapter_id: i64,
    title: []const u8,
    content_type: []const u8,
    resource_id: i64,
    content: []const u8,
    duration: i64,
    is_free: i64,
    sort: i64,
) !void {
    try dbh.conn.exec(
        "UPDATE lessons SET course_id=?1, chapter_id=?2, title=?3, content_type=?4, resource_id=?5, content=?6, duration=?7, is_free=?8, sort=?9 WHERE id=?10 AND deleted=0",
        .{ course_id, chapter_id, title, content_type, resource_id, content, duration, is_free, sort, id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
}

pub fn lessonDelete(dbh: *db.Db, id: i64) !void {
    try dbh.conn.exec("UPDATE lessons SET deleted = 1 WHERE id = ?1 AND deleted = 0", .{id});
    if (dbh.conn.changes() == 0) return error.NotFound;
}

/// 用户在某个课程下的报名状态（phase 3 报名逻辑接入；供课时锁定/下载鉴权用）
pub fn isEnrolled(dbh: *db.Db, user_id: i64, course_id: i64) !bool {
    if (user_id <= 0) return false;
    const row = try dbh.conn.row(
        "SELECT 1 FROM enrollments WHERE user_id = ?1 AND course_id = ?2 AND pay_status IN ('paid','free') LIMIT 1",
        .{ user_id, course_id },
    );
    const r = row orelse return false;
    defer r.deinit();
    return true;
}

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    for (test_sqls) |sql| try dbh.exec(sql, .{});
    try dbh.exec(test_sql_cats, .{});
    return dbh;
}

const test_sql_cats =
    \\CREATE TABLE IF NOT EXISTS categories (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  parent_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
;

test "course_repo courses/chapters/lessons lifecycle" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/course_repo_test.db");
    defer dbh.close();

    // 课程 CRUD
    const c1 = try create(&dbh, 1, "示例课程", "cover.jpg", "简介", "详情", 9900, 0, "published", 1, 100);
    try std.testing.expect(c1 > 0);
    _ = try create(&dbh, 2, "内科学（草稿）", "", "", "", 0, 1, "draft", 2, 101);

    const got = (try getById(&dbh, a, c1)).?;
    try std.testing.expectEqualStrings("示例课程", got.title);
    try std.testing.expectEqual(@as(i64, 9900), got.price);

    try update(&dbh, c1, 1, "示例课程（更新）", "c.jpg", "s", "d", 8800, 1, "published", 3, 200);
    const updated = (try getById(&dbh, a, c1)).?;
    try std.testing.expectEqualStrings("示例课程（更新）", updated.title);

    // 列表：published only / 关键字 / 分类
    const all = try list(&dbh, a, .{ .only_published = true });
    try std.testing.expectEqual(@as(i64, 1), all.total);
    const kw = try list(&dbh, a, .{ .keyword = "内科学" });
    try std.testing.expectEqual(@as(i64, 1), kw.total);
    _ = try list(&dbh, a, .{ .category_id = 999 });
    try std.testing.expectEqual(@as(i64, 0), (try list(&dbh, a, .{ .category_id = 999 })).total);

    // LIKE 通配转义
    const wild = try list(&dbh, a, .{ .keyword = "%" });
    try std.testing.expectEqual(@as(i64, 0), wild.total);

    // 分类树 1 -> 2 -> 3，子树过滤（c1 → cat1 已上架，c2 → cat2 草稿）
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (1, 0, '根'), (2, 1, '子'), (3, 2, '孙')", .{});
    _ = try create(&dbh, 3, "示例课程C", "", "", "", 0, 1, "published", 4, 102);
    // 精确：cat1 只有 c1；子树：cat1 含 cat1+cat2+cat3 全部 3 门
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 1 })).total);
    try std.testing.expectEqual(@as(i64, 3), (try list(&dbh, a, .{ .category_id = 1, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{ .category_id = 2, .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 1), (try list(&dbh, a, .{ .category_id = 3, .include_subtree = true })).total);
    // 子树 + 仅已上架：cat1 子树内 published 的是 c1 与新课（c2 草稿）
    try std.testing.expectEqual(@as(i64, 2), (try list(&dbh, a, .{ .only_published = true, .category_id = 1, .include_subtree = true })).total);
    // 子树 + 状态过滤（listStatus）
    try std.testing.expectEqual(@as(i64, 2), (try listStatus(&dbh, a, .{ .category_id = 1, .status = "published", .include_subtree = true })).total);
    try std.testing.expectEqual(@as(i64, 1), (try listStatus(&dbh, a, .{ .category_id = 1, .status = "draft", .include_subtree = true })).total);
    // 分类计数（未删）：cat1/cat2/cat3 各 1
    const stats = try countByCategory(&dbh, a);
    var found = std.AutoHashMap(i64, i64).init(a);
    defer found.deinit();
    for (stats) |s| try found.put(s.category_id, s.count);
    try std.testing.expectEqual(@as(?i64, 1), found.get(1));
    try std.testing.expectEqual(@as(?i64, 1), found.get(2));
    try std.testing.expectEqual(@as(?i64, 1), found.get(3));
    try std.testing.expectEqual(@as(?i64, null), found.get(99));

    // 章节
    const ch1 = try chapterCreate(&dbh, c1, "第一章 导论", 1);
    try std.testing.expect(ch1 > 0);
    _ = try chapterCreate(&dbh, c1, "第二章 藏象", 2);
    try chapterUpdate(&dbh, ch1, "第一章 绪论", 9);
    const chs = try chaptersByCourse(&dbh, a, c1);
    try std.testing.expectEqual(@as(usize, 2), chs.len);
    try std.testing.expectEqualStrings("第一章 绪论", chs[0].title);
    try std.testing.expectEqual(@as(i64, 9), chs[0].sort);

    // 课时
    const l1 = try lessonCreate(&dbh, c1, ch1, "五脏六腑", "markdown", 0, "# 内容", 120, 0, 1);
    try std.testing.expect(l1 > 0);
    const l2 = try lessonCreate(&dbh, c1, ch1, "免费课时", "markdown", 0, "# 免费", 60, 1, 2);
    try std.testing.expect(l2 > 0);
    try lessonUpdate(&dbh, l1, c1, ch1, "五脏六腑（改）", "video", 5, "", 300, 0, 3);

    const les = try lessonsByChapter(&dbh, a, ch1);
    try std.testing.expectEqual(@as(usize, 2), les.len);
    try std.testing.expectEqualStrings("五脏六腑（改）", les[0].title);

    // 段落删除
    try chapterDelete(&dbh, ch1);
    const after_del = try chaptersByCourse(&dbh, a, c1);
    try std.testing.expectEqual(@as(usize, 1), after_del.len);

    try std.testing.expectError(error.NotFound, update(&dbh, 9999, 1, "x", "", "", "", 0, 0, "draft", 0, 1));
    try std.testing.expectError(error.NotFound, deleteSoft(&dbh, 9999));
    try std.testing.expectError(error.NotFound, chapterUpdate(&dbh, 9999, "x", 0));
    try std.testing.expectError(error.NotFound, lessonUpdate(&dbh, 9999, 0, 0, "x", "video", 0, "", 0, 0, 0));

    // isEnrolled：未报名 false
    try std.testing.expect(!try isEnrolled(&dbh, 1, c1));
    try std.testing.expect(!try isEnrolled(&dbh, 0, c1));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/course_repo_test.db") catch {};
}

// ---------------------------------------------------------------------------

const courses_ddl =
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
;

const chapters_ddl =
    \\CREATE TABLE IF NOT EXISTS chapters (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  course_id INTEGER NOT NULL,
    \\  title TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
;

const lessons_ddl =
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
;

const enrollments_ddl =
    \\CREATE TABLE IF NOT EXISTS enrollments (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL,
    \\  course_id INTEGER NOT NULL,
    \\  source TEXT NOT NULL DEFAULT 'self',
    \\  pay_status TEXT NOT NULL DEFAULT 'unpaid',
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE(user_id, course_id)
    \\)
;

// zqlite 的 conn.exec 不允许单次多语句，测试逐条执行（与 migrate.zig 同策略）
pub const test_sqls = [_][]const u8{ courses_ddl, chapters_ddl, lessons_ddl, enrollments_ddl };
