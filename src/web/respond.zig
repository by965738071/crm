//! 统一 JSON 响应包装：
//!   成功：{ "ok": true, "data": ... }
//!   失败：{ "ok": false, "error": { "code": "...", "message": "..." } }

const std = @import("std");
const framework = @import("http_framework");

pub fn ok(res: *framework.Response, data: anytype) !void {
    try res.json(.{ .ok = true, .data = data });
}

/// SPA 回退（第 8 期）：非 /api 的 GET 深链（如 /courses/5）路由表命中不了，
/// 统一返回前端入口 index.html（启动时读入内存，随进程常驻），
/// 由 vue-router 接管路径。/api/* 与其他方法仍走 JSON 404。
/// 前端未构建（index.html 缺失/为空）时退回 JSON 404，不影响后端冒烟。
pub const SpaFallback = struct {
    html: []const u8 = "",

    pub fn handle(self: *SpaFallback, ctx: *framework.Context, res: *framework.Response) !void {
        const p = ctx.request.path;
        if (self.html.len > 0 and ctx.request.method == .GET and
            !std.mem.startsWith(u8, p, "/api"))
        {
            try res.html(self.html);
            return;
        }
        _ = res.statusCode(.not_found);
        try res.json(.{
            .ok = false,
            .@"error" = .{ .code = "not_found", .message = "no such route" },
        });
    }
};

pub fn notFoundHandler(_: *framework.Context, res: *framework.Response) !void {
    _ = res.statusCode(.not_found);
    try res.json(.{
        .ok = false,
        .@"error" = .{ .code = "not_found", .message = "no such route" },
    });
}
