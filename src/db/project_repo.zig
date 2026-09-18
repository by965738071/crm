//! 专业（考试项目）表数据访问（projects）。
//! 一个专业 = 一棵分类子树：创建专业时自动生成根分类（root_category_id），
//! 课程/资料/题目/试卷通过挂在树下的 category_id 归属专业；
//! 内容表不加专业字段，归属由分类树推导，避免双份状态漂移。
//! 字符串 dupe 到调用方 allocator，行内存不越过当次迭代。

const std = @import("std");
const zqlite = @import("zqlite");
const db = @import("db.zig");
const colref = @import("colref.zig");

pub const Project = struct {
    id: i64,
    code: []const u8,
    name: []const u8,
    logo: []const u8,
    description: []const u8,
    subject_label: []const u8,
    sort: i64,
    status: []const u8, // active/disabled
    root_category_id: i64,
};

// 列清单由 Project struct 编译期生成；deleted/created_at/updated_at 不对外输出
const select_cols = colref.cols(Project);

fn rowToProject(row: zqlite.Row, a: std.mem.Allocator) !Project {
    return .{
        .id = row.int(0),
        .code = try a.dupe(u8, row.text(1)),
        .name = try a.dupe(u8, row.text(2)),
        .logo = try a.dupe(u8, row.text(3)),
        .description = try a.dupe(u8, row.text(4)),
        .subject_label = try a.dupe(u8, row.text(5)),
        .sort = row.int(6),
        .status = try a.dupe(u8, row.text(7)),
        .root_category_id = row.int(8),
    };
}

pub fn validStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "disabled");
}

/// 专业列表（未删）。only_active=true 时只出启用中的（公开端）。
pub fn findAll(dbh: *db.Db, a: std.mem.Allocator, only_active: bool) ![]Project {
    var items: std.ArrayList(Project) = .empty;
    var rows = try dbh.conn.rows(
        "SELECT " ++ select_cols ++ " FROM projects WHERE deleted = 0 AND (?1 = 0 OR status = 'active') ORDER BY sort, id",
        .{@as(i64, if (only_active) 1 else 0)},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try items.append(a, try rowToProject(row, a));
    }
    if (rows.err) |e| return e;
    return items.toOwnedSlice(a);
}

pub fn getById(dbh: *db.Db, a: std.mem.Allocator, id: i64) !?Project {
    const row = try dbh.conn.row(
        "SELECT " ++ select_cols ++ " FROM projects WHERE id = ?1 AND deleted = 0 LIMIT 1",
        .{id},
    );
    const r = row orelse return null;
    defer r.deinit();
    return try rowToProject(r, a);
}

/// code 是否已被占用（exclude_id 传 0 表示不排除）
pub fn codeTaken(dbh: *db.Db, code: []const u8, exclude_id: i64) !bool {
    const n = (try dbh.scalarInt(
        "SELECT COUNT(*) FROM projects WHERE code = ?1 AND id != ?2 AND deleted = 0",
        .{ code, exclude_id },
    )) orelse 0;
    return n > 0;
}

pub const CreateParams = struct {
    code: []const u8,
    name: []const u8,
    logo: []const u8,
    description: []const u8,
    subject_label: []const u8,
    sort: i64,
    now: i64,
};

/// 新建专业：自动创建同名根分类，两笔写入同事务。返回专业 id。
pub fn create(dbh: *db.Db, p: CreateParams) !i64 {
    try dbh.exec("BEGIN", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "INSERT INTO categories (parent_id, name, sort) VALUES (0, ?1, ?2)",
        .{ p.name, p.sort },
    );
    const root_id = dbh.lastInsertId();
    try dbh.exec(
        "INSERT INTO projects (code, name, logo, description, subject_label, sort, status, root_category_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?8, ?8)",
        .{ p.code, p.name, p.logo, p.description, p.subject_label, p.sort, root_id, p.now },
    );
    const id = dbh.lastInsertId();
    try dbh.exec("COMMIT", .{});
    return id;
}

pub const UpdateParams = struct {
    id: i64,
    code: []const u8,
    name: []const u8,
    logo: []const u8,
    description: []const u8,
    subject_label: []const u8,
    sort: i64,
    status: []const u8,
    now: i64,
};

