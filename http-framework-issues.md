# http-framework Issue 草稿

> 本文件存放准备提交到 https://github.com/by965738071/http-framework 的 issue 草稿。
> 提交后可清空对应条目。

---

## Issue 1（功能请求）：Config 缺少应用级配置扩展点与加载机制

**标题**：Feature: Config 无应用级字段扩展点，也没有环境变量/配置文件加载入口

**环境**：http_framework 1.0.0（main 分支），Zig 0.17.0-dev.2125，macOS aarch64

### 背景

`http_app.Config` 的分层设计（network / http / body / pool）很好，但我们接入时发现它对
「应用自身的配置」没有任何承接方式：

1. **无应用级字段/扩展槽**。应用一定有框架不可能知道的配置，例如本项目的
   `data_dir`、SQLite `db_path`、静态目录 `static_dir`。目前只能在自己的 `app.zig` 里
   另立一组常量，配置来源分裂成「框架 Config + 应用常量」两处，无法统一管理
   （例如 profile diff、启动时 dump 全量配置）。
2. **无加载机制**。`Config{}` 只能 comptime 字面量覆盖，没有 `fromEnv` / 配置文件
   入口。部署时改端口、监听地址都要重新编译；应用想支持 `PORT` 环境变量只能自己
   手写解析逻辑，又回到自定义 Config 的老路。

### 期望（任选其一或组合）

- `Config` 增加泛型扩展槽，例如：
  ```zig
  pub fn AppConfig(comptime App: type) type {
      return struct {
          server: Config = .{},
          app: App = .{},
      };
  }
  ```
  或更简单地允许 `Config` 携带一个 `user_data: ?*anyopaque = null`。
- 提供 `Config.fromEnv(allocator, prefix)` 或 `Config.fromFile(allocator, path)`
  之类的加载入口（至少覆盖 address / port / server_name / size_limit 这几个最常改的字段）。

### 当前 Workaround

应用配置以编译期常量硬编码在 `src/app/app.zig`，与 `framework.Config` 分开维护。
功能不受影响，只是配置入口分裂。

---

## Issue 2（文档）：Middleware 的 destroy 钩子语义建议在 README 显著位置说明

**标题**：docs: `Middleware.init` 会在 `Router.deinit` 时自动调用实例 `deinit()`，易导致 double-free

### 现象

`Middleware.init(T, ptr)` 在 `T` 有 `deinit` 方法时会自动注册 destroy 钩子，
`Router.deinit()` 会对所有中间件实例调用 `T.deinit()`。如果应用侧不了解这一点、
又手动调用了实例的 `deinit()`，会 double-free；我们先踩过一次：

```
thread panic: incorrect alignment
  std/hash_map.zig ... in header
  http_rate_limit/rate_limiter.zig:87 in deinit
  http_app/middleware.zig:83 in call   ← destroy 钩子二次触发
```

（`deinitAll` 的注释里其实写了去重逻辑，语义是自洽的；但 `Middleware.init` 的文档注释
只说了「从实现了 process 的类型创建中间件」，没有提到「T 有 deinit 就自动接管所有权」。）

### 建议

- 在 `Middleware.init` doc comment 与 README 中间件章节加一句：
  **「注册进 Router/Pipeline 后，实例所有权即移交框架，由 deinitAll 统一释放，调用方不得再手动 deinit」**。
- 可选：debug 模式下 destroy 钩子调用后把 `ptr` 指向的内存 poison（`std.mem.doNotOptimizeAway` 之外再填 0xAA），让二次释放更早炸、栈更干净。

### 当前 Workaround

应用侧已改为统一在 `run()` 返回后按 `server.deinit → rt.deinit → 业务资源 → st` 顺序收尾，
不再对已注册中间件实例手动 `deinit`。
