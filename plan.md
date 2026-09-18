# 多专业考试学习平台开发计划

> 版本：v1.3（2026-09-18）
> 状态：第 1 期已完成，待开发第 2 期
> v1.3 变更：从单一医学考试平台升级为**多专业通用考试学习平台**：新增专业（projects）一等实体，
> 专业 = 一棵分类子树（root_category_id），课程/资料/题库/试卷等核心内容模型不变，按分类树归属专业；
> 前台顶栏增加专业频道切换，后台新增「专业管理」页；项目目录名 `crm` 保持不变，仅作代号
> v1.2 变更：第 1 期完成并验证（见 9 节备注）
> v1.1 变更：移除 CRM 相关内容（客户档案、跟进记录、待跟进），仅保留考试学习平台

---

## 1. 业务理解

做一个**多专业通用考试学习平台**（医学、建工、土木等任意考试品类均可入驻）：

- **学员端**：考生/从业者等用户注册后，在平台上选定专业频道，学习课程（视频/音频/文档）、查阅资料、刷题练习、参加模拟考试、记笔记、收藏。
- **管理后台**：运营/管理员管理用户、课程内容、题库、资料、公告、订单（手动标记支付）。
- **商业模式**：内容付费（课程/资料）。**第一期不接在线支付**，订单由管理员手动标记"已支付"（如通过线下/微信转账后人工确认）。
- **目标用户**：备考各类职业资格考试的人群（如医师资格、二级建造师、土木工程师等；内容按「专业 + 通用分类树」组织，不写死任何品类）。

### 关键决策记录（对话确认）

| 问题 | 决策 |
|---|---|
| CRM 模块 | **已取消**（v1.1）：不做客户档案/跟进记录，只做学习平台 |
| 在线支付 | 第一期不做，只手动记录支付状态 |
| 角色 | 学员 / 管理员 / 超管（不做讲师角色） |
| 注册方式 | 邮箱+用户名+密码自助注册，管理员可禁用账号 |
| 前端 | 单个 Vue 3 + Element Plus 项目，按角色分学员端/管理后台路由 |
| 架构 | 单进程单体（一个 Zig 二进制 + SQLite 单文件），后端托管前端静态文件 |
| 文件存储 | 本地磁盘 `./data/uploads` |
| Zig 版本 | 0.17.0-dev.2125+0d600e488（本地已装，与 build.zig.zon 一致） |
| 第一期范围外（放二期） | 打卡、学习报告、邀请码、优惠券、WebSocket 客服、在线支付、审计日志 |

---

## 2. 技术选型

| 层 | 选型 | 说明 |
|---|---|---|
| 后端语言 | Zig 0.17.0-dev.2125 | std.Io 新 API 时代 |
| HTTP 框架 | `http_framework`（自研，git 依赖） | 路由、中间件、JSON、session、内置 ORM、静态文件、multipart 上传 |
| 数据库 | SQLite（经 `zqlite`，框架 ORM 已封装） | 单文件 `./data/crm.db` |
| 密码哈希 | `std.crypto.pwhash.argon2id` | Zig 标准库自带 |
| 前端 | Vue 3 + Vite + Element Plus + Pinia + vue-router + axios | 单项目双端（学员/管理后台） |
| 部署 | 单文件：`web/dist` 在 `zig build` 时以 `@embedFile` 内嵌进二进制（v1.4） | `-Dembed-dist=false` 或 dist 缺失时回退为运行期托管 web/dist；开发期用 vite dev server 代理 `/api` |

### http_framework 能力映射（已核对 README）

- 路由：`router.route(.GET, "/users/:id", handler)`，`ctx.param()` 取路径参数
- Handler 三模式：纯函数 / 单例 / 请求级（`initFactory`）
- JSON：`framework.parseJson(T, ...)`、`res.json(.{...})`
- 中间件：`RequestIdMiddleware`、`CompressMiddleware`、`SecurityHeaders`、`CorsMiddleware`、`RateLimiter`、`AuthMiddleware`、`ErrorRenderer`
- 会话：`framework.SessionManager`（cookie session）
- ORM：`framework.orm.Model(T, "table")` + `Query` 构造器 + `insert/findById/updateById/deleteById/findAll/count/paginate`
- 上传：`http_multipart` 模块
- 静态：`framework.StaticFileServer`

---

## 3. 系统架构

```mermaid
graph TD
    B[浏览器] -->|静态资源| S[内嵌 dist 内存表（回退：StaticFileServer 托管 web/dist）]
    B -->|/api/* JSON| R[Router]
    R --> MW[中间件链: RequestId → Security → CORS → RateLimit → Auth]
    MW --> H[业务 Handlers]
    H --> ORM[framework.orm / zqlite]
    ORM --> DB[(./data/crm.db)]
    H --> FS[./data/uploads 文件存储]
```

### 后端目录结构（规划）

```
src/
  main.zig          # juicy 入口：runZio → appMain
  root.zig          # 模块导出
  app/              # 应用装配
    app.zig         # 装配：Config → Db → 迁移/种子 → Services 注册 → 中间件 → 路由 → Server
    state.zig       # State：装配产物的所有权容器（无全局变量，见下约定）
    router.zig      # 路由注册
  db/
    db.zig          # zqlite 封装（Db wrapper）
    migrate.zig     # 建表（PRAGMA user_version）+ 种子数据
  web/
    respond.zig     # 统一 JSON 响应包装
    handlers/       # 按模块划分 handler（auth、courses、questions… 逐期接入）
      health.zig
    dist/           # 前端构建产物（静态托管）
  svc/              # ↓ 以下目录随各期开发逐步创建
```

### 约定

- 统一响应包装：`{ "ok": true, "data": ... }` / `{ "ok": false, "error": { "code": "...", "message": "..." } }`
- 依赖注入：**禁用全局变量**。启动时 `Services.register(state.State, st)` + `seal()` + `server.setServices()`，handler 用 `ctx.service(state.State)` 取回依赖（未来的 SessionManager 等同样注册为服务）
- 认证：cookie session（框架 SessionManager）+ 角色标记存 session；`AuthMiddleware` 保护 `/api/admin/*` 与需要登录的接口
- 时间戳：统一存 Unix 秒（INTEGER）
- 软删除：内容类表用 `deleted` 标记位；用户禁用用 `status` 字段
- JSON 复合字段（选项、答案、规则）存 TEXT，应用层序列化

---

## 4. 角色与权限

