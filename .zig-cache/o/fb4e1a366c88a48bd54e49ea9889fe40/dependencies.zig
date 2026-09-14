pub const packages = struct {
    pub const @"http_framework-1.0.0-1YqJfvV0DgAc1EeAG6GKxr6YfiKv1KVjoQMp8KTcx-dr" = struct {
        pub const build_root = "zig-pkg/http_framework-1.0.0-1YqJfvV0DgAc1EeAG6GKxr6YfiKv1KVjoQMp8KTcx-dr";
        pub const build_zig = @import("http_framework-1.0.0-1YqJfvV0DgAc1EeAG6GKxr6YfiKv1KVjoQMp8KTcx-dr");
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
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "http_framework", "http_framework-1.0.0-1YqJfvV0DgAc1EeAG6GKxr6YfiKv1KVjoQMp8KTcx-dr" },
};
