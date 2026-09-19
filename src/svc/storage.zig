//! 存储布局：`<base>/<yyyy-mm>/<随机hex>.<ext>`，base 默认 `data/uploads`。
//! 数据库里存相对路径（相对进程工作目录），下载时从相对路径拼绝对再读。

const std = @import("std");

/// 第一期上传上限（与 plan.md 风险表一致：先限 200MB，不支持流式写盘）
pub const max_upload_size: usize = 200 * 1024 * 1024;

/// 题干/选项图片上传上限（仅 png/jpg/jpeg/gif/webp，见 handlers/images.zig）
pub const max_image_size: usize = 5 * 1024 * 1024;

/// 题目图片落盘根目录（相对 cwd）。经 /uploads/images/* 静态路由公开访问。
pub const images_dir = "data/uploads/images";

/// data_dir（app.zig 常量）当前只有这一个落盘根
pub const data_dir = "data";

/// 把数据库里的相对路径（uploads/2026-09/xxx）解析成磁盘绝对路径（相对进程 cwd）。
pub fn diskPath(a: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ data_dir, rel_path });
}

/// 允许的类型清单（resources.type 枚举域）
pub const ResourceType = enum {
    video,
    audio,
    pdf,
    doc,
    image,
    markdown,

    pub fn asStr(self: ResourceType) []const u8 {
        return switch (self) {
            .video => "video",
            .audio => "audio",
            .pdf => "pdf",
            .doc => "doc",
            .image => "image",
            .markdown => "markdown",
        };
    }
};

pub const Classified = struct {
    rtype: ResourceType,
    mime: []const u8,
};

/// 按 MIME（优先）与扩展名（兜底）分类，识别不了 → error.UnsupportedFileType。
pub fn classify(mime: []const u8, base_name: []const u8) !Classified {
    const ext = extensionOf(base_name);
    if (mime.len > 2) {
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.ascii.eqlIgnoreCase(a, b);
            }
        }.f;
        if (eq(mime, "video/mp4") or eq(mime, "video/webm") or eq(mime, "video/quicktime") or eq(mime, "video/x-msvideo") or eq(mime, "video/mpeg"))
            return .{ .rtype = .video, .mime = mime };
        if (eq(mime, "audio/mpeg") or eq(mime, "audio/mp4") or eq(mime, "audio/wav") or eq(mime, "audio/x-wav") or eq(mime, "audio/ogg") or eq(mime, "audio/aac") or eq(mime, "audio/webm"))
            return .{ .rtype = .audio, .mime = mime };
        if (eq(mime, "application/pdf"))
            return .{ .rtype = .pdf, .mime = mime };
        if (eq(mime, "application/msword") or eq(mime, "application/vnd.openxmlformats-officedocument.wordprocessingml.document") or eq(mime, "text/plain"))
            return .{ .rtype = .doc, .mime = mime };
        if (eq(mime, "text/markdown"))
            return .{ .rtype = .markdown, .mime = mime };
        if (eq(mime, "image/jpeg") or eq(mime, "image/png") or eq(mime, "image/gif") or eq(mime, "image/webp"))
            return .{ .rtype = .image, .mime = mime };
    }
    if (ext.len > 0) {
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.ascii.eqlIgnoreCase(a, b);
            }
        }.f;
        if (eq(ext, "mp4") or eq(ext, "webm") or eq(ext, "mov") or eq(ext, "mkv"))
            return .{ .rtype = .video, .mime = "video/mp4" };
        if (eq(ext, "mp3") or eq(ext, "wav") or eq(ext, "ogg") or eq(ext, "aac") or eq(ext, "m4a"))
            return .{ .rtype = .audio, .mime = "audio/mpeg" };
        if (eq(ext, "pdf"))
            return .{ .rtype = .pdf, .mime = "application/pdf" };
        if (eq(ext, "doc") or eq(ext, "docx") or eq(ext, "txt"))
            return .{ .rtype = .doc, .mime = "application/octet-stream" };
        if (eq(ext, "md") or eq(ext, "markdown"))
            return .{ .rtype = .markdown, .mime = "text/markdown" };
        if (eq(ext, "jpg") or eq(ext, "jpeg") or eq(ext, "png") or eq(ext, "gif") or eq(ext, "webp"))
            return .{ .rtype = .image, .mime = "image/png" };
    }
    return error.UnsupportedFileType;
}

