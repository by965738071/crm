//! 审计日志仓库：记录所有用户操作（请求摘要 + 身份 + 目标对象）。

const std = @import("std");
const db = @import("db.zig");

pub const AuditLogRepo = struct {
    dbh: *db.Db,

    pub fn init(dbh: *db.Db) AuditLogRepo {
        return .{ .dbh = dbh };
    }

    /// 记录审计日志（请求摘要由中间件构造，含方法+路径+状态码）
    /// query 为原始请求参数（不含 '?'），status 为响应状态码（出错时为 0）。
    pub fn log(self: *AuditLogRepo, allocator: std.mem.Allocator, io: std.Io, user_id: i64, action: []const u8, target_type: []const u8, target_id: i64, request_summary: []const u8, query: []const u8, status: i64, ip: []const u8) !void {
        _ = allocator;
        const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
        try self.dbh.exec(
            "INSERT INTO audit_logs (user_id, action, target_type, target_id, request_summary, query, status, ip, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            .{ user_id, action, target_type, target_id, request_summary, query, status, ip, now },
        );
    }

    /// 按用户查询审计日志（分页）。user_id <= 0 表示不按用户过滤。
    /// 返回的内存由调用方释放（items.items / toOwnedSlice）。
    pub fn list(self: *AuditLogRepo, a: std.mem.Allocator, user_id: i64, limit: i64, offset: i64) !ListResult {
        const total = (try self.dbh.scalarInt(
            "SELECT COUNT(*) FROM audit_logs WHERE (?1 <= 0 OR user_id = ?1)",
            .{user_id},
        )) orelse 0;

        var items: std.ArrayList(AuditLogRow) = .empty;
        var rows = try self.dbh.conn.rows(
            "SELECT id, user_id, action, target_type, target_id, request_summary, query, status, ip, created_at FROM audit_logs WHERE (?1 <= 0 OR user_id = ?1) ORDER BY id DESC LIMIT ?2 OFFSET ?3",
            .{ user_id, limit, offset },
        );
        defer rows.deinit();
        while (rows.next()) |row| {
            try items.append(a, .{
                .id = row.int(0),
                .user_id = row.int(1),
                .action = try a.dupe(u8, row.text(2)),
                .target_type = try a.dupe(u8, row.text(3)),
                .target_id = row.int(4),
                .request_summary = try a.dupe(u8, row.text(5)),
                .query = try a.dupe(u8, row.text(6)),
                .status = row.int(7),
                .ip = try a.dupe(u8, row.text(8)),
                .created_at = row.int(9),
            });
        }
        if (rows.err) |e| return e;
        return .{ .items = items, .total = total };
    }
};

pub const ListResult = struct {
    items: std.ArrayList(AuditLogRow),
    total: i64,
};

pub const AuditLogRow = struct {
    id: i64,
    user_id: i64,
    action: []const u8,
    target_type: []const u8,
    target_id: i64,
    request_summary: []const u8,
    query: []const u8,
    status: i64,
    ip: []const u8,
    created_at: i64,
};

// ---------------------------------------------------------------- 集成测试

const audit_logs_ddl =
    \\CREATE TABLE IF NOT EXISTS audit_logs (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  user_id INTEGER NOT NULL DEFAULT 0,
    \\  action TEXT NOT NULL,
    \\  target_type TEXT NOT NULL DEFAULT '',
    \\  target_id INTEGER NOT NULL DEFAULT 0,
    \\  request_summary TEXT NOT NULL DEFAULT '',
    \\  query TEXT NOT NULL DEFAULT '',
    \\  status INTEGER NOT NULL DEFAULT 0,
    \\  ip TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL
    \\)
;

fn openTestDb(a: std.mem.Allocator, path: [:0]const u8) !db.Db {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".test_data") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var dbh = try db.Db.open(a, path);
    try dbh.exec(audit_logs_ddl, .{});
    return dbh;
}

test "audit_repo log + list with user filter and pagination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbh = try openTestDb(a, ".test_data/audit_repo_test.db");
    defer dbh.close();
    var repo = AuditLogRepo.init(&dbh);

    try repo.log(a, std.testing.io, 1, "request", "request", 0, "GET /api/health -> 200", "", 200, "127.0.0.1");
    try repo.log(a, std.testing.io, 1, "request", "request", 0, "POST /api/auth/login -> 200", "", 200, "127.0.0.1");
    try repo.log(a, std.testing.io, 2, "request", "request", 0, "GET /api/courses -> 200", "category_id=3&sub=1", 200, "10.0.0.2");

    {
        var r = try repo.list(a, 1, 50, 0);
        defer r.items.deinit(a);
        try std.testing.expectEqual(@as(i64, 2), r.total);
        try std.testing.expectEqual(@as(usize, 2), r.items.items.len);
    }
    {
        // user_id <= 0 不过滤
        var r = try repo.list(a, 0, 50, 0);
        defer r.items.deinit(a);
        try std.testing.expectEqual(@as(i64, 3), r.total);
        try std.testing.expectEqual(@as(usize, 3), r.items.items.len);
        // query/status 字段正确回读（id DESC，最新一条在前）
        try std.testing.expectEqualStrings("category_id=3&sub=1", r.items.items[0].query);
        try std.testing.expectEqual(@as(i64, 200), r.items.items[0].status);
        try std.testing.expectEqual(@as(i64, 2), r.items.items[0].user_id);
    }
    {
        // 分页（limit 1）按 id DESC 返回最新一条（user 2）
        var r = try repo.list(a, 0, 1, 0);
        defer r.items.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
        try std.testing.expectEqual(@as(i64, 2), r.items.items[0].user_id);
    }
}

test {
    std.testing.refAllDecls(@This());
}