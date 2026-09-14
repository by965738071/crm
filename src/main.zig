//! 入口：启动 zio 运行时（runZio），在协程上下文中运行 crm.appMain。

const std = @import("std");
const crm = @import("crm");

pub fn main(init: std.process.Init) !void {
    try crm.framework.runZio(init.arena.allocator(), crm.appMain);
}
