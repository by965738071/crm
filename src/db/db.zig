//! SQLite 访问层（zqlite 直连）。
//!
//! 并发模型：zio 运行时是单线程协程调度，sqlite 调用之间不会让出，
//! 因此 Conn 不需要加锁。T0.7 会专项验证该假设（并发压测 + 见 plan.md 风险表）。

const std = @import("std");
const zqlite = @import("zqlite");

pub const DbError = error{SqlTooLong};

pub const Db = struct {
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Db {
        const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
        errdefer conn.close();
        var self = Db{ .allocator = allocator, .conn = conn };

        try conn.busyTimeout(5000);
        // WAL：读不阻塞写；foreign_keys：外键约束默认是关的，必须显式打开
        // （失败时 errdefer 统一 close，不要在这里重复关闭）
        self.conn.exec("PRAGMA foreign_keys = ON", .{}) catch |err| {
            std.log.err("db: PRAGMA foreign_keys failed: {s}", .{@errorName(err)});
            return err;
        };
        if (try self.conn.row("PRAGMA foreign_keys", .{})) |fk_row| {
            defer fk_row.deinit();
            if (fk_row.int(0) != 1) {
                std.log.err("db: foreign_keys not enabled", .{});
                return error.InvalidState;
            }
        }
        if (try self.conn.row("PRAGMA journal_mode = WAL", .{})) |row| {
            row.deinit();
        }
        return self;
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }

    pub fn exec(self: *Db, sql: []const u8, values: anytype) !void {
        try self.conn.exec(sql, values);
    }

    /// 取单行单列整数；无结果行时返回 null
    pub fn scalarInt(self: *Db, sql: []const u8, values: anytype) !?i64 {
        const row = try self.conn.row(sql, values) orelse return null;
        defer row.deinit();
        return row.int(0);
    }

    pub fn lastInsertId(self: *Db) i64 {
        return self.conn.lastInsertedRowId();
    }

    /// 当前 schema 版本（PRAGMA user_version）
    pub fn schemaVersion(self: *Db) !u32 {
        const v = try self.scalarInt("PRAGMA user_version", .{});
        return @intCast(v orelse 0);
    }

    pub fn setSchemaVersion(self: *Db, v: u32) !void {
        // PRAGMA 不支持参数绑定；版本是整数，拼接安全
        var buf: [64]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "PRAGMA user_version = {d}", .{v}) catch return error.SqlTooLong;
        try self.conn.exec(sql, .{});
    }
};