| 角色 | 权限 |
|---|---|
| guest | 浏览课程/资料/公告列表与详情，注册、登录 |
| student | guest + 学习（已报名课程）、练习、考试、收藏、笔记、改自己资料 |
| admin | student + 管理后台全部内容管理、订单、公告发布 |
| superadmin | admin + 用户角色管理、启用/禁用管理员、系统设置 |

---

## 5. 功能需求清单

### M-A 认证与用户
- A1 注册（邮箱唯一、用户名唯一、argon2id 哈希）
- A2 登录/登出（限流防暴力破解，失败次数限制由 RateLimiter + session 计数）
- A3 当前用户信息 `/api/auth/me`
- A4 修改密码、修改基本资料（昵称/头像）
- A5 管理员：用户列表（搜索/筛选/分页）、禁用/启用、改角色（仅超管）

### M-B 分类与内容
- B0 专业（projects，v1.3 新增）：CRUD + 启用/停用；创建自动生成同名根分类，改名同步；树内有科目/内容时禁删；专业代码 code 唯一
- B1 多级分类树（CRUD、排序、树查询，?project_id= 可只看某专业子树）；专业根分类禁止在分类页改名/删除，科目挂在根下（可改，不预置）
- B2 课程 CRUD（标题、封面、简介、价格、免费标记、分类、状态草稿/上架、排序）
- B3 章节 CRUD（课程下三级：课程→章→课时）
- B4 课时：类型 = 视频/音频/文档(PDF)/Markdown/图文；关联资料库文件；免费试看标记
- B5 资料库：上传（multipart，本地 `./data/uploads/<yyyy-mm>/`）、下载（鉴权：付费资料需已报名）、按分类筛选、大小/类型校验

### M-C 学习
- C1 报名课程（免费课直接报名；付费课生成待支付订单，管理员标记后生效）
- C2 学习进度：课时完成状态、视频播放位置、Markdown/文档已读标记
- C3 学习时长上报（心跳/离开时），存 `study_logs`
- C4 我的课程列表 + 继续学习入口

### M-D 题库与练习
- D1 题目 CRUD：单选/多选/判断；题干、选项(JSON)、答案、解析、难度、分类；管理员批量导入（JSON/CSV）
- D2 章节练习：按分类/课程抽题，逐题作答即时判分
- D3 随机练习：按分类随机 N 题
- D4 答题记录 `practice_records`；错题自动进错题本，答对可从错题本移除（标记已掌握）
- D5 题目收藏
- （二期）填空题、简答题人工批改

### M-E 模拟考试
- E1 试卷管理：管理员配置（分类、时长、总分、及格分、各分类/题型抽题规则）
- E2 考试流程：开始考试（生成一次性题序，服务端计时）→ 交卷（服务端判分，多选半对规则：少选且无错选得 0.5 倍，错选 0 分——第一期简化为全对才得分）→ 成绩单 + 逐题解析回顾
- E3 考试记录列表、历史成绩

### M-F 订单（内容付费）
- F1 订单：学员下单/管理员代下单，金额、状态（待支付/已支付/已取消）、支付方式备注、操作人、备注
- F2 管理员标记支付/取消，联动报名状态
- （二期）业绩统计、导出

### M-G 平台功能（第一期）
- G1 公告：管理员发布/下架，学员端首页列表+详情
- G2 收藏：课程、资料（题目收藏并入题库模块）
- G3 笔记：按课程/课时记笔记，仅本人可见

### M-H 管理后台统计（基础版）
- H1 后台首页：用户数、课程数、题目数、待支付订单数、今日/7 日新增用户

### 第二期候选（本期不做，仅预留）
打卡、学习报告、邀请码、优惠券、WebSocket 客服、在线支付、填空题/简答题、审计日志、ElasticSearch 类搜索。

---

## 6. 数据库设计（SQLite）

> 全部表含 `created_at INTEGER`；标注者含 `updated_at INTEGER`、`deleted INTEGER DEFAULT 0`。

```sql
-- 用户
users(id INTEGER PK, email TEXT UNIQUE, username TEXT UNIQUE, password_hash TEXT,
      nickname TEXT, avatar TEXT, role TEXT DEFAULT 'student',      -- student/admin/superadmin
      status TEXT DEFAULT 'active',                                  -- active/disabled
      created_at, updated_at)

-- 专业（考试项目，v5）：一个专业 = 一棵分类子树，内容按分类树归属专业，内容表不加专业字段
projects(id PK, code TEXT UNIQUE, name TEXT, logo, description,
         subject_label TEXT DEFAULT '科目',    -- 科目别称：科目/章节/专业实务…
         sort INTEGER DEFAULT 0, status TEXT DEFAULT 'active',  -- active/disabled
         root_category_id INTEGER, deleted, created_at, updated_at)

-- 分类树（专业根分类由 projects 自动维护）
categories(id PK, parent_id INTEGER DEFAULT 0, name TEXT, sort INTEGER DEFAULT 0, deleted)

-- 课程
courses(id PK, category_id, title, cover, summary, description TEXT,
        price INTEGER DEFAULT 0,          -- 分
        is_free INTEGER DEFAULT 0, status TEXT DEFAULT 'draft',      -- draft/published
        sort, enroll_count INTEGER DEFAULT 0, deleted, created_at, updated_at)

chapters(id PK, course_id, title, sort, deleted)

lessons(id PK, course_id, chapter_id, title,
        content_type TEXT,                 -- video/audio/pdf/markdown/rich
        resource_id INTEGER DEFAULT 0,     -- 关联资料库
        content TEXT,                      -- markdown/富文本直接存储
        duration INTEGER DEFAULT 0,        -- 秒
        is_free INTEGER DEFAULT 0, sort, deleted)

-- 资料库
resources(id PK, category_id, name, orig_name, type,        -- video/audio/pdf/doc/image/markdown
          file_path, size INTEGER, mime, uploader_id, is_public INTEGER DEFAULT 1,
          deleted, created_at)

-- 报名与订单
enrollments(id PK, user_id, course_id, source TEXT DEFAULT 'self',  -- self/admin
            pay_status TEXT DEFAULT 'unpaid',                        -- unpaid/paid/free
            created_at, UNIQUE(user_id, course_id))

orders(id PK, order_no TEXT UNIQUE, user_id, course_id, amount INTEGER,
       status TEXT DEFAULT 'pending',                                -- pending/paid/cancelled
       pay_method TEXT, remark TEXT, operator_id INTEGER DEFAULT 0,
       paid_at INTEGER, created_at)

-- 学习
learning_progress(id PK, user_id, lesson_id, course_id,
                  status TEXT DEFAULT 'not_started',    -- not_started/in_progress/completed
                  position INTEGER DEFAULT 0,           -- 视频秒
                  updated_at, UNIQUE(user_id, lesson_id))

study_logs(id PK, user_id, course_id, lesson_id, seconds INTEGER, date TEXT, created_at) -- date: 'YYYY-MM-DD'

-- 题库
questions(id PK, category_id, course_id INTEGER DEFAULT 0,
          type TEXT,                       -- single/multi/judge
          stem TEXT, options TEXT,         -- options JSON: ["...", "..."]
          answer TEXT,                     -- "A" / "ABD" / "T"/"F"
          explanation TEXT, difficulty INTEGER DEFAULT 2,
          used_count INTEGER DEFAULT 0, creator_id, deleted, created_at)

practice_records(id PK, user_id, question_id, is_correct INTEGER,
                 duration INTEGER, source TEXT,   -- chapter/random/exam
                 session_id INTEGER DEFAULT 0, created_at)

wrong_questions(id PK, user_id, question_id, wrong_count INTEGER DEFAULT 1,
                mastered INTEGER DEFAULT 0, last_wrong_at, UNIQUE(user_id, question_id))

question_favorites(id PK, user_id, question_id, created_at, UNIQUE(user_id, question_id))

-- 模拟考试
exams(id PK, category_id, title, duration_min INTEGER, total_score INTEGER,
      pass_score INTEGER, rules TEXT,      -- 抽题规则 JSON: [{type, category_id, count, score_each}]
      status TEXT DEFAULT 'draft', deleted, created_at)

exam_attempts(id PK, exam_id, user_id, questions TEXT,   -- 试卷题序快照 JSON
              answers TEXT,                 -- 作答 JSON（服务端判分后）
              score INTEGER DEFAULT -1, passed INTEGER,
              started_at, deadline_at, submitted_at INTEGER DEFAULT 0)

-- 平台
favorites(id PK, user_id, target_type TEXT, target_id INTEGER, created_at,
          UNIQUE(user_id, target_type, target_id))       -- target_type: course/resource

notes(id PK, user_id, course_id INTEGER DEFAULT 0, lesson_id INTEGER DEFAULT 0,
      content TEXT, updated_at, deleted, created_at)

announcements(id PK, title, content TEXT, status TEXT DEFAULT 'draft',
              author_id, published_at INTEGER DEFAULT 0, deleted, created_at)
```

