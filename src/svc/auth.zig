//! 认证业务：密码哈希/校验、登录防暴力计数、当前用户上下文类型。

const std = @import("std");

/// AuthRequired 中间件写入 ctx.user_data 的当前用户（登录态的最小可信集）。
pub const CurrentUser = struct {
    id: i64,
    role: []const u8,
};

pub const admin_roles = [_][]const u8{ "admin", "superadmin" };

pub fn isAdminRole(role: []const u8) bool {
    for (admin_roles) |r| {
        if (std.mem.eql(u8, role, r)) return true;
    }
    return false;
}

pub const password_min_len = 8;
pub const password_max_len = 128;

/// argon2id 哈希（OWASP 参数）。返回可打印串，可直接入库。
pub fn hashPassword(a: std.mem.Allocator, io: std.Io, password: []const u8) ![]const u8 {
    var buf: [512]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password, .{
        .allocator = a,
        .params = .owasp_2id,
        .mode = .argon2id,
    }, &buf, io);
    return a.dupe(u8, hash);
}

/// 校验；哈希格式错误/不匹配一律返回 false（不区分，避免探测）。
pub fn verifyPassword(io: std.Io, hash: []const u8, password: []const u8) bool {
    std.crypto.pwhash.argon2.strVerify(hash, password, .{
        .allocator = std.heap.page_allocator,
    }, io) catch return false;
    return true;
}

/// 登录防暴力：按账号滑动窗口计数，超限锁定。
/// 进程内内存态（重启即清空；本期单实例部署可接受，见 plan.md 第 11 节）。
/// 并发假设同 Db：zio 单线程协程、方法内不让出，不加锁。
pub const LoginGuard = struct {
    const Attempt = struct {
        fails: u32 = 0,
        window_start: i64 = 0,
        locked_until: i64 = 0,
    };

    const max_fails: u32 = 5;
    const window_sec: i64 = 15 * 60;
    const lock_sec: i64 = 15 * 60;

    map: std.StringHashMap(Attempt),

    pub fn init(a: std.mem.Allocator) LoginGuard {
        return .{ .map = std.StringHashMap(Attempt).init(a) };
    }

    pub fn deinit(self: *LoginGuard) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.map.allocator.free(k.*);
        self.map.deinit();
    }

    /// 是否允许对该账号继续尝试登录。
    pub fn allow(self: *LoginGuard, now: i64, account: []const u8) bool {
        const at = self.map.getPtr(account) orelse return true;
        if (at.locked_until > now) return false;
        // 滑动窗口到期：重置
        if (now - at.window_start > window_sec) {
            at.fails = 0;
            at.window_start = now;
        }
        return true;
    }

    /// 记录一次失败；达到阈值即上锁。
    pub fn recordFailure(self: *LoginGuard, now: i64, account: []const u8) !void {
        const owned = try self.map.allocator.dupe(u8, account);
        errdefer self.map.allocator.free(owned);
        const gop = try self.map.getOrPut(owned);
        if (gop.found_existing) {
            self.map.allocator.free(owned); // key 归 map 里已有条目
        }
        const at = gop.value_ptr;
        if (at.window_start == 0 or now - at.window_start > window_sec) {
            at.window_start = now;
            at.fails = 0;
        }
        at.fails += 1;
        if (at.fails >= max_fails) {
            at.locked_until = now + lock_sec;
        }
    }

    /// 登录成功后清零。
    pub fn reset(self: *LoginGuard, account: []const u8) void {
        if (self.map.fetchRemove(account)) |kv| {
            self.map.allocator.free(kv.key);
        }
    }
};

// ---------------------------------------------------------------------------

test "hashPassword/verifyPassword" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const hash = try hashPassword(arena.allocator(), io, "S3cret!pw");
    try std.testing.expect(verifyPassword(io, hash, "S3cret!pw"));
    try std.testing.expect(!verifyPassword(io, hash, "wrong"));
    try std.testing.expect(!verifyPassword(io, "garbage-hash", "whatever"));
}

test "LoginGuard locks after 5 failures and unlocks" {
    var guard = LoginGuard.init(std.testing.allocator);
    defer guard.deinit();

    const now: i64 = 1_000_000;
    try std.testing.expect(guard.allow(now, "a@b.com"));
    var i: u32 = 0;
    while (i < 5) : (i += 1) try guard.recordFailure(now, "a@b.com");
    try std.testing.expect(!guard.allow(now, "a@b.com"));
    try std.testing.expect(!guard.allow(now + 15 * 60 - 1, "a@b.com"));
    try std.testing.expect(guard.allow(now + 15 * 60, "a@b.com"));

    // 成功登录清零
    try guard.recordFailure(now, "c@d.com");
    guard.reset("c@d.com");
    var j: u32 = 0;
    while (j < 4) : (j += 1) try guard.recordFailure(now, "c@d.com");
    try std.testing.expect(guard.allow(now, "c@d.com")); // 重置后累计 4 次未锁
}
