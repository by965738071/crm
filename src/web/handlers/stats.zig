//! 后台统计 handler（M-H H1，第 7 期）：首页概览计数。
//!
//! 口径见 stats_repo 注释（courses/questions 排除软删；新增用户按 UTC 日历日）。

const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const stats_repo = @import("../../db/stats_repo.zig");

pub fn overview(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    try respond.ok(res, try stats_repo.overview(st.db, common.nowSec(ctx)));
}
