//! 订单 handler（M-F，第 6 期）：学员订单列表 + 管理端订单管理（列表/代下单/标记支付/取消）。
//!
//! 权限：学员端挂 AuthRequired（user_id 强制为本人，杜绝越权读他人订单）；
//! 管理端挂 AuthRequired{admin_only}。支付/取消是管理端登记线下收款的动作，
//! 学员端只读（§7 未列取消入口，按 F2「管理员标记支付/取消」语义收敛到 admin 侧）。
//! 金额单位为分（与 courses.price 同口径），换算展示属前端。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const common = @import("common.zig");
const respond = @import("../respond.zig");
const order_repo = @import("../../db/order_repo.zig");
const course_repo = @import("../../db/course_repo.zig");
const user_repo = @import("../../db/user_repo.zig");

const max_pay_method_len = 32;
const max_remark_len = 255;

/// ?status= 查询参数：空 = 不过滤；非法 → 400。
fn statusFilter(ctx: *framework.Context) ![]const u8 {
    const s = ctx.query("status") orelse "";
    if (s.len != 0 and !order_repo.validStatus(s)) {
        try ctx.failWith(framework.AppError.badRequest("status 仅支持 pending/paid/cancelled"));
        unreachable; // failWith 永远以 error 返回
    }
    return s;
}

// ---------------------------------------------------------------- 学员端

pub fn myOrders(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const status = try statusFilter(ctx);

    const r = try order_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .user_id = cu.id, // 强制本人；keyword 不透出（学员只查自己，无需求）
        .status = status,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

// ---------------------------------------------------------------- 管理端

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const status = try statusFilter(ctx);
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";
    const user_id = common.parseQueryInt(ctx, "user_id", 0, 1 << 40, 0);

    const r = try order_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .user_id = user_id,
        .status = status,
        .keyword = keyword,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

const CreateBody = struct {
    user_id: i64 = 0,
    course_id: i64 = 0,
};

/// 代下单：为指定学员建报名（unpaid，source=admin）+ pending 订单；只限付费上架课。
pub fn adminCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    const body = common.readJson(CreateBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.user_id <= 0 or body.course_id <= 0)
        return ctx.failWith(framework.AppError.badRequest("user_id 与 course_id 必填"));

    const user = (try user_repo.getById(st.db, ctx.arena, body.user_id)) orelse
        return ctx.failWith(framework.AppError.notFound("用户不存在"));
    if (!std.mem.eql(u8, user.status, "active"))
        return ctx.failWith(framework.AppError.badRequest("用户已被禁用"));

    const course = (try course_repo.getById(st.db, ctx.arena, body.course_id)) orelse
        return ctx.failWith(framework.AppError.notFound("课程不存在"));
    if (!std.mem.eql(u8, course.status, "published"))
        return ctx.failWith(framework.AppError.badRequest("课程未上架"));

    const order = order_repo.createByAdmin(st.db, ctx.arena, body.user_id, course, cu.id, common.nowSec(ctx)) catch |err| switch (err) {
        error.FreeCourse => return ctx.failWith(framework.AppError.badRequest("免费课程无需代下单")),
        error.AlreadyEnrolled => return ctx.failWith(framework.AppError.badRequest("该用户已报名此课程")),
        else => return err,
    };
    try respond.ok(res, order);
}

const PayBody = struct {
    pay_method: []const u8 = "",
    remark: []const u8 = "",
};

pub fn adminPay(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const body = common.readJson(PayBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.pay_method.len > max_pay_method_len)
        return ctx.failWith(framework.AppError.badRequest("pay_method 最长 32 字符"));
    if (body.remark.len > max_remark_len)
        return ctx.failWith(framework.AppError.badRequest("remark 最长 255 字符"));

    const order = try mustPending(ctx, st, id);

    const updated = order_repo.markPaid(st.db, ctx.arena, .{
        .order_id = order.id,
        .pay_method = body.pay_method,
        .remark = body.remark,
        .operator_id = cu.id,
        .now = common.nowSec(ctx),
    }) catch |err| switch (err) {
        error.InvalidState => return ctx.failWith(framework.AppError.badRequest("仅待支付订单可标记支付，请刷新后重试")),
        else => return err,
    };
    try respond.ok(res, updated);
}

const CancelBody = struct {
    remark: []const u8 = "",
};

pub fn adminCancel(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    const body = common.readJson(CancelBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (body.remark.len > max_remark_len)
        return ctx.failWith(framework.AppError.badRequest("remark 最长 255 字符"));

    const order = try mustPending(ctx, st, id);

    const updated = order_repo.cancel(st.db, ctx.arena, order.id, cu.id, body.remark) catch |err| switch (err) {
        error.InvalidState => return ctx.failWith(framework.AppError.badRequest("仅待支付订单可取消，请刷新后重试")),
        else => return err,
    };
    try respond.ok(res, updated);
}

/// 读取订单并校验处于 pending：不存在 → 404；已支付/已取消 → 400（文案区分终态）。
/// 状态机守卫在 repo 的 UPDATE ... WHERE status='pending' 里兜底，这里预检只为友好文案。
fn mustPending(ctx: *framework.Context, st: *state.State, id: i64) !order_repo.Order {
    const order = (try order_repo.getById(st.db, ctx.arena, id)) orelse {
        try ctx.failWith(framework.AppError.notFound("订单不存在"));
        unreachable; // failWith 永远以 error 返回
    };
    if (std.mem.eql(u8, order.status, "paid")) {
        try ctx.failWith(framework.AppError.badRequest("该订单已支付，不可再操作"));
        unreachable;
    }
    if (std.mem.eql(u8, order.status, "cancelled")) {
        try ctx.failWith(framework.AppError.badRequest("该订单已取消，不可再操作"));
        unreachable;
    }
    return order;
}
