//! 管理后台：审计日志查询（真实数据，支持按用户筛选 + 分页）。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const audit_repo = @import("../../db/audit_repo.zig");
const respond = @import("../respond.zig");

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var user_id: i64 = 0;
    if (ctx.query("user_id")) |q| user_id = std.fmt.parseInt(i64, q, 10) catch 0;

    var page: i64 = 1;
    if (ctx.query("page")) |q| page = std.fmt.parseInt(i64, q, 10) catch 1;
    var size: i64 = 50;
    if (ctx.query("size")) |q| size = std.fmt.parseInt(i64, q, 10) catch 50;
    size = @max(1, @min(200, size));
    page = @max(1, page);

    var repo = audit_repo.AuditLogRepo.init(st.db);
    const r = try repo.list(ctx.arena, user_id, size, (page - 1) * size);
    try respond.ok(res, .{
        .items = r.items.items,
        .total = r.total,
        .page = page,
        .size = size,
    });
}