//! 资料库 handler。
//!   公开：
//!     GET /api/resources（游客只见公开；登录可见全部）
//!     GET /api/resources/:id/download（公开资源直接下；非公开需登录，报名鉴权 phase 3 接入）
//!   管理端（/api/admin）：
//!     GET  /resources     列表（全量，?category_id=&type=&keyword=&status=）
//!     POST /upload        multipart 上传（字段：file, name?, category_id, is_public）→ 落盘+建资源
//!     POST /resources     纯元数据建（用于已存在于磁盘的路径）
//!     PUT  /resources/:id 元数据更新
//!     DELETE /resources/:id 软删

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const authm = @import("../../app/auth_middleware.zig");
const resource_repo = @import("../../db/resource_repo.zig");
const storage = @import("../../svc/storage.zig");
const respond = @import("../respond.zig");
const common = @import("common.zig");

pub const ResourceView = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    orig_name: []const u8,
    rtype: []const u8,
    size: i64,
    mime: []const u8,
    uploader_id: i64,
    is_public: i64,
    created_at: i64,
    // 下载地址由前端拼（不暴露磁盘路径）
};

fn resourceView(r: resource_repo.Resource) ResourceView {
    return .{
        .id = r.id,
        .category_id = r.category_id,
        .name = r.name,
        .orig_name = r.orig_name,
        .rtype = r.rtype,
        .size = r.size,
        .mime = r.mime,
        .uploader_id = r.uploader_id,
        .is_public = r.is_public,
        .created_at = r.created_at,
    };
}

// ---------------------------------------------------------------- 公开

pub fn list(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);
    const rtype = ctx.query("type") orelse "";
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";

    const cu = try authm.currentUserOptional(ctx, &st.session);
    // 游客只看到公开资源；登录用户可见全部（下载仍按 is_public/enrollment 鉴权）
    const items_only_public = cu == null;

    var r: resource_repo.ResourceList = undefined;
    if (items_only_public) {
        r = try resource_repo.listPublic(st.db, ctx.arena, .{
            .page = page,
            .size = size,
            .category_id = category_id,
            .rtype = rtype,
            .keyword = keyword,
        });
    } else {
        r = try resource_repo.list(st.db, ctx.arena, .{
            .page = page,
            .size = size,
            .category_id = category_id,
            .rtype = rtype,
            .keyword = keyword,
        });
    }
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

fn mustGet(ctx: *framework.Context, st: *state.State, id: i64, out: *resource_repo.Resource) !bool {
    out.* = (try resource_repo.getById(st.db, ctx.arena, id)) orelse {
        try ctx.failWith(framework.AppError.notFound("资料不存在"));
        return false;
    };
    return true;
}

/// 鉴权下载（流式）：
///   - is_public=1：游客可下
///   - is_public=0：需登录（phase 3 接入“付费资料需已报名”按课程维度判断）
///   - 文件丢失 → 500（磁盘与数据库不一致属于服务端故障，画面丢文件该报 500 而非 404 误导）
pub fn download(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    var resource: resource_repo.Resource = undefined;
    if (!try mustGet(ctx, st, id, &resource)) return;

    if (resource.is_public == 0) {
        const cu = try authm.currentUserOptional(ctx, &st.session);
        if (cu == null) return ctx.failWith(framework.AppError.unauthorized("请先登录再下载该资料"));
        // phase 3：校验资源归属课程报名情况（is_public=0 且未报名 → 403）
    }

    const disk = try storage.diskPath(ctx.arena, resource.file_path);
    const file = std.Io.Dir.cwd().openFile(ctx.io, disk, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            std.log.err("resource download: file missing on disk: {s}", .{resource.file_path});
            return ctx.failWith(framework.AppError.internal("文件已丢失，请联系管理员"));
        },
        else => return err,
    };
    defer file.close(ctx.io);
    const stat = try file.stat(ctx.io);

    // Content-Disposition 带 UTF-8 文件名（RFC 5987）；orig_name 已过 safeBaseName 清洗无 CRLF 风险
    const disp = try std.fmt.allocPrint(ctx.arena, "attachment; filename*=UTF-8''{s}", .{resource.orig_name});
    _ = try res.header("Content-Disposition", disp);

    var stream_buf: [16 * 1024]u8 = undefined;
    const content_type = if (resource.mime.len > 0) resource.mime else "application/octet-stream";
    var stream = try res.stream(&stream_buf, .{
        .content_length = null, // chunked：文件可能在 stat 后被截断，chunked 成帧最稳（同 static server 做法）
        .content_type = content_type,
    });

    var read_buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const to_read = @min(read_buf.len, stat.size - offset);
        const bufs: []const []u8 = &.{read_buf[0..to_read]};
        const n = try file.readPositional(ctx.io, bufs, offset);
        if (n == 0) return error.UnexpectedEof;
        try stream.writeAll(read_buf[0..n]);
        offset += n;
    }
    try stream.end();
}

