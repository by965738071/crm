//! 编译期反射：从 struct 字段名生成 SQL 列清单，避免各处手写列字符串漂移。
//!
//! 约束：表列名 == 结构体字段名、且字段声明顺序 == 表列顺序（rowToX 的索引即字段序）。
//! 不满足约束的表（JOIN、别名、COALESCE、额外计算列）继续手写列清单。
const std = @import("std");

/// 生成 `"f1, f2, ..."` 列清单。comptime 输出常量，直接嵌入二进制（安全返回切片）。
pub fn cols(comptime T: type) []const u8 {
    return comptime blk: {
        const names = @typeInfo(T).@"struct".field_names;
        var out: []const u8 = "";
        for (names, 0..) |n, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ n;
        }
        break :blk out;
    };
}

const Probe = struct {
    id: i64,
    user_id: i64,
    action: []const u8,
};

test "cols generates comma-joined field list in declaration order" {
    try std.testing.expectEqualStrings("id, user_id, action", cols(Probe));
}

test "cols empty struct" {
    try std.testing.expectEqualStrings("", cols(struct {}));
}