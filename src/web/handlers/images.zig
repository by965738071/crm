//! 题目图片上传 handler（方案一第一期）。
//!   管理端：
//!     POST /api/admin/upload-image  multipart 字段 file（png/jpg/jpeg/gif/webp，≤5MB）
//!     返回 { url: "/uploads/images/<yyyy-mm>/<hex>.<ext>", size }
//!   公开访问：GET /uploads/images/*（随机 hex 文件名防猜测，见 state.zig 的 image_files 静态服务）
//!
//! 图片不上库、不落资源表：URL 由前端内嵌到题干/选项文本（markdown 图语法），
//! 渲染时由前端 RichText 组件解析成 <img>。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const storage = @import("../../svc/storage.zig");
const respond = @import("../respond.zig");

const allowed_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" };

fn extAllowed(ext: []const u8) bool {
    for (allowed_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn uploadImage(ctx: *framework.Context, res: *framework.Response) !void {
    _ = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));

    var form = framework.multipartFrom(ctx, storage.max_image_size) catch |err| switch (err) {
        error.NotMultipart, error.MissingBoundary, error.MalformedPart, error.DuplicateField, error.TooManyParts => return ctx.failWith(framework.AppError.badRequest("multipart 表单无效")),
        error.BodyTooLarge => return ctx.failWith(framework.AppError.payloadTooLarge("图片过大，上限 5MB")),
        else => return err,
    };
    defer form.deinit();

    const file_field = form.getFile("file") orelse
        return ctx.failWith(framework.AppError.badRequest("缺少 file 字段"));
    const safe_name = file_field.safeBaseName() orelse
        return ctx.failWith(framework.AppError.badRequest("文件名无效"));

    // 只放行常见网页图片格式；svg 可内联脚本（存储型 XSS）显式排除
    if (!extAllowed(storage.extensionOf(safe_name))) {
        return ctx.failWith(framework.AppError.badRequest("仅支持 png/jpg/jpeg/gif/webp 图片"));
    }

    const saved = storage.saveImage(ctx.io, ctx.arena, safe_name, file_field.data) catch |err| switch (err) {
        error.FileTooBig => return ctx.failWith(framework.AppError.payloadTooLarge("图片过大，上限 5MB")),
        else => return err,
    };

    const url = try std.fmt.allocPrint(ctx.arena, "/{s}", .{saved.rel_path});
    try respond.ok(res, .{ .url = url, .size = saved.size });
}
