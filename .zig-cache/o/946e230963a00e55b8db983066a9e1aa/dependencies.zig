pub const packages = struct {
    pub const @"../wlw/http-framework" = struct {
        pub const build_root = "../wlw/http-framework";
        pub const build_zig = @import("../wlw/http-framework");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zio", "zio-0.17.0-xHbVVC8rKQC-IaVNQvJWKA_ACKKh6BdQ1PZyS9zqJpq-" },
        };
    };
    pub const @"zio-0.17.0-xHbVVC8rKQC-IaVNQvJWKA_ACKKh6BdQ1PZyS9zqJpq-" = struct {
        pub const build_root = "zig-pkg/zio-0.17.0-xHbVVC8rKQC-IaVNQvJWKA_ACKKh6BdQ1PZyS9zqJpq-";
        pub const build_zig = @import("zio-0.17.0-xHbVVC8rKQC-IaVNQvJWKA_ACKKh6BdQ1PZyS9zqJpq-");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zqlite-0.0.1-RWLaYz49nABcCXlOV690EXRLoexKyFDB9lCr5rsYfMQf" = struct {
        pub const build_root = "zig-pkg/zqlite-0.0.1-RWLaYz49nABcCXlOV690EXRLoexKyFDB9lCr5rsYfMQf";
        pub const build_zig = @import("zqlite-0.0.1-RWLaYz49nABcCXlOV690EXRLoexKyFDB9lCr5rsYfMQf");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "http_framework", "../wlw/http-framework" },
    .{ "zqlite", "zqlite-0.0.1-RWLaYz49nABcCXlOV690EXRLoexKyFDB9lCr5rsYfMQf" },
};