// ---------------------------------------------------------------- 管理端

pub fn adminList(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const page = common.parseQueryInt(ctx, "page", 1, 100, 1);
    const size = common.parseQueryInt(ctx, "size", 20, 100, 1);
    const category_id = common.parseQueryInt(ctx, "category_id", 0, 1 << 40, 0);
    const rtype = ctx.query("type") orelse "";
    const keyword = ctx.queryDecoded("keyword") catch null orelse "";

    const r = try resource_repo.list(st.db, ctx.arena, .{
        .page = page,
        .size = size,
        .category_id = category_id,
        .rtype = rtype,
        .keyword = keyword,
    });
    try respond.ok(res, .{ .items = r.items.items, .total = r.total, .page = page, .size = size });
}

pub fn adminGet(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    var resource: resource_repo.Resource = undefined;
    if (!try mustGet(ctx, st, id, &resource)) return;
    try respond.ok(res, resourceView(resource));
}

/// multipart 上传：字段 file（必须）、name（可选，缺省用文件名）、category_id、is_public
pub fn upload(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);

    // 先解析再读 body；body 上限与 multipart limit 一致（200MB）
    var form = framework.multipartFrom(ctx, storage.max_upload_size) catch |err| switch (err) {
        error.NotMultipart, error.MissingBoundary, error.MalformedPart, error.DuplicateField, error.TooManyParts => return ctx.failWith(framework.AppError.badRequest("multipart 表单无效")),
        error.BodyTooLarge => return ctx.failWith(framework.AppError.payloadTooLarge("文件过大，上限 200MB")),
        else => return err,
    };
    defer form.deinit();

    const file_field = form.getFile("file") orelse
        return ctx.failWith(framework.AppError.badRequest("缺少 file 字段"));
    const safe_name = file_field.safeBaseName() orelse
        return ctx.failWith(framework.AppError.badRequest("文件名无效"));

    const name_raw = form.getText("name") orelse "";
    const name = if (name_raw.len > 0) name_raw else safe_name;

    const category_id = blk: {
        const v = form.getText("category_id") orelse break :blk 0;
        break :blk std.fmt.parseInt(i64, v, 10) catch 0;
    };
    const pub_raw = form.getText("is_public") orelse "1";
    const is_public = std.mem.eql(u8, pub_raw, "1") or std.mem.eql(u8, pub_raw, "true");

    // MIME 分类：数据库里 type 必须是 resources 的枚举域
    const mime_in = file_field.content_type orelse "";
    const classified = storage.classify(mime_in, safe_name) catch
        return ctx.failWith(framework.AppError.badRequest("不支持的文件类型"));

    if (category_id != 0) {
        const cnt = (try st.db.scalarInt("SELECT COUNT(*) FROM categories WHERE id = ?1 AND deleted = 0", .{category_id})) orelse 0;
        if (cnt == 0) return ctx.failWith(framework.AppError.badRequest("分类不存在"));
    }

    const saved = storage.saveUpload(ctx.io, ctx.arena, "data/uploads", safe_name, file_field.data) catch |err| switch (err) {
        error.FileTooBig => return ctx.failWith(framework.AppError.payloadTooLarge("文件过大，上限 200MB")),
        else => return err,
    };

    const id = try resource_repo.create(
        st.db,
        category_id,
        name,
        safe_name,
        classified.rtype.asStr(),
        saved.rel_path,
        saved.size,
        classified.mime,
        cu.id,
        if (is_public) 1 else 0,
        common.nowSec(ctx),
    );
    const r = (try resource_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, resourceView(r));
}