索引：各外键列、`practice_records(user_id, question_id)`、`study_logs(user_id, date)`、`orders(status)`。

---

## 7. API 设计（REST，前缀 `/api`）

### 公开
| Method | Path | 说明 |
|---|---|---|
| POST | /auth/register | 注册 |
| POST | /auth/login | 登录 |
| POST | /auth/logout | 登出 |
| GET | /auth/me | 当前用户（含角色） |
| GET | /projects | 专业列表（启用中，含 root_category_id 供前台频道过滤） |
| GET | /categories | 分类树（?project_id= 时只返回该专业根分类下的科目子树） |
| GET | /courses | 课程分页列表（?category_id=&sub=1 含子树&keyword=&page=&size=） |
| GET | /courses/:id | 课程详情+章节课时树（未付费用户锁定非免费课时内容） |
| GET | /resources | 资料分页列表（?category_id=&type=） |
| GET | /announcements | 已发布公告（?keyword=&page=&size=，草稿/软删隐身） |
| GET | /announcements/:id | 公告详情 |

### 学员（需登录）
| Method | Path | 说明 |
|---|---|---|
| PUT | /user/profile | 改昵称/头像 |
| PUT | /user/password | 改密码 |
| POST | /courses/:id/enroll | 报名（免费→直接 paid；付费→建订单） |
| GET | /orders | 我的订单分页列表（?status=pending/paid/cancelled，仅本人） |
| GET | /me/enrollments | 我的课程 |
| GET | /me/progress?course_id= | 我的进度 |
| POST | /learning/progress | 上报进度 {lesson_id,status,position} |
| POST | /learning/heartbeat | 时长心跳 {lesson_id,seconds} |
| POST | /practice/start | 开始练习 {mode:chapter/random, category_id, sub?, count} → 题目（不含答案）；category_id=0 全量，sub=1 含子树 |
| POST | /practice/submit | 逐题提交 {question_id,answer,duration} → 判分结果 |
| GET | /practice/wrong | 错题本（分页，?mastered=0） |
| POST | /practice/wrong/:id/master | 标记已掌握 |
| GET | /exams | 可考试试卷列表 |
| POST | /exams/:id/start | 开考 → 题目快照+截止时间 |
| POST | /exam-attempts/:id/submit | 交卷答卷 {answers} → 成绩 |
| POST | /exam-attempts/:id/answer | 自动保存整卷作答 {answers:[{question_id,answer}]}（全量替换；服务端计时/断线恢复的必要补充） |
| GET | /exam-attempts | 考试记录 |
| GET | /exam-attempts/:id | 成绩回顾（逐题+解析） |
| POST | /favorites | 收藏 {target_type,target_id}（幂等；非法 type 400，目标不存在 404） |
| DELETE | /favorites | 取消收藏，参数走 query ?target_type=&target_id=（框架协议层拒收 DELETE 带 body，见 issues#5；未收藏 404） |
| GET | /favorites | 我的收藏（?target_type= 过滤；已软删目标隐身） |
| POST | /notes | 新建笔记 {course_id,lesson_id?,content}（lesson 须属该课，越界 400） |
| GET | /notes | 我的笔记（?course_id=&lesson_id=） |
| PUT/DELETE | /notes/:id | 改/软删本人笔记（越权=404，不暴露存在性） |
| POST | /questions/:id/favorite | 题目收藏切换 |
| GET | /practice/favorites | 题目收藏列表（分页，含答案与解析，复盘用） |
| GET | /resources/:id/download | 鉴权下载（流式） |

