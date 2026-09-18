//!   公开：GET /api/categories（整棵树；?project_id= 时只返回该专业根分类下的科目子树）
//!   管理端（/api/admin，AuthRequired{admin_only}）：
//!     POST /categories            新建 {parent_id,name,sort?}
//!     PUT  /categories/:id        修改 {parent_id,name,sort}
//!     DELETE /categories/:id      删除（须无子类）
//! 专业根分类（projects.root_category_id）禁止在此改名/删除，统一走专业管理。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("../../app/state.zig");
const cat_repo = @import("../../db/category_repo.zig");
const project_repo = @import("../../db/project_repo.zig");
const respond = @import("../respond.zig");
const common = @import("common.zig");

/// 树节点视图：children 为空数组时输出 `[]`（不含字段省略）
pub const CategoryNode = struct {
    id: i64,
    parent_id: i64,
    name: []const u8,
    sort: i64,
    children: []CategoryNode = &.{},
};

fn collectLeaves(a: std.mem.Allocator, cats: []cat_repo.Category, parent_id: i64) ![]CategoryNode {
    var out: std.ArrayList(CategoryNode) = .empty;
    for (cats) |c| {
        if (c.parent_id != parent_id) continue;
        const children = try collectLeaves(a, cats, c.id);
        try out.append(a, .{ .id = c.id, .parent_id = c.parent_id, .name = c.name, .sort = c.sort, .children = children });
    }
    return out.toOwnedSlice(a);
}

pub fn tree(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const cats = try cat_repo.findAll(st.db, ctx.arena);

    // 按专业过滤：返回专业根分类下的科目（不含根节点自身）
    const project_id = common.parseQueryInt(ctx, "project_id", 0, 1 << 40, 0);
    if (project_id > 0) {
        const proj = (try project_repo.getById(st.db, ctx.arena, project_id)) orelse
            return ctx.failWith(framework.AppError.notFound("专业不存在"));
        const subjects = try collectLeaves(ctx.arena, cats, proj.root_category_id);
        return respond.ok(res, subjects);
    }

    const root = try collectLeaves(ctx.arena, cats, 0);
    try respond.ok(res, root);
}

// ---------------------------------------------------------------- 管理端

const CategoryBody = struct {
    parent_id: i64 = 0,
    name: []const u8 = "",
    sort: i64 = 0,
};

fn validateName(ctx: *framework.Context, name: []const u8) !bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 64) {
        try ctx.failWith(framework.AppError.badRequest("分类名需为 1-64 字符"));
        return false;
    }
    return true;
}

pub fn create(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    const body = common.readJson(CategoryBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateName(ctx, body.name)) return;
    if (body.parent_id < 0) return ctx.failWith(framework.AppError.badRequest("parent_id 不能为负"));
    if (body.parent_id != 0 and (try cat_repo.getById(st.db, ctx.arena, body.parent_id)) == null) {
        return ctx.failWith(framework.AppError.notFound("父分类不存在"));
    }

    const id = try cat_repo.create(st.db, ctx.arena, body.parent_id, body.name, body.sort);
    const cat = (try cat_repo.getById(st.db, ctx.arena, id)).?;
    try respond.ok(res, nodeOf(cat));
}

fn nodeOf(c: cat_repo.Category) CategoryNode {
    return .{ .id = c.id, .parent_id = c.parent_id, .name = c.name, .sort = c.sort };
}

fn mustGet(ctx: *framework.Context, st: *state.State, id: i64, out: *cat_repo.Category) !bool {
    out.* = (try cat_repo.getById(st.db, ctx.arena, id)) orelse {
        try ctx.failWith(framework.AppError.notFound("分类不存在"));
        return false;
    };
    return true;
}

/// 目标分类是否为未删专业的根节点（根节点改名/删除只能走专业管理，否则专业↔子树断链）
fn isProjectRoot(st: *state.State, id: i64) !bool {
    const n = (try st.db.scalarInt("SELECT COUNT(*) FROM projects WHERE root_category_id = ?1 AND deleted = 0", .{id})) orelse 0;
    return n > 0;
}

pub fn update(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    const body = common.readJson(CategoryBody, ctx) catch
        return ctx.failWith(framework.AppError.badRequest("请求体 JSON 无效"));
    if (!try validateName(ctx, body.name)) return;
    if (body.parent_id < 0) return ctx.failWith(framework.AppError.badRequest("parent_id 不能为负"));
    if (body.parent_id == id) return ctx.failWith(framework.AppError.badRequest("不能把分类设为自己的父级"));
    if (body.parent_id != 0 and (try cat_repo.getById(st.db, ctx.arena, body.parent_id)) == null) {
        return ctx.failWith(framework.AppError.notFound("父分类不存在"));
    }

    var cat: cat_repo.Category = undefined;
    if (!try mustGet(ctx, st, id, &cat)) return;
    if (try isProjectRoot(st, id)) {
        return ctx.failWith(framework.AppError.conflict("该分类是专业根节点，请在专业管理中维护"));
    }

    cat_repo.update(st.db, ctx.arena, id, body.parent_id, body.name, body.sort) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("分类不存在")),
        else => return err,
    };
    var fresh: cat_repo.Category = undefined;
    if (!try mustGet(ctx, st, id, &fresh)) return;
    try respond.ok(res, nodeOf(fresh));
}

pub fn delete(ctx: *framework.Context, res: *framework.Response) !void {
    const st = ctx.service(state.State) orelse return ctx.failWith(framework.AppError.internal("app not ready"));
    var id: i64 = 0;
    if (!try common.parseId(ctx, "id", &id)) return;

    if (try isProjectRoot(st, id)) {
        return ctx.failWith(framework.AppError.conflict("该分类是专业根节点，请在专业管理中删除"));
    }

    // 有子分类不允许删（避免悬挂）
    const child_count = (try st.db.scalarInt("SELECT COUNT(*) FROM categories WHERE parent_id = ?1 AND deleted = 0", .{id})) orelse 0;
    if (child_count > 0) {
        return ctx.failWith(framework.AppError.conflict("该分类下还有子分类，请先删除子分类"));
    }

    cat_repo.delete(st.db, id) catch |err| switch (err) {
        error.NotFound => return ctx.failWith(framework.AppError.notFound("分类不存在")),
        else => return err,
    };
    try respond.ok(res, .{ .status = "ok" });
}