/// 更新专业；改名时同步根分类名（两侧展示一致）。
pub fn update(dbh: *db.Db, p: UpdateParams) !void {
    try dbh.exec("BEGIN", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};

    try dbh.exec(
        "UPDATE projects SET code = ?1, name = ?2, logo = ?3, description = ?4, subject_label = ?5, sort = ?6, status = ?7, updated_at = ?8 WHERE id = ?9 AND deleted = 0",
        .{ p.code, p.name, p.logo, p.description, p.subject_label, p.sort, p.status, p.now, p.id },
    );
    if (dbh.conn.changes() == 0) return error.NotFound;
    try dbh.exec(
        "UPDATE categories SET name = ?1 WHERE id = (SELECT root_category_id FROM projects WHERE id = ?2)",
        .{ p.name, p.id },
    );
    try dbh.exec("COMMIT", .{});
}

/// 软删专业 + 其根分类（调用方须先确认树内无子分类/内容）。
pub fn deleteSoft(dbh: *db.Db, id: i64, now: i64) !void {
    const root_id = (try dbh.scalarInt(
        "SELECT root_category_id FROM projects WHERE id = ?1 AND deleted = 0",
        .{id},
    )) orelse return error.NotFound;

    try dbh.exec("BEGIN", .{});
    errdefer dbh.exec("ROLLBACK", .{}) catch {};
    try dbh.exec("UPDATE projects SET deleted = 1, updated_at = ?1 WHERE id = ?2", .{ now, id });
    try dbh.exec("UPDATE categories SET deleted = 1 WHERE id = ?1", .{root_id});
    try dbh.exec("COMMIT", .{});
}

/// 专业根分类下的未删子分类数（删除前置检查）
pub fn rootChildCount(dbh: *db.Db, root_id: i64) !i64 {
    return (try dbh.scalarInt(
        "SELECT COUNT(*) FROM categories WHERE parent_id = ?1 AND deleted = 0",
        .{root_id},
    )) orelse 0;
}

/// 专业子树内是否仍有内容（课程/资料/题目/试卷任一存在即 true）
pub fn subtreeHasContent(dbh: *db.Db, root_id: i64) !bool {
    const sql =
        \\WITH RECURSIVE sub(id, depth) AS (
        \\  SELECT ?1, 0
        \\  UNION ALL
        \\  SELECT c.id, s.depth + 1 FROM categories c JOIN sub s ON c.parent_id = s.id
        \\  WHERE c.deleted = 0 AND s.depth < 20)
        \\SELECT (EXISTS (SELECT 1 FROM courses WHERE deleted = 0 AND category_id IN (SELECT id FROM sub)) OR
        \\        EXISTS (SELECT 1 FROM resources WHERE deleted = 0 AND category_id IN (SELECT id FROM sub)) OR
        \\        EXISTS (SELECT 1 FROM questions WHERE deleted = 0 AND category_id IN (SELECT id FROM sub)) OR
        \\        EXISTS (SELECT 1 FROM exams WHERE deleted = 0 AND category_id IN (SELECT id FROM sub)))
    ;
    const n = try dbh.scalarInt(sql, .{root_id});
    return (n orelse 0) > 0;
}

// ---------------------------------------------------------------------------

const test_sql_projects =
    \\CREATE TABLE IF NOT EXISTS projects (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  code TEXT NOT NULL UNIQUE,
    \\  name TEXT NOT NULL,
    \\  logo TEXT NOT NULL DEFAULT '',
    \\  description TEXT NOT NULL DEFAULT '',
    \\  subject_label TEXT NOT NULL DEFAULT '科目',
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  status TEXT NOT NULL DEFAULT 'active',
    \\  root_category_id INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\)
;

// hasContent 查询只用到 category_id/deleted 两列，测试建最小表结构即可
const test_sql_min =
    \\CREATE TABLE IF NOT EXISTS categories (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  parent_id INTEGER NOT NULL DEFAULT 0,
    \\  name TEXT NOT NULL,
    \\  sort INTEGER NOT NULL DEFAULT 0,
    \\  deleted INTEGER NOT NULL DEFAULT 0
    \\)
