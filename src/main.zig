//! 入口：启动 zio 运行时（runZio），在协程上下文中运行 crm.appMain。
//!
//! 顶层分配器策略（内存泄漏检测的前提）：
//! - Debug 构建：用 std.heap.DebugAllocator 作顶层分配器，进程退出时 deinit()
//!   做泄漏检测，泄漏则输出来自分配栈并置非零退出码——保证开发期所有请求/
//!   连接 arena 漏 reset/deinit、绕过 arena 的直接分配未释放都能被测到。
//! - Release 构建：用进程级 arena（init.arena），内存随进程结束统一回收，零开销。

const std = @import("std");
const builtin = @import("builtin");
const crm = @import("crm");

pub fn main(init: std.process.Init) !void {
    if (builtin.mode == .debug) {
        const Debug = std.heap.DebugAllocator(.{});
        var debug: Debug = .init;
        defer {
            switch (debug.deinit()) {
                .ok => {},
                .leak => {
                    std.log.err("memory leak detected (stacks printed above)", .{});
                    std.process.exit(1);
                },
            }
        }
        try crm.framework.runZio(debug.allocator(), crm.appMain);
    } else {
        try crm.framework.runZio(init.arena.allocator(), crm.appMain);
    }
}