//! 路由注册。新增业务模块时在 register 里挂路由即可。

const std = @import("std");
const framework = @import("http_framework");
const state = @import("state.zig");
const health = @import("../web/handlers/health.zig");
const auth_h = @import("../web/handlers/auth.zig");
const admin_users = @import("../web/handlers/admin_users.zig");
const categories = @import("../web/handlers/categories.zig");
const courses = @import("../web/handlers/courses.zig");
const resources = @import("../web/handlers/resources.zig");
const auth_mw = @import("auth_middleware.zig");
const respond = @import("../web/respond.zig");

pub fn register(st: *state.State, router: *framework.Router) !void {
    try router.route(.GET, "/api/health", framework.Handler.fromFn(health.handle));

    // 前端静态资源（web/dist 构建产物）
    try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &st.static_assets));
    // 根路径先返回前端占位页；SPA 回退路由在第 8 期前端接入时完善
    try router.route(.GET, "/", framework.Handler.initSingleton(framework.StaticFileServer, &st.static_index));

    // ---------------- 认证与用户（第 1 期） ----------------
    var api = try router.group("/api");

    // 公开接口：注册 / 登录 / 登出（登出幂等，不挂鉴权）
    try api.route(.POST, "/auth/register", framework.Handler.fromFn(auth_h.register));
    try api.route(.POST, "/auth/login", framework.Handler.fromFn(auth_h.login));
    try api.route(.POST, "/auth/logout", framework.Handler.fromFn(auth_h.logout));

    // 登录态接口：组级 AuthRequired（需登录，不限制角色）
    var authed = try api.group("/auth");
    try authed.use(framework.Middleware.init(auth_mw.AuthRequired, &st.auth_user));
    try authed.route(.GET, "/me", framework.Handler.fromFn(auth_h.me));
    try authed.route(.PUT, "/profile", framework.Handler.fromFn(auth_h.updateProfile));
    try authed.route(.PUT, "/password", framework.Handler.fromFn(auth_h.changePassword));

    // 管理端：AuthRequired{admin_only}（admin/superadmin）
    var admin = try api.group("/admin");
    try admin.use(framework.Middleware.init(auth_mw.AuthRequired, &st.auth_admin));
    try admin.route(.GET, "/users", framework.Handler.fromFn(admin_users.list));
    try admin.route(.GET, "/users/:id", framework.Handler.fromFn(admin_users.get));
    try admin.route(.PUT, "/users/:id/status", framework.Handler.fromFn(admin_users.putStatus));
    try admin.route(.PUT, "/users/:id/role", framework.Handler.fromFn(admin_users.putRole));
    try admin.route(.POST, "/users/:id/reset-password", framework.Handler.fromFn(admin_users.postResetPassword));

    // ---------------- 分类（第 2 期） ----------------
    try api.route(.GET, "/categories", framework.Handler.fromFn(categories.tree));
    try admin.route(.POST, "/categories", framework.Handler.fromFn(categories.create));
    try admin.route(.PUT, "/categories/:id", framework.Handler.fromFn(categories.update));
    try admin.route(.DELETE, "/categories/:id", framework.Handler.fromFn(categories.delete));

    // ---------------- 课程 / 章节 / 课时（第 2 期） ----------------
    try api.route(.GET, "/courses", framework.Handler.fromFn(courses.list));
    try api.route(.GET, "/courses/:id", framework.Handler.fromFn(courses.detail));
    try admin.route(.GET, "/courses", framework.Handler.fromFn(courses.adminList));
    try admin.route(.GET, "/courses/:id", framework.Handler.fromFn(courses.adminGet));
    try admin.route(.POST, "/courses", framework.Handler.fromFn(courses.adminCreate));
    try admin.route(.PUT, "/courses/:id", framework.Handler.fromFn(courses.adminUpdate));
    try admin.route(.DELETE, "/courses/:id", framework.Handler.fromFn(courses.adminDelete));
    try admin.route(.POST, "/chapters", framework.Handler.fromFn(courses.chapterCreate));
    try admin.route(.PUT, "/chapters/:id", framework.Handler.fromFn(courses.chapterUpdate));
    try admin.route(.DELETE, "/chapters/:id", framework.Handler.fromFn(courses.chapterDelete));
    try admin.route(.POST, "/lessons", framework.Handler.fromFn(courses.lessonCreate));
    try admin.route(.PUT, "/lessons/:id", framework.Handler.fromFn(courses.lessonUpdate));
    try admin.route(.DELETE, "/lessons/:id", framework.Handler.fromFn(courses.lessonDelete));

    // ---------------- 资料库（第 2 期） ----------------
    try api.route(.GET, "/resources", framework.Handler.fromFn(resources.list));
    try api.route(.GET, "/resources/:id/download", framework.Handler.fromFn(resources.download));
    try admin.route(.GET, "/resources", framework.Handler.fromFn(resources.adminList));
    try admin.route(.GET, "/resources/:id", framework.Handler.fromFn(resources.adminGet));
    try admin.route(.POST, "/upload", framework.Handler.fromFn(resources.upload));
    try admin.route(.POST, "/resources", framework.Handler.fromFn(resources.metaCreate));
    try admin.route(.PUT, "/resources/:id", framework.Handler.fromFn(resources.metaUpdate));
    try admin.route(.DELETE, "/resources/:id", framework.Handler.fromFn(resources.metaDelete));

    router.notFoundHandler(framework.Handler.fromFn(respond.notFoundHandler));
}
