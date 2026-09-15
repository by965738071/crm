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

---

## Issue 3（功能请求）：`custom_auth` 挂点太弱，导致框架 AuthMiddleware 无法被 session/DB 类鉴权复用

**标题**：Feature: `AuthConfig.custom_auth` 应支持带状态的身份解析器（resolver），而非无捕获的 `fn (*Context) bool`

**环境**：http_framework 1.0.0（main 分支），Zig 0.17.0-dev.2125

### 背景

`http_security.AuthMiddleware` 目前能校验的只有「与启动时配置的那一个常量比对」的共享
密钥（bearer_token / basic / api_key），它的输出 `AuthInfo` 也只有
`{strategy, token, username, api_key}`——没有 per-user 身份（user_id）概念，`roles`
字段声明了但 `authOk` 从不填充。

对于「cookie session → 服务端会话表 → user_id/role」这类最常见的用户登录态场景，应用
唯一能接进去的扩展点是：

```zig
custom_auth: ?*const fn (*Context) bool = null,
```

但这个签名实际不可用：

1. **无状态**：裸函数指针，没有 `self: *anyopaque`，拿不到 SessionManager / DB，只能依赖全局变量；
2. **只能返回 `bool`**：无法区分 401（未登录）与 403（角色不够），无法携带 error；
3. **给不出身份**：返回 true 后框架只会 `authOk(.custom)` 存一个空的 `AuthInfo`，解析出的 user_id 无法回传；
4. **同步签名**：无法在鉴权时 await 查库（zio 协程下需要可挂起的接口）。

结果是：应用无法复用 AuthMiddleware 的 401/挑战/短路机制，只能在 `Middleware.init`
之上从头写一个鉴权中间件（我们项目里就是这么做的）。这不是 bug——共享密钥定位本身合理，
但文档也未说明该定位，容易让人误以为框架自带「用户登录」能力。

### 期望

提供一个带状态、可返回身份、可失败的解析器挂点，例如：

```zig
pub const Identity = struct {
    user_id: i64,
    roles: []const []const u8 = &.{},
    extra: ?*anyopaque = null,
};

pub const IdentityResolver = struct {
    self: *anyopaque,
    /// 返回 null = 未认证（框架发 401）；返回 error = 由框架渲染 500/自定义错误
    resolve: *const fn (*anyopaque, *Context) !?Identity,
};

pub const AuthConfig = struct {
    ...,
    resolver: ?IdentityResolver = null,
    /// 非空则要求 Identity.roles 至少命中其一，否则 403
    required_roles: []const []const u8 = &.{},
};
```

命中 `resolver` 成功后，框架把 `Identity` 填进 `AuthInfo`（顺带把 `roles` 字段真正
用起来）并 `setUserData`，下游 handler 直接取用。401/403 的载荷格式若能配置化
（如交给应用侧的 ErrorRenderer 定制 JSON）则更佳。

### 收益与边界

- 收益：session-backed / DB-token-backed 鉴权可复用框架的 401/挑战/call-next 机制，应用侧
  鉴权中间件从「完整实现」缩为「一个 resolver 回调」。
- 诚实说明：即使补上此钩子，若应用需要定制 401/403 响应体（如中文 JSON），仍可能选择自写
  中间件。故这是「可复用性」改进，不是「必要性」修复，优先级建议 medium。

### 当前 Workaround

应用在框架 `Middleware.init` + `SessionManager` + `ctx.setUserData` 机制上自写
`AuthRequired` 中间件，完成 session→身份解析与 admin_only 角色门槛。功能无损失。

---

## Issue 4（设计不一致）：AppError 渲染为纯文本，与 JSON 响应包不统一且无可配置钩子

**标题**：`ErrorRenderer` 把 AppError 渲染成 `text/plain`，success/notFound 却是 JSON；应用无法自定义错误体格式

**环境**：http_framework 1.0.0（main 分支），Zig 0.17.0-dev

### 现象

`AppError.toResponse` 写死 `res.text(self.message)`（error.zig:54-57），因此所有
`ctx.failWith(AppError.x(msg))` 的响应体是**纯文本消息**；而成功响应（应用侧 `respond.ok`）
与框架 `StaticFileServer` 404 等路径普遍是 JSON。同一个 API 前缀下出现两种响应格式：

```
GET /api/practice/wrong        → {"ok":true,"data":{...}}          (Content-Type: application/json)
GET /api/practice/wrong (未登录) → 请先登录                          (Content-Type: text/plain)
```

前端统一拦截器（axios 之类）通常假定 `{ok, error:{code,message}}` 包络解析错误，纯文本
错误体会迫使应用为每个请求做 Content-Type 分支判断。

### 期望（任选其一）

- `ErrorRenderer` 提供渲染钩子：`render: ?*const fn (*Context, *Response, AppError) anyerror!void = null`，默认实现渲染 JSON 包络（至少含 `status` 数字码与 `message`）。
- 或直接把默认渲染改为 JSON：`{"ok":false,"error":{"code":"bad_request","message":"..."}}`（code 由 AppError.kind 推导），与 `Response.json` 的成功包络对称。

### 当前 Workaround

应用接受 text/plain 错误体，冒烟脚本对错误文案用 `grep` 断言（而非 JSON 解析）。能用，
但前端阶段（第 8 期）要么写双格式解析器，要么回来定制渲染——不如框架提前留钩子。
优先级建议 medium（不阻断功能，影响前端统一性）。
