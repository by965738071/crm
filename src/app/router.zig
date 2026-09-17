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
const learning = @import("../web/handlers/learning.zig");
const questions = @import("../web/handlers/questions.zig");
const practice = @import("../web/handlers/practice.zig");
const exams = @import("../web/handlers/exams.zig");
const orders = @import("../web/handlers/orders.zig");
const images = @import("../web/handlers/images.zig");
const announcements = @import("../web/handlers/announcements.zig");
const favorites = @import("../web/handlers/favorites.zig");
const notes = @import("../web/handlers/notes.zig");
const stats_h = @import("../web/handlers/stats.zig");
const admin_logs = @import("../web/handlers/admin_logs.zig");
const auth_mw = @import("auth_middleware.zig");
const respond = @import("../web/respond.zig");

pub fn register(st: *state.State, router: *framework.Router) !void {
    try router.route(.GET, "/api/health", framework.Handler.fromFn(health.handle));

    // 前端静态资源（web/dist 构建产物）
    try router.route(.GET, "/static/*", framework.Handler.initSingleton(&st.static_assets));
    // 题目图片静态资源（data/uploads/images，仅暴露随机文件名）
    try router.route(.GET, "/uploads/images/*", framework.Handler.initSingleton(&st.image_files));
    // 根路径先返回前端占位页；SPA 回退路由在第 8 期前端接入时完善
    try router.route(.GET, "/", framework.Handler.initSingleton(&st.static_index));

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

    // 学员登录态接口（第 3 期 M-C）：空前缀子组，只给本组路由挂 AuthRequired
    // （框架组中间件沿祖先链解析，见 http_router/router.zig 注释）
    var study = try api.group("");
    try study.use(framework.Middleware.init(auth_mw.AuthRequired, &st.auth_user));
    try study.route(.POST, "/courses/:id/enroll", framework.Handler.fromFn(learning.enroll));
    try study.route(.GET, "/me/enrollments", framework.Handler.fromFn(learning.myEnrollments));
    try study.route(.GET, "/me/progress", framework.Handler.fromFn(learning.myProgress));
    try study.route(.POST, "/learning/progress", framework.Handler.fromFn(learning.reportProgress));
    try study.route(.POST, "/learning/heartbeat", framework.Handler.fromFn(learning.heartbeat));

    // 题库与练习（第 4 期 M-D）
    try study.route(.POST, "/practice/start", framework.Handler.fromFn(practice.start));
    try study.route(.POST, "/practice/submit", framework.Handler.fromFn(practice.submit));
    try study.route(.GET, "/practice/wrong", framework.Handler.fromFn(practice.wrongList));
    try study.route(.POST, "/practice/wrong/:id/master", framework.Handler.fromFn(practice.masterWrong));
    try study.route(.GET, "/practice/favorites", framework.Handler.fromFn(practice.favorites));
    try study.route(.POST, "/questions/:id/favorite", framework.Handler.fromFn(practice.toggleFavorite));

    // 模拟考试（第 5 期 M-E）
    try study.route(.GET, "/exams", framework.Handler.fromFn(exams.list));
    try study.route(.POST, "/exams/:id/start", framework.Handler.fromFn(exams.start));
    try study.route(.POST, "/exam-attempts/:id/answer", framework.Handler.fromFn(exams.saveAnswer));
    try study.route(.POST, "/exam-attempts/:id/submit", framework.Handler.fromFn(exams.submit));
    try study.route(.GET, "/exam-attempts", framework.Handler.fromFn(exams.attemptList));
    try study.route(.GET, "/exam-attempts/:id", framework.Handler.fromFn(exams.attemptDetail));

    // 订单（第 6 期 M-F）：学员只读本人订单；支付/取消走管理端（F2 语义）
    try study.route(.GET, "/orders", framework.Handler.fromFn(orders.myOrders));

    // 收藏与笔记（第 7 期 M-G）
    try study.route(.POST, "/favorites", framework.Handler.fromFn(favorites.add));
    try study.route(.DELETE, "/favorites", framework.Handler.fromFn(favorites.remove));
    try study.route(.GET, "/favorites", framework.Handler.fromFn(favorites.list));
    try study.route(.POST, "/notes", framework.Handler.fromFn(notes.create));
    try study.route(.GET, "/notes", framework.Handler.fromFn(notes.list));
    try study.route(.PUT, "/notes/:id", framework.Handler.fromFn(notes.update));
    try study.route(.DELETE, "/notes/:id", framework.Handler.fromFn(notes.delete));

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
    try admin.route(.GET, "/course-stats", framework.Handler.fromFn(courses.adminCourseStats));
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
    try admin.route(.GET, "/resource-stats", framework.Handler.fromFn(resources.adminCategoryStats));
    try admin.route(.GET, "/resources/:id", framework.Handler.fromFn(resources.adminGet));
    try admin.route(.POST, "/upload", framework.Handler.fromFn(resources.upload));
    try admin.route(.POST, "/resources", framework.Handler.fromFn(resources.metaCreate));
    try admin.route(.PUT, "/resources/:id", framework.Handler.fromFn(resources.metaUpdate));
    try admin.route(.DELETE, "/resources/:id", framework.Handler.fromFn(resources.metaDelete));

    // ---------------- 题库管理（第 4 期 M-D） ----------------
    try admin.route(.GET, "/questions", framework.Handler.fromFn(questions.adminList));
    try admin.route(.GET, "/question-stats", framework.Handler.fromFn(questions.adminCategoryStats));
    try admin.route(.POST, "/upload-image", framework.Handler.fromFn(images.uploadImage));
    try admin.route(.POST, "/questions", framework.Handler.fromFn(questions.adminCreate));
    try admin.route(.POST, "/questions/import", framework.Handler.fromFn(questions.adminImport));
    try admin.route(.GET, "/questions/:id", framework.Handler.fromFn(questions.adminGet));
    try admin.route(.PUT, "/questions/:id", framework.Handler.fromFn(questions.adminUpdate));
    try admin.route(.DELETE, "/questions/:id", framework.Handler.fromFn(questions.adminDelete));

    // 模拟考试管理（第 5 期 M-E）
    try admin.route(.GET, "/exams", framework.Handler.fromFn(exams.adminList));
    try admin.route(.GET, "/exam-stats", framework.Handler.fromFn(exams.adminCategoryStats));
    try admin.route(.POST, "/exams", framework.Handler.fromFn(exams.adminCreate));
    try admin.route(.GET, "/exams/:id", framework.Handler.fromFn(exams.adminGet));
    try admin.route(.PUT, "/exams/:id", framework.Handler.fromFn(exams.adminUpdate));
    try admin.route(.DELETE, "/exams/:id", framework.Handler.fromFn(exams.adminDelete));

    // 订单管理（第 6 期 M-F）
    try admin.route(.GET, "/orders", framework.Handler.fromFn(orders.adminList));
    try admin.route(.POST, "/orders", framework.Handler.fromFn(orders.adminCreate));
    try admin.route(.POST, "/orders/:id/pay", framework.Handler.fromFn(orders.adminPay));
    try admin.route(.POST, "/orders/:id/cancel", framework.Handler.fromFn(orders.adminCancel));

    // ---------------- 公告（第 7 期 M-G G1）：公开端只读已发布 ----------------
    try api.route(.GET, "/announcements", framework.Handler.fromFn(announcements.list));
    try api.route(.GET, "/announcements/:id", framework.Handler.fromFn(announcements.detail));

    // 公告管理（第 7 期）
    try admin.route(.GET, "/announcements", framework.Handler.fromFn(announcements.adminList));
    try admin.route(.POST, "/announcements", framework.Handler.fromFn(announcements.adminCreate));
    try admin.route(.GET, "/announcements/:id", framework.Handler.fromFn(announcements.adminGet));
    try admin.route(.PUT, "/announcements/:id", framework.Handler.fromFn(announcements.adminUpdate));
    try admin.route(.DELETE, "/announcements/:id", framework.Handler.fromFn(announcements.adminDelete));
    try admin.route(.POST, "/announcements/:id/publish", framework.Handler.fromFn(announcements.adminPublish));
    try admin.route(.POST, "/announcements/:id/unpublish", framework.Handler.fromFn(announcements.adminUnpublish));

    // 后台统计（第 7 期 M-H H1）
    try admin.route(.GET, "/stats", framework.Handler.fromFn(stats_h.overview));

    // 日志管理（审计日志查询）
    try admin.route(.GET, "/audit-logs", framework.Handler.fromFn(admin_logs.adminList));

    router.notFoundHandler(framework.Handler.initSingleton(&st.spa));
}
