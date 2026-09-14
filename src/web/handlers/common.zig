//! 各业务 handler 的通用小工具：JSON 读取、时间、路径参数解析、分页解析。

const std = @import("std");
const framework = @import("http_framework");

/// 解析 JSON 请求体（上限 1MB，忽略未知字段）。调用方 catch 成 400。
pub fn readJson(comptime T: type, ctx: *framework.Context) !T {
    const body = try ctx.readBody(ctx.arena, 1 << 20);
    const parsed = std.json.parseFromSlice(T, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch
        return error.BadJson;
    return parsed.value;
}

pub fn nowSec(ctx: *framework.Context) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_s));
}

/// 解析 `:param` 路径参数成 i64；缺参/非法 → 写 400 响应并返回 false（调用方 return）。
pub fn parseId(ctx: *framework.Context, param_name: []const u8, out: *i64) !bool {
    const raw = ctx.param(param_name) orelse {
        const msg = try std.fmt.allocPrint(ctx.arena, "缺少路径参数 {s}", .{param_name});
        try ctx.failWith(framework.AppError.badRequest(msg));
        return false;
    };
    out.* = std.fmt.parseInt(i64, raw, 10) catch {
        try ctx.failWith(framework.AppError.badRequest("路径参数无效"));
        return false;
    };
    return true;
}

pub fn parseQueryInt(ctx: *framework.Context, key: []const u8, default: i64, max: i64, min_value: i64) i64 {
    const q = ctx.query(key) orelse return default;
    const v = std.fmt.parseInt(i64, q, 10) catch return default;
    return std.math.clamp(v, min_value, max);
}