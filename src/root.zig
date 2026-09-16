//! crm 模块根：对外导出与子模块引用入口。

pub const framework = @import("http_framework");
pub const zqlite = @import("zqlite");

pub const version = "0.1.0";

pub const state = @import("app/state.zig");
pub const app = @import("app/app.zig");
pub const router = @import("app/router.zig");
pub const db = @import("db/db.zig");
pub const migrate = @import("db/migrate.zig");
pub const user_repo = @import("db/user_repo.zig");
pub const category_repo = @import("db/category_repo.zig");
pub const course_repo = @import("db/course_repo.zig");
pub const resource_repo = @import("db/resource_repo.zig");
pub const learning_repo = @import("db/learning_repo.zig");
pub const question_repo = @import("db/question_repo.zig");
pub const practice_repo = @import("db/practice_repo.zig");
pub const exam_repo = @import("db/exam_repo.zig");
pub const order_repo = @import("db/order_repo.zig");
pub const announcement_repo = @import("db/announcement_repo.zig");
pub const favorite_repo = @import("db/favorite_repo.zig");
pub const note_repo = @import("db/note_repo.zig");
pub const stats_repo = @import("db/stats_repo.zig");
pub const svc_identity = @import("svc/identity.zig");
pub const svc_storage = @import("svc/storage.zig");
pub const audit_repo = @import("db/audit_repo.zig");
pub const respond = @import("web/respond.zig");

pub const appMain = app.appMain;

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