### 管理后台（/api/admin/*，role ≥ admin）
| Method | Path | 说明 |
|---|---|---|
| GET/PUT | /admin/users, /admin/users/:id, /admin/users/:id/status | 用户管理、禁用启用 |
| PUT | /admin/users/:id/role | 改角色（仅超管） |
| GET/POST/PUT/DELETE | /admin/projects | 专业管理（CRUD；根分类随建/改名同步；树内有科目/内容时 409） |
| POST/PUT/DELETE | /admin/categories | 分类（专业根分类禁改禁删） |
| POST/PUT/DELETE | /admin/courses, chapters, lessons | 内容管理 |
| POST | /admin/upload | multipart 上传 → resource |
| POST/PUT/DELETE | /admin/resources | 资料管理 |
| POST/PUT/DELETE | /admin/questions | 题目管理；POST /admin/questions/import 批量导入 |
| GET/POST/PUT/DELETE | /admin/exams | 试卷管理（status 随 body 更新；软删后历史考试记录仍保留可回顾） |
| GET | /admin/orders | 订单列表（?status=&keyword=&user_id=，keyword 匹配单号/课程名） |
| POST | /admin/orders | 代下单 {user_id, course_id}（仅付费上架课；建 unpaid 报名+pending 订单） |
| POST | /admin/orders/:id/pay | 标记已支付 {pay_method?, remark?}（同步 enrollment.pay_status=paid 解锁课时） |
| POST | /admin/orders/:id/cancel | 取消订单（仅 pending；删 unpaid 报名行+回退 enroll_count，学员可重新报名） |
| GET | /admin/announcements | 公告列表（?status=draft/published&keyword=，标题+正文检索） |
| POST/PUT/DELETE | /admin/announcements | 公告 CRUD（update 只改文案；软删终态） |
| POST | /admin/announcements/:id/publish,unpublish | 发布/下架（重复操作 400，刷新 published_at） |
| GET | /admin/stats | 后台首页统计（用户/课程/题量/待支付单/今日与7日新增） |

---

## 8. 前端页面清单（Vue 3 单项目）

技术：Vue 3 `<script setup>` + Vite + Element Plus + Pinia + vue-router + axios；开发代理 `/api → http://localhost:8080`；生产 `zig build` 时 `web/dist` 内嵌进二进制（`build.zig` 代码生成 `dist_assets` 模块），由 `src/web/dist_embed.zig` 接管 `/`、`/static/*`、`/assets/*` 与 SPA 回退；改前端后必须重新 `zig build` 才会更新二进制内的产物。

```
web/
  src/
    api/          # axios 封装 + 各模块 api
    stores/       # auth store（user/role）、ui store
    router/       # 路由守卫：requiresAuth / requiresAdmin
    layouts/      # StudentLayout / AdminLayout
    views/
      student/    Login, Register, Home(课程/资料/公告), Courses, CourseDetail,
                  LessonLearn(视频/音频/PDF/markdown 学习页), Resources,
                  Practice(分类练习/随机练习), WrongBook, Exams, ExamTaking(计时答题),
                  ExamResult, MyCourses, MyNotes, MyFavorites, MyOrders, Profile,
                  Announcements, NotFound
                  （复用组件 components/QuestionCard：练习/错题/收藏/考试/回顾五场景）
      admin/      Dashboard, UserList, ProjectManage, CategoryManage, CourseManage(含章节编辑),
                  LessonEdit, ResourceManage(上传), QuestionManage(批量导入),
                  ExamManage, OrderManage, AnnouncementManage
```

关键点：
- 路由守卫按 `role` 区分学员端/后台
- 答题页考试模式不展示答案，练习模式即时反馈
- 考试页本地倒计时 + 到点自动交卷，以服务端 deadline 为准
- 视频播放：HTML5 `<video>`，位置恢复用 `progress.position`

---

## 9. 开发阶段任务

### 第 0 期：基础设施（先行）
- [x] T0.1 目录结构搭建（src/app、handlers、db 等），清理模板代码
- [x] T0.2 配置加载（端口、数据目录、session secret）
- [x] T0.3 数据库打开 + `migrate.zig` 建表 + 幂等迁移方案（PRAGMA user_version 版本号递增）
- [x] T0.4 统一 JSON 响应/错误处理（AppError → 响应包装），接入框架中间件与 logger
- [x] T0.5 种子数据：超管账号、示例分类
- [x] T0.6 健康检查 `/api/health` + 前端静态托管；跑通 `zig build run`
- [x] T0.7 验证 zqlite 多请求并发访问（单进程内加锁），发现问题记录 bug 文档

**第 0 期完成备注（2026-09-13 验证记录）**：

- `zig build test` 3/3 通过；`zig build run` 冒烟通过：
  - `GET /api/health` → `{"ok":true,"data":{"status":"ok",...,"schema_version":1}}`
  - 未注册路由 → JSON 404 envelope；`/` → 静态占位页
- T0.7 并发验证：50 个并发 curl 全部 200，无 SQLITE busy、无崩溃。结论：zio 单线程协程调度 + sqlite 调用间不让出 → 单 `Conn` 不加锁可行，继续观察（后续写接口上线后重测）。
- 框架 ORM（`framework.orm`）实为 **JSON 文件存储**，非 SQLite → 本项目直接使用 `zqlite` 裸 SQL，封装在 `src/db/`。
- 配置策略（v1.2 调整）：**不自建 Config struct**，直接使用 `framework.Config`（network/http/body/pool 分层）；应用级路径（data_dir/db_path/static_dir）暂时硬编码在 `app.zig` 常量。框架缺口（无应用级扩展槽、无 env/文件加载入口）已起草 issue → `http-framework-issues.md`（待提交，gh CLI 未安装）。
- 退出清理约定：`Router.deinit()` 会通过中间件 destroy 钩子**自动调用**带 `deinit` 的中间件实例（如 `RateLimiter.deinit`）。因此：
  1. 不要对已注册进 router 的中间件实例再手动 `deinit`（会 double-free，实测触发 `incorrect alignment` panic）；
  2. `st`（State，持有中间件实例）必须在 `rt.deinit()` **之后**销毁，不能用 `defer` 抢在前面。
  已在 `app.zig` 中按 `server.deinit → rt.deinit → st → db close` 顺序收尾，并为错误路径配了对称 `errdefer` 链；正常退出与 AddressInUse 错误退出均验证 0 泄漏。
  该 double-deinit 陷阱也已在 `http-framework-issues.md` Issue 2 中建议框架改善文档。
- 环境提醒：`zig-pkg/` 是包缓存目录，不要手工编辑；损坏时删除该目录后 `zig build --fetch` 可恢复。

### 第 1 期：认证与用户（M-A）
- [x] T1.1 注册/登录/登出/me（argon2id + session）
- [x] T1.2 登录限流、禁用账号拦截
- [x] T1.3 资料/密码修改；管理员用户管理接口

**第 1 期完成备注（2026-09-14 验证记录）**：

