# SERA Web 管理后台

版本 **2.2.1+33**，2026-11-10。后台用于课程项目中的社区运营：发布官方动态与活动、处理帖子和评论、审核管理申请、逐人分配权限、处理账号与查看操作记录。沿用同一 Flutter Web、Provider、go_router、Dio、FastAPI 和 SQLite，没有增加另一套前端、角色框架、数据库或直接依赖。

入口为 `/#/admin`，默认进入 `/#/admin/overview`；本机地址是 [SERA 管理后台](http://127.0.0.1:8787/#/admin)。社区管理中的“管理后台”入口指向同一应用。普通用户仍使用今日／计划／日程／社区四栏；后台不增加第五个主导航，不自动公开个人任务、日程或专注记录。

## 页面与操作

| 分区 | 路由 | 实际用途 |
| --- | --- | --- |
| 概览 | `/admin/overview` | 官方查看近 7／30／90 天注册、发帖评论人数、内容和评论趋势、内容分类及互动排行；普通管理员保留原社区概览 |
| 内容管理 | `/admin/posts` | 分别查看日常、活动、使用反馈与评论；查询、分页、查看完整内容及图片，有对应权限时移除内容并填写原因 |
| 官方发布 | `/admin/publish` | 复用现有发布、最多三张图片上传与失败恢复；按权限发布官方动态或活动，成功后进入内容管理 |
| 管理员与申请 | `/admin/team` | 官方通过完整用户名或邮箱添加已有用户，编辑每位管理员的四项权限，移除管理员，批准或拒绝普通用户申请 |
| 用户 | `/admin/users` | 官方查询脱敏账号摘要，查看状态与社区发帖／评论数量，填写原因后停用或恢复账号 |
| 操作记录 | `/admin/audit` | 官方查看操作者、时间、操作、对象和原因；内容管理行为与审计同事务提交 |
| 运行状态 | `/admin/status` | 官方查看数据库读取、后台心跳和 AI／邮件／语音／推送的脱敏配置说明；不发送外部探测请求 |

宽屏使用侧栏和内容区；窗口窄于 900px 时切换抽屉，表格保留横向滚动，表单限制阅读宽度。后台路由使用完整浏览器宽度；返回普通应用后恢复原来的 430px 移动端容器。

发布页使用已有社区编辑器。发布失败保留文字、图片和重试标识；离开未发布内容会明确确认，取消继续编辑。后台分区间保留同一表单状态，换账号时重新创建表单并清空上一账号输入。发布进行中禁止用户主动离开；账号失效或切换仍按原账号生命周期清理，迟到结果不会进入新账号。

账号切换还会在旧路由退出前释放控件焦点，并在切换队列的微任务中完成待处理焦点更新，避免窗口重新获焦时遍历已经离开渲染树的输入控件。这复用 Flutter 的焦点管理，不建立另一套键盘事件系统。

## 权限矩阵

官方身份来自服务端 `SERA_COMMUNITY_OFFICIAL_USER_IDS`，不能通过注册字段、客户端菜单或请求头取得。管理员身份与四项权限使用现有 `community_admins`，不新增“超级管理员”等角色。四项权限分别是 `publishOfficial`、`publishActivity`、`moderatePosts`、`moderateComments`。

| 能力 | 官方所有者 | 社区管理员 | 普通用户／游客 |
| --- | --- | --- | --- |
| 进入后台、查询公开帖子 | 允许 | 允许，包括尚未分配操作权限的管理员 | 拒绝后台访问；仍可使用公开社区 |
| 发布官方动态 | 允许 | 需 `publishOfficial` | 拒绝 |
| 发布官方活动 | 允许 | 需 `publishActivity` | 拒绝 |
| 在后台移除帖子 | 允许 | 需 `moderatePosts` | 拒绝；社区仍保留本人内容原有删除能力 |
| 查询全站评论、在后台移除评论 | 允许 | 需 `moderateComments` | 拒绝；社区原有评论阅读与本人删除能力保留 |
| 添加／修改／移除管理员，审核申请 | 允许 | 拒绝 | 普通用户只能在社区申请并查看自己的结果 |
| 查询用户、停用／恢复账号 | 允许 | 拒绝 | 拒绝 |
| 运营统计、操作记录、运行状态 | 允许 | 拒绝 | 拒绝 |

普通管理员的概览中，`users`、`admins`、`pendingApplications` 为 `null`；不会返回官方专属数量。菜单隐藏只是界面适配，每个请求及写入事务仍重新读取真实会话、官方身份和最新权限。官方撤权后，旧页面或已打开的弹窗不能绕过服务端限制。

## 接口与查询

实际后台端点共 **10 个**（2.2.1 新增只读统计），统一前缀 `/api/v1/admin`，详细字段见运行中的 `/docs` 或 `/openapi.json`。浏览器沿用同源 HttpOnly Cookie 与 `X-CSRF-Token`；原生／独立测试使用现有 Bearer 会话，没有另一套后台登录令牌。后台数据响应设置 `Cache-Control: no-store`。

| 方法与路径 | 输入与结果 | 服务端权限 |
| --- | --- | --- |
| `GET /analytics` | `days=7/30/90`（默认 30），香港日期、同刻前期、每日指标、互斥分类、当前累计互动与排行；完整口径见 [运营统计](ADMIN_ANALYTICS.md) | 官方 |
| `GET /bootstrap` | `{viewer, counts}`，数量来自实际数据库 | 官方或管理员 |
| `GET /posts` | `q`、`category=all/daily/feedback`、`kind=all/post/activity`、`official=all/yes`、`cursor`、`limit`；返回 `{posts,total,nextCursor}`，帖子 DTO 与社区一致 | 官方或管理员 |
| `GET /comments` | `q`、`postId`、`cursor`、`limit`；返回 `{comments,total,nextCursor}`，评论增加 `postTitle` | 官方或 `moderateComments` |
| `GET /users` | `q`、`status=all/active/disabled`、`cursor`、`limit`；返回 `{users,total,nextCursor}` | 官方 |
| `PUT /users/{user_id}/status` | `{disabled,reason,requestId}`；返回 `{updated:true}` | 官方 |
| `DELETE /posts/{post_id}` | JSON `{reason,requestId}`；返回 `{deleted:true}` | 官方或 `moderatePosts` |
| `DELETE /comments/{comment_id}` | JSON `{reason,requestId}`；返回 `{deleted:true}` | 官方或 `moderateComments` |
| `GET /audit` | `q`、`cursor`、`limit`；返回 `{entries,total,nextCursor}` | 官方 |
| `GET /status` | `{components}`，包括配置状态、可空健康结果和可选心跳时间 | 官方 |

列表默认每页 30 条、最多 100 条；查询最多 200 字，游标最多 512 字符且绑定当前查询与筛选。帖子和评论按递增序号倒序翻页，账号按创建时间和稳定 ID 翻页，新增数据不会让下一页重复读取上一页。SQL 参数绑定，`%`、`_` 和反斜线按字面搜索，不允许调用方注入查询片段。

帖子查询支持标题、正文、实际公开作者名称和准确 ID；评论支持正文、实际公开作者名称和准确 ID。用户支持用户名以及完整邮箱、手机号或 ID；返回值始终脱敏。操作记录支持操作者、对象名称、操作代码与对象 ID。作者查询使用界面实际显示的公开名称，历史邮箱或手机号形登录名不会成为公开作者检索的旁路。

官方发布、媒体上传、管理员设置和申请审核继续调用已有 `/api/v1/community` 端点，不再复制发布或授权业务。后台删除和账号状态操作原因必填，最多 500 字；`requestId` 与操作内容绑定，结果未知时按同一标识重试，内容不同却复用标识返回 `409 idempotency_conflict`。未登录／过期为 401，真实权限或 CSRF 不允许为 403，参数无效为 400，缺失账号为 404；具体错误码与输入约束以 OpenAPI 和契约测试为准。

## 数据、停用与审计

后台用户摘要只含稳定 ID、公开用户名、脱敏邮箱／手机号、邮箱验证状态、注册时间、停用状态和社区计数。不会读取或返回个人工作区正文、密码哈希、会话、私钥、推送订阅内容；后台不提供重置他人密码或修改已验证邮箱的操作。

账号停用使用独立 `auth_account_status` 附表，保持 `users`、身份迁移版本及 workspace schema 2 原样。事务内写入状态、撤销该用户所有会话和 Web 推送订阅、删除语音连接票据、取消仍在执行的 AI 作业及待发提醒，并记录原因。密码登录、手机号登录、新会话创建和已有会话使用均检查状态。工作区、已发布社区内容、专注历史和其他业务记录保留；恢复后用户需要重新登录，旧会话与订阅不会自动复活。官方账号和当前操作者不能被后台停用。

`admin_operations` 保存后台操作幂等收据，`admin_audit` 保存时间、操作者公开名、动作、对象和原因。帖子／评论删除复用 `CommunityStore._delete_in_transaction`，原有媒体、评论、点赞和报名外键级联保持一致。官方发布、管理员增改删和申请审核通过最小审计 hook 在原业务事务内记录；审计写失败时业务与幂等收据一起回滚，不留下“已删除却没有记录”的半成品。重复确认的申请不会重新授予后来被撤销的权限。

运行状态只读取已持久化心跳和现有配置。数据库可读取与 150 秒内正常 worker 心跳可以标为 `healthy`；AI、邮件、语音仅配置检查时为 `configured` 且 `healthy:null`，不能据此宣称供应商可达、邮件已送达或语音模型已加载。此页不调用付费模型、不发送邮件／推送，也不连接 ASR；原 `/health/ready` 的部署检查继续独立使用。

## 启动与官方账号配置

在 `sera_flutter` 目录使用已有依赖环境。常规构建和启动如下；先停止占用同一端口的上一启动进程，不另起多套常驻服务。

```powershell
./scripts/build.ps1 -Target web
./scripts/start-fullstack.ps1 -SkipBuild -EnvFile @('.local/community-private/official.env')
```

其他私有 AI、SMTP、短信配置按需加入已有 `-EnvFile` 数组；只传存在且确实需要的配置文件。密钥留在服务端，不能写入 Dart、构建参数、公开文档或 Web 文件。全栈脚本会复用现有 API、worker、语音与静态文件服务，Ctrl+C 停止其子进程。

当前课程官方账号由原有本地创建脚本管理，凭据位于私有 `.local/community-private/official-account.json`，不要复制到源码或文档。新环境先用现有启动流程初始化指定数据库并停止，再在同一数据库执行：

```powershell
backend/.venv/Scripts/python.exe scripts/provision-community-official.py
```

脚本会先在线备份，不覆盖重名账号、不回显密码、不发送邮件、不伪造邮箱已验证；重复执行保留原凭据。指定隔离库时同时传 `--db` 和独立 `--private-dir`。服务启动加载该目录的 `official.env` 后，使用对应账号登录后台。Compose 在 `deploy/.env` 配置同名 `SERA_COMMUNITY_OFFICIAL_USER_IDS`，仍部署原应用镜像与静态构建，不增加后台服务；部署和 HTTPS 步骤见 [部署说明](../deploy/README.md)。

## 演示与验证

涉及移除、停用、权限变化的演示应使用隔离演示库和测试账号，不对用户现有内容试操作。

1. 打开 `/#/admin`，以官方账号登录并返回概览，核对数量与社区实际内容一致。
2. 在官方发布中填写动态、选择图片并发布；在内容管理查询新内容，打开详情核对正文、图片与真实互动计数。再以活动方式指定开始时间与地点发布。
3. 普通测试用户在社区提交管理申请；官方进入管理员与申请，仅授予所需权限。以该账号打开后台，展示对应菜单和真实可执行操作，未授予操作即使直接请求也被拒绝。
4. 测试账号发表测试帖子和评论；有对应权限的管理员填写原因后移除，刷新社区核对实际删除和计数，官方在操作记录核对操作者、对象与原因。
5. 官方在用户页查询测试账号，填写原因停用，验证另一标签页／会话失效以及重新登录被拒绝；恢复后重新登录，验证旧会话不恢复、原工作区仍保留。
6. 在发布页输入未提交文字，离开时选择继续编辑，核对输入保留；再明确放弃。切换账号时不得看到上一账号草稿或弹窗。
7. 查看运行状态，区分已读取数据库、正常／过期心跳与“已配置”服务，不能把配置存在演示为外部服务联调成功。

本轮新增管理员后端隔离验收已实际完成：

```powershell
backend/.venv/Scripts/python.exe -m unittest discover -s test -p admin_backend_test.py -v
```

**27 项通过，0 失败，17.570 秒**，使用临时 SQLite 和惰性外部供应商。覆盖即时撤权、四权限独立性、Cookie CSRF、账号变化、稳定分页与公开作者检索、实际删除级联及幂等、密码／手机／直接会话停用、恢复、原工作区保留、审计失败事务回滚、旧身份迁移与外键，以及 9 端点 OpenAPI／DTO 契约、无外部请求的状态检查。执行日志为 `.local/admin-backend-isolated-20261109.log`。

该 Python 测试位于 `test/`，单独执行 `backend/` discovery 时需要另外运行上述命令；统一的 `scripts/check.ps1` 已包含后台、管理员接口、配置与交付、Flutter 和 Web 平台检查。完整 Flutter、浏览器、构建和设备结果见 [README](../README.md) 的本轮最终证据。

## 决策依据

- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)：采用最小权限、默认拒绝、每个请求重新校验和集中复用授权边界，并用真实越权与撤权测试验证。SERA 延用已有所有者与四权限，没有为后台建立平行角色体系。
- [Flutter Large screen devices](https://docs.flutter.dev/ui/adaptive-responsive/large-screens)：布局依据当前窗口约束选择侧栏／抽屉和内容宽度，保留鼠标、键盘与表格滚动，避免把手机页面简单放大。复用现有组件与状态，控制新增使用和维护成本。
- [Flutter FocusManager.applyFocusChangesIfNeeded](https://api.flutter.dev/flutter/widgets/FocusManager/applyFocusChangesIfNeeded.html)：待处理焦点应在微任务或帧后处理，不能在 build 中强制提交。SERA 在账号切换队列中清理旧焦点，再释放旧应用与路由。

本轮扩展来自明确的课设与运营需求，管理查询集中在后台；不会把后台搜索、菜单、统计或高级设置重新放回用户的极简主界面。
