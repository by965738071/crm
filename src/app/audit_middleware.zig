//! 审计日志中间件：记录所有用户操作（请求摘要 + 身份 + 目标对象）。
//!
//! 挂在全局管道（rt.use）上，捕获请求方法、路径、状态码摘要、
//! 当前用户身份（从 ctx.user_data 取）与对端 IP（框架 peer_ip），
//! 并写入 audit_logs 表。handler 出错（含鉴权失败）也会记录。
//!
//! 参考现有设计：框架 Middleware.init + SessionManager + ctx.setUserData 机制。

const std = @import("std");
const framework = @import("http_framework");
const identity = @import("../svc/identity.zig");
const audit_repo = @import("../db/audit_repo.zig");

pub const AuditLogMiddleware = struct {
    repo: *audit_repo.AuditLogRepo,
    allocator: std.mem.Allocator,

    pub fn init(repo: *audit_repo.AuditLogRepo, allocator: std.mem.Allocator) AuditLogMiddleware {
        return .{ .repo = repo, .allocator = allocator };
    }

    pub fn process(self: *AuditLogMiddleware, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        // 先执行请求（获取响应状态）；出错时记录错误再继续传播
        const result = next.call(ctx, res);

        // 提取当前用户身份（可选：未登录则 user_id = 0）
        var user_id: i64 = 0;
        if (ctx.getUserData(identity.CurrentUser)) |cu| {
            user_id = cu.id;
        }

        // 构造请求摘要：方法 + 路径 + 状态码（或错误名）
        const method_str = @tagName(ctx.request.method);
        const path = ctx.request.path;
        const summary = if (result) |_|
            try std.fmt.allocPrint(self.allocator, "{s} {s} -> {d}", .{ method_str, path, @intFromEnum(res.status) })
        else |err|
            try std.fmt.allocPrint(self.allocator, "{s} {s} -> ERROR {s}", .{ method_str, path, @errorName(err) });
        defer self.allocator.free(summary);

        // 请求参数（URL query 原始串，不含 '?'；写请求体不入库以防敏感信息泄漏）
        const query = ctx.request.query;
        // 响应状态码：正常路径取 res.status，出错时尚未设置，记 0
        const status: i64 = if (result) |_| @intFromEnum(res.status) else |_| 0;

        // 提取对端 IP（框架 Context.peer_ip 在 accept 时由内核注入）
        var ip_buf: [64]u8 = undefined;
        const ip = ctx.peerIpString(&ip_buf) orelse "unknown";

        // 记录审计日志（同步写入 SQLite）
        self.repo.log(self.allocator, ctx.io, user_id, "request", "request", 0, summary, query, status, ip) catch |err| {
            std.log.err("audit log failed: {s}", .{@errorName(err)});
        };

        // 出错时继续传播
        if (result) |_| {} else |err| return err;
    }
};
