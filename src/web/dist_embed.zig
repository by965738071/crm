//! web/dist 前端产物的编译期内嵌访问。
//!
//! 数据来源是 build.zig 生成的 `dist_assets` 模块（@embedFile 进二进制）。
//! enabled（编译期 files 非空）时由本模块接管 "/"、"/static/*"、"/assets/*"
//! 与 SPA 回退，运行期不再依赖 web/dist 目录 → 可单文件部署。
//! 运行期才产生的内容（uploads/images 题目图片）不受影响，仍走文件系统。

const std = @import("std");
const framework = @import("http_framework");
const assets = @import("dist_assets");

/// 前端是否已内嵌进二进制（编译期决定）
pub const enabled: bool = assets.files.len > 0;

/// 内嵌文件数（自检/日志用）
pub const file_count: usize = assets.files.len;

/// 精确 path→内容 查找。前端产物规模在百量级，线性比较开销可忽略。
fn find(path: []const u8) ?assets.File {
    for (assets.files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f;
    }
    return null;
}

/// 扩展名 → MIME（vite 产物常见类型 + 资料类文件兜底）
const mime = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".htm", "text/html; charset=utf-8" },
    .{ ".js", "text/javascript; charset=utf-8" },
    .{ ".mjs", "text/javascript; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".json", "application/json" },
    .{ ".map", "application/json" },
    .{ ".svg", "image/svg+xml" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".webp", "image/webp" },
    .{ ".avif", "image/avif" },
    .{ ".ico", "image/vnd.microsoft.icon" },
    .{ ".txt", "text/plain; charset=utf-8" },
    .{ ".xml", "application/xml" },
    .{ ".pdf", "application/pdf" },
    .{ ".mp4", "video/mp4" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".ttf", "font/ttf" },
    .{ ".otf", "font/otf" },
    .{ ".wasm", "application/wasm" },
});

fn contentType(path: []const u8) []const u8 {
    return mime.get(std.fs.path.extension(path)) orelse "application/octet-stream";
}

/// vite 产物文件名带内容哈希 → assets/ 下可一年强缓存；html 入口必须
/// no-cache（重新部署后浏览器要立刻拿到新入口），其余给短缓存。
fn cacheControlFor(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "assets/")) return "public, max-age=31536000, immutable";
    if (std.mem.endsWith(u8, path, ".html")) return "no-cache";
    return "public, max-age=3600";
}

fn serve(res: *framework.Response, path: []const u8) !bool {
    const f = find(path) orelse return false;
    _ = try res.header("Cache-Control", cacheControlFor(path));
    try res.raw(f.content, contentType(path));
    return true;
}

fn notFound(res: *framework.Response) !void {
    _ = res.statusCode(.not_found);
    try res.json(.{
        .ok = false,
        .@"error" = .{ .code = "not_found", .message = "no such route" },
    });
}

/// GET / → 内嵌 index.html
pub fn handleRoot(_: *framework.Context, res: *framework.Response) !void {
    if (try serve(res, "index.html")) return;
    try notFound(res);
}

/// GET /static/* → 内嵌查找（与旧磁盘托管语义一致：剥前缀后相对 dist 根）
pub fn handleStatic(ctx: *framework.Context, res: *framework.Response) !void {
    if (try servePrefixed(ctx, res, "")) return;
    try notFound(res);
}

/// GET /assets/* → vite base='/' 的产物目录。
/// （修复：此前路由表漏注册 /assets/*，JS/CSS 会被 SPA 回退吞成 HTML。）
pub fn handleAssets(ctx: *framework.Context, res: *framework.Response) !void {
    if (try servePrefixed(ctx, res, "assets/")) return;
    try notFound(res);
}

fn servePrefixed(ctx: *framework.Context, res: *framework.Response, comptime dir_prefix: []const u8) !bool {
    const raw = ctx.param("*") orelse return false;
    const decoded = percentDecode(ctx.arena, raw) orelse return false;
    // "++" 要求右操作数 comptime 已知，运行时拼接走 arena
    const key = if (dir_prefix.len == 0)
        decoded
    else
        std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ dir_prefix, decoded }) catch return false;
    return serve(res, key);
}

/// not-found 回退：先尝试内嵌文件命中（覆盖 dist 根直链等场景），
/// 未命中返回内嵌 index.html 交给 vue-router；/api/* 与非 GET → JSON 404。
pub fn handleNotFound(ctx: *framework.Context, res: *framework.Response) !void {
    const p = ctx.request.path;
    if (ctx.request.method == .GET and !std.mem.startsWith(u8, p, "/api")) {
        const raw = if (p.len > 0 and p[0] == '/') p[1..] else p;
        if (raw.len > 0) {
            const decoded = percentDecode(ctx.arena, raw) orelse "";
            if (try serve(res, decoded)) return;
        }
        if (find("index.html")) |idx| {
            _ = try res.header("Cache-Control", "no-cache");
            try res.html(idx.content);
            return;
        }
    }
    try notFound(res);
}

/// percent-decode 到 arena（无 '%' 时零拷贝直通）；解码失败 → null。
fn percentDecode(arena: std.mem.Allocator, src: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, src, '%') == null) return src;
    const buf = arena.alloc(u8, src.len) catch return null;
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch return null;
            buf[j] = hi * 16 + lo;
            i += 3;
            j += 1;
        } else {
            buf[j] = src[i];
            i += 1;
            j += 1;
        }
    }
    return buf[0..j];
}