/// 取文件名基名的扩展名（小写，不含点）；无扩展名返回空串。
pub fn extensionOf(base_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base_name, '.') orelse return "";
    return base_name[dot + 1 ..];
}

fn nowSec(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// 当前 <yyyy-mm> 子目录名。
pub fn monthDir(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@as(u64, @intCast(nowSec(io)))) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}", .{ year_day.year, month_day.month.numeric() });
}

pub const SaveResult = struct {
    /// 相对路径：`uploads/2026-09/ab12….mp4`
    rel_path: []const u8,
    size: i64,
};

/// 保存普通资源。base 是磁盘根目录（如 `data/uploads`）；rel_path 以 `uploads/...` 开头。
pub fn saveUpload(
    io: std.Io,
    a: std.mem.Allocator,
    base: []const u8,
    safe_name: []const u8,
    data: []const u8,
) !SaveResult {
    return saveUnder(io, a, base, "uploads", safe_name, data);
}

/// 题目图片上传：按分类分组落盘 `data/uploads/images/<group>/<yyyy-mm>/<hex>.<ext>`，
/// 返回相对路径 `uploads/images/<group>/<yyyy-mm>/<hex>.<ext>`（对外 URL 前缀 /uploads/images/）。
/// group 是调用方校验过的单段路径（分类 id 或 "misc"），仅允许字母数字及 _-.。
pub fn saveImage(
    io: std.Io,
    a: std.mem.Allocator,
    safe_name: []const u8,
    data: []const u8,
    group: []const u8,
) !SaveResult {
    if (data.len > max_image_size) return error.FileTooBig;
    var ok = group.len > 0 and group.len <= 32;
    for (group) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) ok = false;
    }
    if (!ok) return error.InvalidImageGroup;
    const base = try std.fmt.allocPrint(a, "{s}/{s}", .{ images_dir, group });
    const rel_prefix = try std.fmt.allocPrint(a, "uploads/images/{s}", .{group});
    return saveUnder(io, a, base, rel_prefix, safe_name, data);
}

fn saveUnder(
    io: std.Io,
    a: std.mem.Allocator,
    base: []const u8,
    rel_prefix: []const u8,
    safe_name: []const u8,
    data: []const u8,
) !SaveResult {
    if (data.len > max_upload_size) return error.FileTooBig;

    const month = try monthDir(io, a);
    const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, month });
    std.Io.Dir.cwd().createDirPath(io, sub) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // 随机文件名：16 字节 hex，保留原扩展名
    var rnd_buf: [16]u8 = undefined;
    try std.Io.randomSecure(io, &rnd_buf);
    const ext = extensionOf(safe_name);
    var stored_name: []const u8 = undefined;
    var file: std.Io.File = undefined;
    // 若随机文件名意外撞车，换新随机名重试（不应误报 FileTooBig）
    while (true) {
        const hex = try std.fmt.allocPrint(a, "{x}", .{&rnd_buf});
        stored_name = if (ext.len > 0)
            try std.fmt.allocPrint(a, "{s}.{s}", .{ hex, ext })
        else
            try a.dupe(u8, hex);
        const full_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ sub, stored_name });
        file = std.Io.Dir.cwd().createFile(io, full_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try std.Io.randomSecure(io, &rnd_buf);
                continue;
            },
            else => return err,
        };
        break;
    }
    defer file.close(io);
    // zio 0.17 在 Windows 上 File.writeStreamingAll 对 overlapped handle 传 NULL
    // OVERLAPPED（WriteFile 返回 87），改用 positional 写（走事件循环，正确携带 OVERLAPPED）。
    try file.writePositionalAll(io, data, 0);

    return .{
        .rel_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ rel_prefix, month, stored_name }),
        .size = @intCast(data.len),
    };
}
