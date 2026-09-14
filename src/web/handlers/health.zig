//! GET /api/health —— 存活 + 数据库连通性检查

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const respond = @import("../respond.zig");

pub fn handle(ctx: *framework.Context, res: *framework.Response) !void {
    // 框架注入的服务容器：启动时 appMain 把 *State 注册为 state.State 服务
    const st = ctx.service(state.State) orelse {
        try ctx.failWith(framework.AppError.internal("app not ready"));
        return;
    };

    // DB 探活：失败即视为不健康
    if (try st.db.scalarInt("SELECT 1", .{})) |_| {} else {
        try ctx.failWith(framework.AppError.internal("db unreachable"));
        return;
    }

    const now_ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    const uptime_s: i64 = @intCast(@divTrunc(now_ns - st.started_at_ns, std.time.ns_per_s));

    try respond.ok(res, .{
        .status = "ok",
        .uptime_seconds = uptime_s,
        .db = "sqlite",
        .schema_version = try st.db.schemaVersion(),
    });
}