const ResourceMetaBody = struct {
    category_id: i64 = 0,
    name: []const u8 = "",
    orig_name: []const u8 = "",
    rtype: []const u8 = "",
    file_path: []const u8 = "",
    size: i64 = 0,
    mime: []const u8 = "",
    is_public: i64 = 1,
};

/// 纯元数据建资源：用于已物理存在于磁盘、但未登记的资料，或外部迁移。
pub fn metaCreate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cu = try authm.currentUser(ctx);
    const body = common.readJson(ResourceMetaBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateMeta(ctx, st, &body)) return;

    const id = try resource_repo.create(
        st.db,
        body.category_id,
        body.name,
        body.orig_name,
        body.rtype,
        body.file_path,
        body.size,
        body.mime,
        cu.id,
        body.is_public,
        common.nowSec(ctx),
    );
    const r = (try resource_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, resourceView(r));
}

fn validateMeta(ctx: *framework.Context, st: *state.State, body: *const ResourceMetaBody) !bool {
    const trimmed_name = std.mem.trim(u8, body.name, " \t\r\n");
    if (trimmed_name.len == 0 or trimmed_name.len > 200) {
        try ctx.failWith(framework.AppError.badRequest("资料名需为 1-200 字符"));
        return false;
    }
    if (body.file_path.len == 0) {
        try ctx.failWith(framework.AppError.badRequest("file_path 不能为空"));
        return false;
    }
    if (!std.mem.startsWith(u8, body.file_path, "uploads/")) {
        try ctx.failWith(framework.AppError.badRequest("file_path 必须位于 uploads/ 下"));
        return false;
    }
    const ok_types = [_][]const u8{ "video", "audio", "pdf", "doc", "image", "markdown" };
    var found = false;
    for (ok_types) |t| {
        if (std.mem.eql(u8, body.rtype, t)) found = true;
    }
    if (!found) {
        try ctx.failWith(framework.AppError.badRequest("type 仅支持 video/audio/pdf/doc/image/markdown"));
        return false;
    }
    if (body.category_id != 0) {
        const cnt = (try st.db.scalarInt("SELECT COUNT(*) FROM categories WHERE id = ?1 AND deleted = 0", .{body.category_id})) orelse 0;
        if (cnt == 0) {
            try ctx.failWith(framework.AppError.badRequest("分类不存在"));
            return false;
        }
    }
    if (body.is_public != 0 and body.is_public != 1) {
        try ctx.failWith(framework.AppError.badRequest("is_public 仅支持 0/1"));
        return false;
    }
    return true;
}

pub fn metaUpdate(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    var resource: resource_repo.Resource = undefined;
    if (!try mustGet(ctx, st, id, &resource)) return;

    const body = common.readJson(ResourceMetaBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateMeta(ctx, st, &body)) return;

    resource_repo.update(st.db, id, body.category_id, body.name, body.rtype, body.is_public) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("资料不存在")),
        else => return err,
    };
    const fresh = (try resource_repo.getById(st.db, ctx.arena, id)).?;
    // file_path 不变（磁盘文件不动），返回合并视图
    var merged = fresh;
    merged.file_path = resource.file_path;
    try respond.ok(res, resourceView(merged));
}

pub fn metaDelete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;
    resource_repo.deleteSoft(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("资料不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .status = "ok" });
}