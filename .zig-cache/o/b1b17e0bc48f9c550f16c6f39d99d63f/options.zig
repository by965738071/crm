pub const backend: ?[]const u8 = null;
pub const @"build.build.ResolveBeneathMode" = enum (u1) {
    strict = 0,
    best_effort = 1,
};
pub const resolve_beneath_mode: @"build.build.ResolveBeneathMode" = .strict;
pub const no_hacks: bool = false;
pub const task_migration: bool = true;
pub const scheduler_metrics: bool = true;
