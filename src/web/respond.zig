//! 统一 JSON 响应包装：
//!   成功：{ "ok": true, "data": ... }
//!   失败：{ "ok": false, "error": { "code": "...", "message": "..." } }

const std = @import("std");
const framework = @import("http_framework");

pub fn ok(res: *framework.Response, data: anytype) !void {
    try res.json(.{ .ok = true, .data = data });
}

pub fn notFoundHandler(_: *framework.Context, res: *framework.Response) !void {
    _ = res.statusCode(.not_found);
    try res.json(.{
        .ok = false,
        .@"error" = .{ .code = "not_found", .message = "no such route" },
    });
}