- `zig build test` 全绿（auth 哈希/LoginGuard/镜像 各 repo 单测）。
- `scripts/smoke_phase1.sh` 40/40 通过，覆盖：注册（含重复 409、坏 JSON 400）、登录/登出/me（含无 cookie 401、学员打 /admin 403）、改资料、改密+会话轮换、禁用拦截（403）、登录限流（5 次 401 后 429）、角色变更（自改 400）、泄漏/AddressInUse 检查。
- 修复：冒烟脚本 admin 登录的占位密码 `***` → 种子默认密码 `admin123456`（此前该步骤一直假失败）。
- 安全约定落地：登录成功/改密后调用 `session.rotate` 防会话固定；禁用账号由 /me 自查 + 中间件不查库，详见 `auth_middleware.zig` 注释。
- 待办：`http-framework-issues.md` 建议已起草，仓库尚无 commit（git 未初始化提交），后续补齐。

### 第 2 期：内容与资料（M-B）

- [x] T2.1 分类树 CRUD（种子 7 个一级分类全为根节点 sibling，管理端支持传参生成任意父子树）+ 公开树查询
- [x] T2.2 课程/章节/课时 CRUD + 管理端列表/详情 + 公开端「只显示 published、草稿 404」
- [x] T2.3 资料库：multipart 上传落盘（`./data/uploads/<yyyy-mm>/`）、鉴权下载（私密需已登录+管理端 or 已报名[p3 定]; 游客 401）、管理员元数据维护

**第 2 期完成备注（2026-09-14 验证记录；沿用第 1 期「干净机器 + 全新 DB」纪律后全绿）**：

- 分类/课程/章节/课时/资料全部走真实 HTTP 冒烟：`scripts/smoke_phase2.sh` **PASS=41 FAIL=0**，同二进制 `zig build test` 8/8、期一 40/40。
- 经验（期二踩的 3 个 ALL 是**冒烟脚本自身缺陷**而非框架/路由，已修）：
  1. 冒烟里对 `categories` 树取 id 用的是「对象」的 `['data']['id']`，但 `/api/categories` 返回**数组** → 空 id → `PUT/DELETE /api/admin/categories/`（集合）→ 405「Method Not Allowed」。改为 `['data'][0]['id']`。
  2. 冒烟 DELETE 了**种子根（id=1）**（期二初误写「有子分类 409」前提，种子 7 个全为根），之后所有依赖 `category_id=1` 的 create 全部「分类不存在」。改用**临时分类**做 update/delete 验证，种子根保持不动。
  3. 查询参数 `?keyword=课程 B` 直接塞中文，未 URL 编码 → 服务器收到空 keyword，匹配全表首条（误判「草稿泄漏」）。改成 `%E8%AF%BE%E7%A8%8B%20B`。
- 结论：**三个「分类不存在」FAIL 均非产品代码 bug**；框架 multipart/下载/405 语义均按规约工作。期二验证同时确认了「种子纯兄弟根」这一已知约束（分类树层级由管理端 POST 展开，属产品预期，非缺陷）。


### 第 3 期：学习（M-C）
- [x] T3.1 报名（免费直通/付费建订单）
- [x] T3.2 进度上报/查询、心跳时长
- [x] T3.3 我的课程、继续学习数据

**第 3 期完成备注（2026-09-15 验证记录，Windows）**：

- `zig build test` 11/11 全绿（learning_repo 报名/解锁/upsert/聚合/utcDate 单测）；`scripts/smoke_phase3.sh` **PASS=66 FAIL=0**，覆盖：报名 404（不存在/草稿）、付费 pending_payment+order_no、幂等 already_enrolled、未支付不解锁 403、免费课直通、试看课时未报名可学、进度 upsert 同行、position 负值钳 0、status 白名单 400、坏 JSON/缺参 400、心跳 seconds 1-600 边界 400、UTC 日期、我的课程聚合（completed/last_lesson/last_position/排序）、me/progress、游客 401。
- 设计：`order_no = O{now}-{enroll_id}`（确定性，UNIQUE 兜底）；报名+建订单包 `BEGIN IMMEDIATE` 事务；解锁规则 = `pay_status IN ('paid','free')`，支付标记留给第 6 期；`learning_progress` UPSERT 靠 `UNIQUE(user_id,lesson_id)`；`study_logs` 按 UTC 日期聚合（为第 7 期统计预留）。
- 踩坑 1（**Zig 0.17.0-dev std.fmt 怪癖**，非框架问题）：有符号整数带宽度格式会给正数加 '+'（`{d:0>4}` 对 i64 1970 → "+1970"，见 `Io/Writer.zig printIntAny`）→ `utcDate` 转 u64 后零填充；`storage.monthDir` 因 `epoch.Year=u16` 不受影响。
- 踩坑 2（Windows 环境）：git-bash 下 curl argv 里的中文被系统码页破坏 → 服务端收到非法 UTF-8 → JSON 400。第 3 期脚本请求体全 ASCII；后续脚本在 Windows 上验证时遵循同一约定。
- 踩坑 3（Windows 环境）：无 POSIX 信号，`kill` = TerminateProcess（rc=143），无法验证 SIGTERM 优雅关停 → 脚本按平台分支断言；Linux/macOS 上仍验 exit 0 + 泄漏检查。

### 第 4 期：题库与练习（M-D）
- [x] T4.1 题目 CRUD + 批量导入
- [x] T4.2 章节/随机练习、判分、答题记录
- [x] T4.3 错题本 + 掌握标记 + 题目收藏

**第 4 期完成备注（2026-09-15 验证记录，Windows）**：