;
const test_sql_content =
    \\CREATE TABLE IF NOT EXISTS courses (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
;
const test_sql_content2 =
    \\CREATE TABLE IF NOT EXISTS resources (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
;
const test_sql_content3 =
    \\CREATE TABLE IF NOT EXISTS questions (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
;
const test_sql_content4 =
    \\CREATE TABLE IF NOT EXISTS exams (id INTEGER PRIMARY KEY, category_id INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
;

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    try dbh.exec(test_sql_min, .{});
    try dbh.exec(test_sql_projects, .{});
    try dbh.exec(test_sql_content, .{});
    try dbh.exec(test_sql_content2, .{});
    try dbh.exec(test_sql_content3, .{});
    try dbh.exec(test_sql_content4, .{});
    return dbh;
}

test "project_repo create/update/delete + subtree content check" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();

    var dbh = try openTestDb(a, ".test_data/project_repo_test.db");
    defer dbh.close();

    const id = try create(&dbh, .{
        .code = "exam-a",
        .name = "考试甲",
        .logo = "",
        .description = "示例专业",
        .subject_label = "科目",
        .sort = 1,
        .now = 100,
    });
    try std.testing.expect(id > 0);

    const got = (try getById(&dbh, a, id)).?;
    try std.testing.expectEqualStrings("exam-a", got.code);
    try std.testing.expect(got.root_category_id > 0);
    try std.testing.expectEqualStrings("active", got.status);

    // 根分类同名，且在根分类挂子分类/内容
    {
        const r = (try dbh.conn.row("SELECT name FROM categories WHERE id = ?1", .{got.root_category_id})).?;
        defer r.deinit();
        try std.testing.expectEqualStrings("考试甲", r.text(0));
    }
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (50, ?1, '科目一')", .{got.root_category_id});
    try std.testing.expectEqual(@as(i64, 1), try rootChildCount(&dbh, got.root_category_id));
    try std.testing.expectEqual(false, try subtreeHasContent(&dbh, got.root_category_id));

    // 子树深处挂一门课程 → hasContent 变 true（孙分类也覆盖）
    try dbh.exec("INSERT INTO categories (id, parent_id, name) VALUES (51, 50, '科目一之第二章')", .{});
    try dbh.exec("INSERT INTO courses (id, category_id) VALUES (9, 51)", .{});
    try std.testing.expectEqual(true, try subtreeHasContent(&dbh, got.root_category_id));

    // 改名同步根分类
    try update(&dbh, .{
        .id = id,
        .code = "exam-a",
        .name = "考试甲（改）",
        .logo = "",
        .description = "d",
        .subject_label = "章节",
        .sort = 2,
        .status = "disabled",
        .now = 200,
    });
    const upd = (try getById(&dbh, a, id)).?;
    try std.testing.expectEqualStrings("考试甲（改）", upd.name);
    try std.testing.expectEqualStrings("disabled", upd.status);
    {
        const r = (try dbh.conn.row("SELECT name FROM categories WHERE id = ?1", .{upd.root_category_id})).?;
        defer r.deinit();
        try std.testing.expectEqualStrings("考试甲（改）", r.text(0));
    }

    // 公开列表过滤 disabled
    try std.testing.expectEqual(@as(usize, 0), (try findAll(&dbh, a, true)).len);
    try std.testing.expectEqual(@as(usize, 1), (try findAll(&dbh, a, false)).len);

    // code 占用检查（排除自身）
    try std.testing.expectEqual(true, try codeTaken(&dbh, "exam-a", 0));
    try std.testing.expectEqual(false, try codeTaken(&dbh, "exam-a", id));

    // 软删：专业与其根分类同时隐身
    try deleteSoft(&dbh, id, 300);
    try std.testing.expect((try getById(&dbh, a, id)) == null);
    try std.testing.expectEqual(@as(?i64, 1), try dbh.scalarInt("SELECT deleted FROM categories WHERE id = ?1", .{upd.root_category_id}));
    try std.testing.expectError(error.NotFound, deleteSoft(&dbh, 9999, 300));

    std.Io.Dir.cwd().deleteFile(std.testing.io, ".test_data/project_repo_test.db") catch {};
}