- `zig build test` 18/18 全绿（新增 question_repo CRUD/校验/抽题/CSV 解析与 practice_repo 错题/收藏集成测试）；`scripts/smoke_phase4.sh` **PASS=98 FAIL=0**（连跑两遍幂等），覆盖：建题四类校验失败（题型/分类/多选单字母/答案越界）、judge 选项忽略与 TRUE→T 规范化、更新答案、列表过滤（分类/keyword/type）、JSON 导入（全有成败：坏批含「第N行」文案且总数不变）、CSV 导入（引号字段含逗号/列数不正 400）、questions+csv 二选一 400、游客 401、坏 mode/空池 400、count 钳制、抽题视图不含答案/解析（python 断言）、used_count 递增、判分全分支（判分宽松：乱序重复小写；judge 接受 true；空答/无字母/坏 source/坏 duration → 400）、错题本 count 累加 + 答对自动 mastered、wrong_count 保留、mastered=0/1/-1 列表、手动掌握（幂等）+404、收藏切换/列表/404、软删联动（get/submit/收藏 404，错题列表隐藏）。
- 设计：答案入库即规范化（judge "T"/"F"、单选 1 字母、多选升序去重 "ABD"），options 以 JSON 字符串数组存列；练习**无状态**（start 抽题 + submit 逐题即时判分，不落会话），`practice_records.session_id=0` 预留给第 5 期考试（= exam_attempts.id）；错题本 UPSERT 在 `BEGIN IMMEDIATE` 事务内与答题记录同写，答对只置 mastered=1 不清零 wrong_count（复盘价值）；抽题/错题/收藏查询一律 `JOIN questions ... deleted=0`，软删题自动隐身。导入语义「先全量校验、全对才入库」，避免部分导入后前端难对账。
- 新增路由（§7 未列，属功能闭环必要补充）：`GET /api/practice/favorites`（D5 题收藏需读端点；§7 的 `GET /favorites` 是第 7 期 G2 课程/资料通用收藏，路径不冲突）。
- 踩坑 4（**Zig 0.17.0-dev 语言变更**，非框架问题）：`**` 数组重复运算符已移除 → `@splat(false)` 配合目标类型推导长度；`catch |e| {} else |v| {}` 已移除 → 用 `if (expr) |v| {} else |e| {}`；`std.ArrayList(T).init(alloc)` 移除 → `.empty` + `append(a, ..)`；switch 的 prong **不再收窄** catch 捕获的错误集 → `validationMsg` 改收 `anyerror` + else 兜底；`std.ascii.upperString` 不再返回 error union，且定长栈缓冲遇超长输入 debug assert → 改 `std.ascii.eqlIgnoreCase` 逐字比较（同时堆除了一类潜在 panic：学员对判断题送超长字符串可炸进程）。
- 踩坑 5（冒烟脚本）：AppError 错误体是**纯文本**（框架 ErrorRenderer `res.text`，见 issues 草稿 Issue 4）→ 断言错误文案用 `grep` 而非 json.load；bash 单引号串里的 `\"` 不会被剥除（是字面量），JSON 结构引号用裸 `"`、仅字段值内引号用 `\"`。

### 第 5 期：模拟考试（M-E）
- [x] T5.1 试卷管理 + 抽题规则
- [x] T5.2 开考/交卷/服务端计时判分/成绩回顾

**第 5 期完成备注（2026-09-15 验证记录，Windows）**：

- `zig build test` 23/23 全绿（新增 exam_repo：validateExam 全分支、rules/快照/作答 JSON 往返、gradeAnswer、drawSnapshot 池校验/同桶去重/题型交集、考试全流程落库集成测试）；`scripts/smoke_phase5.sh` **PASS=112 FAIL=0**，并在同一二进制上**连跑 30 轮全绿**（跨运行数据累积下仍幂等）。
- 冒烟覆盖：建卷校验 8 失败分支（分值合计不一致/坏 status/空规则/规则分类不存在+文案/count 0/主分类不存在/空标题）、管理端列表（status/keyword/category 过滤）与 404、学员列表（草稿隐身+my_attempts/my_best_score）、游客 401×3、开考（快照无答案泄漏 python 断言/deadline=+duration/首轮 resumed=false）、自动保存全对、断线恢复（同 attempt_id+存量作答回显）、空 body 交卷用存量判分、重复交卷 400、交卷后保存 400、题池不足 400+文案、草稿卷开考 404、第二场答错+空白（score 0；错题本只进有作答的错题，空白不污染）、第三场交白卷、未交卷回顾 400、成绩回顾（逐题正确答案/解析/学员作答/得分，删除试卷后仍可读且标题不崩）、历史列表 exam_id 过滤、越权读/存/交他人考试 404×3、管理端更新（校验+404）、删除试卷→新开考 404 但历史可读、关停泄漏检查。
- 设计：试卷校验为纯函数 `exam_repo.validateExam`（规则 Σcount∈1..100、Σ(count×score_each)=total_score 精确一致；status 随 body 更新，无独立发布接口）；开考把题面+每题分值整体快照进 `exam_attempts.questions`，判分与题库后续变更解耦；服务端计时 = deadline_at + 惰性结算（start 时发现过期 → 用已保存作答自动交卷 submitted_at=deadline，再开新场）；交卷允许超时后补交存量作答（正常判分）；判分全对才得分（多选部分分留第二期）；交卷后 answers 列回写含 correct 字段（服务端结论）= 完整判分记录，回顾直读不受题库编辑影响；逐题写 `practice_records`（source=exam，session_id=attempt.id，兑现第 4 期预留）；错题本仅非空作答才动。
- 抽题算法（`drawSnapshot`）：规则按 (category, type) 聚合分桶；**两层可行性校验**：①每桶该题型存量≥桶需求；②每分类 Σ总需求≤分类总存量——「任意题型」桶与具体题型桶共享同一物理池，只按桶各自计数会漏判重叠超需（同题重复抽入/卷面凑不满）。抽题序：具体题型桶先抽（同分类内不同题型池互斥），「任意」桶多抽 need+prev 候选再排除已用 id（存活≥need 由校验②保证）。卷内题序=规则声明顺序（有意，题型分段便于前端）。
- 踩坑 6（**std.json 借用输入内存 + zqlite Row 生命周期 → 悬垂指针**，应用代码问题非框架）：std.json parseFromSlice 的字符串字段（Value 与静态解析、无转义路径）引用输入缓冲；row.text() 在 Row.deinit 后悬垂 → exam 的 rule.type 读出乱码（冒烟见空题型+误判池不足；交卷判分也会错）。修复 = decode* 入口先把输入 dupe 到 arena 再解析（`question_repo.decodeOptions` 同病同治——前 4 期冒烟只是内存未被复用的侥幸）。新纪律：**凡从 Row 文本做 JSON 解析，必须经 decode* 函数的 arena 拷贝路径**。
- 踩坑 7（冒烟脚本/Windows，非框架问题）：间歇性串响应/串请求体的根因 = **固定文件名（.smoke/last.json、ansb.json）偶发共享违规锁**（Defender 类扫描器对新写文件短暂无共享句柄），curl -o / echo > 静默失败保留旧内容 → 后续断言读到陈旧数据整条链误判；python raw socket 600 请求校验 content-length 全对 → 排除框架丢 body。修复 = 每响应一个唯一序号文件（目录文件数即序号，规避子 shell 无法回传变量），写入失败落哨兵文件响亮报错；内联 python 读响应一律显式 `encoding='utf-8'`（中文错误体在 GBK locale 下直接报错）。第 4 期脚本同病（固定 last.json），后续若复现可照搬此 harness。

### 第 6 期：订单（M-F）
- [x] T6.1 订单创建/列表/取消
- [x] T6.2 标记支付联动报名状态

**第 6 期完成备注（2026-09-16 验证记录，Windows）**：

- `zig build test` 25/25 全绿（新增 order_repo 状态机/联动/列表过滤集成测试）；`scripts/smoke_phase6.sh` **PASS=105 FAIL=0**，同二进制**连跑 3 遍全绿**（跨运行数据累积下仍幂等：列表断言全部带 user_id/keyword 过滤）。
- 冒烟覆盖：报名建单 pending+金额、未支付课时 403、学员列表（状态过滤/非法 status 400/伪造 user_id 参数被无视）、游客 401×2、学员打管理端 403×4、管理端列表（单号/课程名 keyword、分页 page/size）、pay 校验链（404/路径 id 非数字 400/坏 JSON 400/remark 超长 400）、标记支付→paid+operator+paid_at、报名解锁（re-enroll already_enrolled+paid、课时 200）、终态守卫（重复 pay/取消已支付 → 400 带文案区分终态）、取消→报名回滚+enroll_count 回退+可重新报名新单、代下单（username/operator 回显、重复报名/免费课/草稿课 400、用户/课程 404、user_id=0 400）、代下单支付联动解锁、四状态计数汇总、学员间隔离、关停泄漏检查。
- 设计：orders v1 建表已含 F1 全部列（pay_method/remark/operator_id/paid_at），**无需迁移**；状态机 = 唯一可操作态 pending，paid/cancelled 终态，改态 UPDATE 带 `status='pending'` 守卫（changes==0 → InvalidState），单连接串行下幂等；备注「空则保留」用 `COALESCE(NULLIF(?,''),remark)` 实现；取消联动删 unpaid 报名 + `enroll_count = CASE WHEN > 0 THEN -1`，避免旧 unpaid 行永久卡 already_enrolled；`GET /orders` 学员端强制 `user_id=本人`（查询参数不可覆盖），杜绝越权读单；管理端列表 LEFT JOIN users/courses（订单为财务凭证，不随课程软删隐身），keyword 同匹配单号与课程名。代下单复用 `O{now}-{enroll_id}` 单号规则与报名事务模式（BEGIN IMMEDIATE 包多表写）。
- 本期未发现 http_framework 新缺陷（issues 1-4 维持现状）；`timeout_ms` 参数导致终端工具「input not fully received」属环境层问题，与框架无关。

### 第 7 期：平台功能（M-G/H）
- [x] T7.1 公告；T7.2 收藏/笔记；T7.3 后台统计接口
- 完成备注（2026-09-16）：
- `zig build test` 33/33 全绿（新增 announcement/favorite/note/stats 四个 repo 集成测试）；`scripts/smoke_phase7.sh` **PASS=126 FAIL=0**，同二进制**连跑 3 遍全绿**。
- 冒烟覆盖：公告草稿公开隐身/发布可见/下架再隐身、重复发布与重复下架 400、文案更新不动状态、status 过滤、标题与正文双 keyword 检索、软删终态（详情/更新/发布/再删全 404）、空标题 400、学员打管理端 403、游客 401；收藏幂等 add、filter、目标软删隐身、取消后再取消 404、跨用户隔离、非法 type 400、目标不存在 404、**框架拒收 DELETE+body 行为显式断言**；笔记建/改/查/软删、lesson 归属校验、越权 404、内容空 400、用户隔离；统计用 before/after 相对增量（注册用户→users/today/7d +1、建题/建课/代下单 pending →+1 操作回退后回基线）+权限 401/403；关停泄漏检查。
- 设计：公告状态机 draft↔published，守卫在 repo 的 `UPDATE ... WHERE status=...`（changes==0 → InvalidState），handler 预检只为区分 404/400 文案；update 只改文案，状态只能走 publish/unpublish（避免双入口互覆）；发布刷新 published_at，下架保留原值。收藏表与题收藏分表（语义不同：题收藏服务于刷题复盘）；add 用 INSERT OR IGNORE+UNIQUE 幂等；列表 LEFT JOIN 目标表过滤软删（收藏隐身而非报错，与题收藏一致）。笔记所有 SQL 带 user_id 守卫，越权=404；课/时软删不影响笔记可见性（用户自有数据）。统计 UTC 日历日窗口与 study_logs 归日口径对齐；进程内单实例假设同 Db。
- 新增路由（§7 未列，功能闭环必要补充）：`GET /api/admin/announcements/:id`（后台编辑前取单条）。收藏 DELETE 参数载体由 body 改为 query（框架限制，见 issues#5）。
- 发现并记录 http_framework 新缺陷 **issues#5**：DELETE/GET 等方法携带 body（CL>0）在协议层直接 400（防走私拒收，RFC 9110 允许 DELETE+body），文档与错误信息均未说明；本应用在框架设计内（未改依赖代码），workaround = 取消收藏走 query 参数。另：本次发现仓库层测试因未入 root.zig 而长期未编译（announcement/note/favorite 三处 bug：deleteSoft 参数、多行字面量拼接丢换行、COUNT 双 SELECT）——属应用侧纪律问题（新模块必须同步导根），已修。

### 第 8 期：前端学员端
- [x] T8.1 项目脚手架 + 布局 + 路由守卫 + axios 封装
- [x] T8.2 认证页 + 首页 + 课程列表/详情/学习页
- [x] T8.3 资料库、练习、错题本、考试、个人中心

**第 8 期完成备注（2026-09-16 验证记录，Windows）**：

- `cd web && npm run build` 产物全绿（21 视图 + 布局 + QuestionCard 复用组件，vite 无错误）；`zig build` 通过；`zig build test` 33/33 同二进制全绿；`scripts/smoke_phase8.sh` **PASS=23 FAIL=0**，覆盖：`GET /` 返回 index.html 且引用 `/static/assets/*`、6 类深链（含 `/exam-taking/9`、`/lessons/3`、乱路径）回退 index.html、真实 JS/CSS 产物 200 且 content-type 正确、缺失静态文件 404、`/api/*` 未知路径 JSON 404（不被回退吞掉）、POST 深链 404（仅 GET 回退）、关停日志干净。
- 后端配套（SPA 支撑，本期内完成）：`src/web/respond.zig` 新增 `SpaFallback` 非 /api 的 GET 深链返回启动时 `readFileAlloc` 进内存的 index.html（文件缺失→空串→退化为 JSON 404，不致命）；`router.zig` 挂 `notFoundHandler`；`app.zig` 启动读文件 + errdefer/退出对称释放。
- 硬约定：`vite.config.js` 的 `base: '/static/'` 必须与后端 `static_assets` 资源篮前缀 `/static` 一致，改 base 即白屏；dev 代理 `/api → 127.0.0.1:8080`。
- 关键交互设计：
  - **axios 拦截器**：成功返回 `d.data`；错误体兼容 text/plain 中文（ErrorRenderer，见 Issue 4）与 JSON 双格式提取 message 统一 `ElMessage.error`；401 清 auth store 跳 `/login?next=`。
  - **auth store**：`unknown` 三态（未拉过 /me）；路由守卫 `meta.auth` 首跳先 `loadMe`，失败带 `next` 回跳；`guestOnly` 已登录进 `/home`。
  - **考试答题页**：start 快照存 sessionStorage（`exam_<attempt_id>`）；30s debounce 全量自动保存（只提交非空答案，服务端整体替换语义）；本地倒计时归零自动交卷（以服务端 deadline 为准）；快照丢失时考试中心历史列表「继续作答」重新 start 可恢复（resumed 回显存量作答）；beforeunload 拦截误关。
  - **学习页**：video/audio `timeupdate` 10s 节流上报 `in_progress+position`，`ended` 报 completed，播放期 30s 心跳；PDF 因 `Content-Disposition: attachment` 不可预览，改为下载卡片；课时路由 `/lessons/:id?course_id=`（课时无反查课程接口，入口跳转必须带参）。
  - **改密**：后端 `session.rotate` 后经 Set-Cookie 无感下发新 cookie，前端不跳登录。
  - 练习/考试题目统一用 `QuestionCard`（answer 字符串协议：单选 "A"、多选升序 "AB"、判断 "T"/"F"、填空原文）。
- 本期未发现 http_framework 新缺陷（SPA 回退、静态托管、中间件均按预期工作），issues 文档无新增。

### 第 9 期：前端管理后台
- [x] T9.1 Dashboard、用户、分类、课程/课时编辑
- [x] T9.2 资料上传、题库/试卷管理、订单、公告

**第 9 期完成备注（2026-09-16 验证记录，Windows）**：

- `cd web && npm run build` 全绿（10 个 admin 视图 + AdminLayout，全部按路由懒加载分包）；`zig build` 通过；`zig build test` 33/33；`scripts/smoke_phase8.sh` **PASS=23 FAIL=0**（SPA 回退不受影响）。
- 骨架：`/admin` 父路由 `meta {auth, admin}`，守卫先 `loadMe` 再按 `auth.isAdmin` 拦非管理员（手输 URL 兜底回 /home）；学员端顶栏仅 admin 可见「管理后台」入口。
- 后端字段对齐约定（前端表单逐一对齐 handler 结构体）：`is_free/is_public` 一律 0/1 整数（非 bool）；课程价格单位分（表单输入元、提交 ×100）；question `valid_types` 实际只有 **single/multi/judge**（无 fill）；题目列表直接回完整 Question（含答案/解析，可喂编辑表单）；资料上传 multipart 字段 `is_public` 为 '1'/'0' 字符串。
- 试卷表单：抽题规则动态行（type/分类/count/score_each）+ 实时 Σ 校验，Σ(count×分值)≠总分或总题数>100 时 el-alert 报红并禁用保存（与后端 `validateExam` 硬校验镜像，避免提交才发现 400）。
- **修复后端真 bug（本项目 handler，非框架）**：`resources.zig` 的 `metaUpdate` 复用了 create 的 `validateMeta`，强校验 `file_path` 非空 + `uploads/` 前缀，但 `ResourceView` 不暴露 file_path → 管理端元数据编辑从 API 客户端必 400。改为 file_path 校验只留在 `metaCreate`；`smoke_phase2.sh` 补两条回归用例（4 字段 PUT 200 + 非法 rtype 400），并已内联 curl 验证（PUT 200、改名落库、坏 rtype 400、DELETE 200）。
- 踩坑（环境既有）：`smoke_phase2.sh` 从未做 Windows 移植（中文 JSON body 被 GBK 破坏、POSIX 信号断言），在本机整体跑不通；新增用例遵循请求体纯 ASCII 约定，逻辑在 Linux/macOS 可验证（本地用内联 curl 等价验过）。
- 本期未发现 http_framework 新缺陷（issues 仍为 1–5），资料元数据问题属应用层校验复用不当。

### 第 10 期：打磨与部署
- [ ] T10.1 端到端冒烟（脚本或手动清单）、性能与限流调优
- [ ] T10.2 打包脚本：`zig build -Doptimize=ReleaseSafe` + 前端 build + 部署说明 README
- [ ] T10.3 备份策略：SQLite 定时复制（简单 cron 脚本）

> 每期完成后运行 `zig build test`；后端接口用 `zig build test` 内的集成测试或 curl 冒烟覆盖。

---

## 10. http_framework bug 记录机制

- 发现框架 bug 时立即记录到 `http-framework-bug.md`，编号 `BUG-001` 递增。
- 模板字段：**日期 / 模块（router、orm、session、multipart…）/ 症状 / 最小复现代码 / 疑似位置 / 对本项目的影响 / 当前 workaround / 状态（open/fixed）**。
- 严重 bug（崩溃、数据损坏、安全）先在业务侧加 workaround 保证进度，再继续开发。
- 修复框架后回到该文档更新状态，必要时同步 bump `build.zig.zon` 依赖 hash。

---

## 11. 风险与待办确认

| 风险 | 应对 |
|---|---|
| zqlite/ORM 在并发请求下的线程安全未验证 | ✅ T0.7 已验证（50 并发全 200，单 Conn 无锁可行）；写接口上线后重测 |
| 框架 ORM 能力不足（多表 JOIN、聚合统计） | 回退手写 SQL（zqlite 原生 prepare/exec），封装在 `db/` 层 |
| 大文件上传内存占用 | 确认 multipart 是否流式写盘；不支持则限制上传大小（先限 200MB）并记录 bug |
| Zig 0.17-dev API 仍在变动 | 升级前全量 `zig build test`；技能库以 0.16 为基准，细节以本地工具链报错为准 |
| 视频托管带宽 | 第一期本地磁盘即可，文档预留 resource.file_path 可改对象存储 |
