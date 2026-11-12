# SERA 账号、同步、AI 与语音 API

实现为 FastAPI/Uvicorn + SQLite WAL，面向 Android + Web 的单主机课程部署。服务从旧整份工作区 API 平滑迁移，工作区数据格式为 schemaVersion 2；URL 仍为 `/api/v1`。可执行契约位于 `/openapi.json`，交互文档位于 `/docs`。请求、响应 schemas 与 Bearer/Cookie 安全方案均显式列出，未知 API 返回 JSON 404。

## 启动与配置

在 `sera_flutter` 目录执行（Python 3.11）：

```powershell
python -m venv backend/.venv
backend/.venv/Scripts/python.exe -m pip install -r backend/requirements.txt -c backend/requirements.lock.txt
backend/.venv/Scripts/python.exe backend/download_asr_model.py
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin
python web/generate_offline_manifest.py build/web
backend/.venv/Scripts/python.exe backend/server.py --web-dir build/web --ai-key-file ../硅基流动AI接口api.txt
```

另开两个终端，使用同一数据库启动 worker 和本地 ASR：

```powershell
backend/.venv/Scripts/python.exe backend/worker.py --db backend/sera.sqlite3 --ai-key-file ../硅基流动AI接口api.txt
backend/.venv/Scripts/python.exe backend/local_asr.py --db backend/sera.sqlite3
```

默认网页/API `http://127.0.0.1:8787`，独立语音服务 `ws://127.0.0.1:8790/ws`。非默认端口设置 `SERA_ASR_WS_URL`（浏览器可访问完整地址）和 `SERA_ASR_HEALTH_URL`（API 所在主机可访问的 `/health` 地址）。Web 构建使用 `API_BASE_URL=same-origin`，Android 模拟器使用 `API_BASE_URL=http://10.0.2.2:8787`。Web 的 HttpOnly cookie 要求浏览器与 API 同源；4180/4181 的 CORS 许可供调试使用，不保证第三方 Cookie 策略允许跨站会话。

Android的API地址与语音票据中的WebSocket地址是两个配置：使用`10.0.2.2`访问API时，服务端也应将`SERA_ASR_WS_URL`设为`ws://10.0.2.2:8790/ws`，或额外建立`adb -s <设备ID> reverse tcp:8790 tcp:8790`以使用默认回环语音地址。`scripts/run-android.ps1`默认同时转发8787与8790。

密钥仅由服务端从 `SILICONFLOW_API_KEY` 或 `SILICONFLOW_API_KEY_FILE`/`--ai-key-file` 读取，不进入 Flutter 构建、工作区、API 响应或交付包。模型默认 `Qwen/Qwen2.5-7B-Instruct`，可用 `SILICONFLOW_MODEL`/`--ai-model` 配置。云端音频模型默认 `FunAudioLLM/SenseVoiceSmall`。模型调用失败明确返回错误，不伪装成模板或识别成功。依赖固定版本见 `backend/requirements.txt`，当前环境冻结见 `backend/requirements.lock.txt`。

## 会话、邮箱与账号

社区共享内容、官方与管理员权限、申请审核接口见[社区接口与权限说明](COMMUNITY.md#接口)。读取社区允许游客，所有发布、互动和管理写入继续要求有效会话；Web 的写入和账号切换保护复用本节已有 Cookie/CSRF 机制。官方所有者只能通过服务端 `SERA_COMMUNITY_OFFICIAL_USER_IDS` 指定，公开注册请求不能指定角色。

客户端默认使用独立的设备工作区，不要求登录；任务、日程、草案与偏好保存在本机数据库。账户 REST 和同步接口继续要求真实账户认证。主动选择“登录并同步”后才合并到当前账户；恢复已有登录会话不会自动导入设备记录。本机原始副本与按账户保存的合并收据保留在设备，账户退出不会把账户缓存当作设备副本。

页面操作与失败恢复见 [邮箱验证与账号恢复](ACCOUNT_RECOVERY.md)。客户端支持粘贴对应操作的完整邮件链接，验证后刷新当前账号资料；Android 外部邮件 App Link 和可跨设备访问的公网 origin 需单独部署验证。

Web 请求头 `X-Sera-Client:web`：注册/登录响应不含可读取的 Bearer，浏览器保存 `HttpOnly; SameSite=Strict` 会话 Cookie，HTTPS 时加 Secure。响应含 `csrfToken`、稳定 `sessionId` 和 `cookieSession:true`；所有 Cookie 鉴权写请求发送 `X-CSRF-Token`。`GET auth/me` 可在刷新后恢复同一 CSRF 值。原生使用 `Authorization: Bearer <token>`，Flutter 将 token 存入系统安全存储。

密码使用每账号随机盐 + PBKDF2-HMAC-SHA256 600000 轮；会话只保存 SHA256 摘要，7 天过期。用户名 3–40 位（字母、数字、中文、下划线、连字符），邮箱最长 254 且必须为单一邮箱地址，密码 10–128 位。登录/注册限流每来源 IP 15 分钟 30 次；邮箱动作每账号/类型每小时最多 5 次。找回密码另有独立的来源 IP 每 15 分钟 30 次限制，计数仅使用来源地址摘要，不依赖邮箱是否注册。邮箱验证为状态标记，当前不强制阻止未验证账号使用工作区。

| 方法与路径 | 请求 / 响应 |
| --- | --- |
| POST `/api/v1/auth/register` | `{username,email,password}` → 201 会话 |
| POST `/api/v1/auth/login` | `{identifier,password}` → 会话；identifier 为用户名或邮箱 |
| GET `/api/v1/auth/me` | 当前 `{user,expiresAt,sessionId,csrfToken,cookieSession}` |
| POST `/api/v1/auth/logout` | 撤销当前会话；客户端标记退出，响应不改共享Cookie |
| POST `/api/v1/auth/email/verification/request` | 已登录；返回真实邮件模式、处理状态与提示，失败明确返回 503；已验证账号返回 `sent:false` / `already_verified` |
| GET `/api/v1/auth/development-mailbox?purpose=verify-email` | 已登录且 `local` 模式；仅当前账号有效且未消费的验证邮件，响应 `Cache-Control:no-store`；无有效邮件时 `mail:null` |
| POST `/api/v1/auth/email/verification/confirm` | `{token}` → `{verified:true}`；有效登录会话仅能确认本账号链接 |
| POST `/api/v1/auth/password/reset/request` | `{email}` → 统一申请受理响应，已存在/不存在、账号限流、投递失败均相同；来源 IP 限流统一返回 429 |
| POST `/api/v1/auth/password/reset/confirm` | `{token,password}` → `{reset:true}`，重置并撤销该账号全部会话与推送；有效登录会话仅能重置本账号 |
| GET `/api/v1/account/export` | user、完整 workspace、作业和推送 endpoint 元数据，不导出认证/订阅密钥 |
| DELETE `/api/v1/account` | `{password}` → 删除账号，级联删除会话、个人工作区、同步收据、作业、推送与票据 |

邮件 token 在数据库只存哈希、30 分钟有效、单次使用；重发作废旧链接。页面链接分别为 `/#/verify-email?token=...` 和 `/#/reset-password?token=...`，链接 origin 仅使用已验证格式的 `SERA_PUBLIC_ORIGIN`，不使用请求 Host。失效、已使用和类型错误的链接返回 `400/action_expired`。有效登录账号与链接账号不符时返回 `403/action_account_mismatch`，链接不被消费；匿名可按邮件链接完成确认，已退出或过期 Cookie 不阻止匿名恢复。重置密码不会删除账号工作区，使用新密码登录后仍可读取原数据。旧邮件文件保留历史内容，不自动重写。

验证邮件成功响应含 `sent`、兼容字段 `delivery`、`deliveryMode`、`developmentPreview`、`deliveryStatus`、`message`。`local` 的状态为 `development_only`，明确没有外部投递；`mailpit` 为 `mailpit_accepted`；`smtp` 为 `smtp_accepted`，只表示 SMTP 服务接受，不保证收件箱已送达。开发邮箱预览只在 `local` 可用，且同时核对当前会话账号、邮件收件人和数据库中有效的 verify token；不接受查询参数指定其他账号，重置邮件和重置 token 永不由此接口返回。

找回密码统一响应为 `{accepted:true,delivery,deliveryMode,developmentPreview:false,deliveryStatus:'request_accepted',message}`，无 token、无 `sent:true`，且设置 `Cache-Control:no-store`。有效格式邮箱的处理在通用 HTTP 响应发出后执行，SMTP 等待/账号限流/发送故障不进入公开响应。后台失败日志只记录稳定错误 code，不记录邮箱、token 或 SMTP 配置。申请受理不保证邮件送达，若服务在后台发送完成前停止，应等待恢复后重新申请；应用不会匿名展示开发重置邮件。

`SERA_MAIL_MODE=local` 将测试邮件写入数据库同目录的 `mail/`，本人验证邮件可通过账号页开发邮箱打开；开发者可在受保护的服务端目录读取自己的重置邮件完成恢复，目录不得映射到 Web。`mailpit` 固定投递 Compose 私网 `mailpit:1025`；`smtp` 使用 `SMTP_HOST/PORT/FROM/USERNAME/PASSWORD/TLS`，模板见 `deploy/.env.example`。TLS 只能为 starttls、ssl、none；非法值在联网前拒绝，none 仅用于回环 SMTP。starttls/ssl 显式使用系统信任链并验证服务器证书和主机名。邮件 readiness 只验证配置格式，不测试外部送达；公网邮件必须使用已授权真实 SMTP 验收收件。

客户端允许离线退出本机，若撤销请求未送达会明确说明，仍有效的服务器会话最多保留到过期。网络失败恢复未过期本机身份时标记未在线验证，401 才清理会话。删除账号密码错误不会误清当前会话。切换账号后缓存隔离，以 `user.id` 为数据 scope，不以 token 为数据库名。

## 工作区、迁移与对象同步

| 方法与路径 | 契约 |
| --- | --- |
| GET `/api/v1/workspace` | `{workspace:null}` 或 schema2 工作区 |
| PUT `/api/v1/workspace` | `{workspace,expectedRevision}` → 保存后的工作区；兼容旧客户端 |
| DELETE `/api/v1/workspace` | 清该账号工作区；应用内清空使用可撤销的版本化写入 |
| GET `/api/v1/guest-workspace` | 仅回环原生请求可读旧单工作区（需登录） |
| POST `/api/v1/workspace/import-guest` | `{workspace,expectedRevision}` → 明确导入当前账号；保留旧 guest 数据 |
| POST `/api/v1/workspace/validate-merge` | 已登录及 Cookie CSRF；`{workspace,expectedRevision}` → `{valid:true,revision}`；只读校验合并候选，不写工作区、操作或收据；版本陈旧 409、候选非法 400 |
| GET `/api/v1/sync/state` | `{workspace,entityVersions}` |
| POST `/api/v1/sync/operations` | 对象级原子、幂等操作批次 |

首次保存 expectedRevision=0。整份 PUT 使用 `BEGIN IMMEDIATE` 校验 workspace revision；操作同步独立比较对象版本，互不相关的任务修改不会因全局版本变化互相覆盖。schema1 读取/保存时迁移为 schema2，添加新字段与 singleton 初始版本，不删除旧任务。schema2 包括 tasks、entries、goals、drafts、preferences、focusRecords、history、externalBusyEntries、planningSessions、focusSession、reviews、reminderStates、platformSettings、entityVersions。完整模型见 `lib/domain/models.dart`。

设备记录合并使用上述只读预检后再提交现有原子操作同步，不调用旧整份替换导入接口。预检同时检查实体关联、规划结果及日历写入规则；客户端进入本机持久队列前再次比较预检基线。服务端最终同步仍执行版本与业务校验，预检不是写入授权或锁。本机删除不代表删除云端记录；相同 ID 的双向编辑需要明确选择，重试复用持久批次。

## 未登录 AI 与语音

以下接口仅接受 `X-Sera-Device`（设备随机生成并本机保存的 32 字节、64 位小写十六进制能力标识），不创建账户或会话，不授予账户工作区、导出、推送与同步权限。显式提交的输入或音频会发送给现有 AI／语音服务；设备工作区不会随请求整份上传。Origin 检查、接收字节上限和超时限制仍执行；账户 Cookie 不扩展设备权限。

| 方法与路径 | 契约 |
| --- | --- |
| POST `/api/v1/device/jobs` | 与账户 jobs 相同的 `{kind,input,requestId?}`；返回 202 `{job}`；真实提供方处理，不使用本地模板冒充结果 |
| GET `/api/v1/device/jobs/{id}` | 仅创建该作业的设备可以读取；其他设备 404 |
| POST `/api/v1/device/jobs/{id}/cancel` | 仅所属设备可取消；迟到结果丢弃，实际提供方结束前不释放处理槽 |
| POST `/api/v1/device/asr/tickets` | `{sampleRate:16000}` → `{ticket,expiresAt,websocketUrl}`；独立设备票据，30 秒内单次建立连接，流最长 90 秒，每帧核对有效性 |
| POST `/api/v1/device/ai/transcribe` | 与账户备用上传相同的音频 multipart；最大 60 秒、10 MiB，返回真实来源与可编辑转写 |

设备 AI 作业保留原有 `error` 简短提示，并增加可选、可空的 `errorCode`。空答案为 `ai_empty_response`，与 `ai_timeout`、`ai_connection_error`、`invalid_ai_output` 等失败分开；旧客户端继续读取 `error`。HTTP 200 但答案为空仍是失败，不使用推理正文代替答案，不自动重试模型调用。服务端诊断只记录操作种类、允许列表错误代码、处理阶段与耗时，不记录输入、模型输出、设备标识或异常正文。

设备 AI 作业只在服务进程内存保留，最多 900 秒；服务重启后不可恢复，客户端保留本机输入供显式重试。幂等键按设备隔离：同键同内容复用，改内容 409。处理槽为全局 4、设备 2、IP 4；上传转写为全局 2、设备 1。设备请求体接收另有全局 8、IP 4、总 10 秒限制；作业 64 KiB、票据及取消 4 KiB、上传 11 MiB，超过即拒绝。设备 ASR 数据库只保存票据 nonce 和设备标识的哈希、到期时间和消费状态，不保存音频或转写；WebSocket 日志对票据脱敏。

`focusSession.targetMinutes` 为可选整数（1–1440），在开始一次专注时固定保存。默认采用当前日正在进行或下一项待执行时间块的时长，并不超过任务剩余工作量；没有当天有效时间块时采用剩余工作量。任务的总估时与实际投入记录分别保留。暂停、恢复、跨日和后续修改任务／日历都不重算已有目标；界面目标和倒计时使用同一字段。旧记录缺少该字段或为 null 时正常读取，优先参考该次专注开始日的有效时间块，找不到时回退任务剩余工作量；不改变 schemaVersion 2。

`history` 仍保留最近 30 条操作，不缩减条数。新增记录可含 `format: "entity-delta-v1"`：`before` / `after` 的 `tasks`、`entries`、`goals`、`drafts`、`focusRecords`、`externalBusyEntries`、`reviews` 数组只保留该次新增、删除或修改的实体，未变化集合为空数组；`preferences` 仅在变化时同时保存前后完整值。这些对象不是完整工作区，不能直接用于替换 Workspace。`beforeOrder` 为发生变化集合的原 ID 顺序；`afterDigest` 是完整可撤销业务状态的 SHA-256，规范化时映射键排序、根实体集合按 ID 排序，检查项、阶段等内部有序列表保持原序。普通撤销先验证该摘要及仓储版本，再将反向差异合并到当前完整状态，恢复原集合顺序；不覆盖会话、专注会话、平台设置等原先不属于普通撤销范围的数据。

`完成任务` 的差异记录另含 `afterTaskEntries: {taskId: {entryId: sha256}}`，保存该任务完成后全部关联时间块的指纹（包括未变的历史时间块）。完成撤销和指定调整撤销继续执行对象范围、后续修改与时段冲突检查，保留无关的新编辑。标记已撤销时保留全部格式元数据。缺少 `format` 的旧完整记录继续读取和撤销；只有下一次正常业务保存才将可识别的完整旧记录无损转为差异格式，不在读取时写库、不改已排队操作的 body 或幂等键。未知格式、摘要、集合、ID 顺序或完成范围缺失须拒绝恢复，不能将部分记录当作完整工作区。格式仍属于 schemaVersion 2，经现有 `history/{id}` 对象版本与同步事务保存；首次压缩旧历史的成本应单独记录。

旧客户端回写已存在的差异记录时，服务端仅保留一种兼容情况：同账户、同记录 ID，来件只有 `id`、`label`、`at`、`before`、`after`、`undone`，且这些字段与当前记录完全相同，仅缺少新格式元数据。整体工作区 PUT 和 history upsert 均在版本检查通过后补回原有元数据；字段发生变化、部分元数据缺失或显式空格式均拒绝降级。此规则不跨账户或记录复制信息，也不影响正常删除历史。同步幂等摘要始终按客户端原始操作计算，补回元数据不会改变已排队 body 或同批重放结果。旧 2.0.7 客户端无法撤销差异记录（其完整快照一致性检查会拒绝），应在升级客户端后执行撤销。

操作示例：

```json
{"clientId":"android-a","batchId":"batch-1","operations":[{"id":"op-unique-1","entityType":"tasks","entityId":"task-1","expectedVersion":0,"action":"upsert","value":{"id":"task-1","title":"写课程报告","estimatedMinutes":45}}]}
```

成功返回 `{workspace,applied:[operationId],replayed:[operationId],entityVersions}`。版本键为 `tasks/task-1`；preferences/focusSession/reminderStates/platformSettings 使用 `<type>/singleton`。每批 1–5000 条且不超过 8 MiB。相同 id + 相同内容重放不会重复执行；相同 id 改内容返回冲突。删除后保留版本墓碑，旧客户端不能用 version0 复活已删除对象。一个冲突或引用校验失败会回滚整批。

409 返回 `{code:object_conflict,conflicts:[{operationId,entityType,entityId,expectedVersion,currentVersion,serverValue}],serverWorkspace,entityVersions}`。客户端保留本地待同步数据，展示冲突处理，不自动覆盖服务器；用户选择合并/保留本地后使用新操作 id 和当前对象版本提交。网络结果未知时重放原操作 id，不能另造操作绕过幂等。离线本地 workspace 与待发队列同一事务持久化；重新登录同一账号继续同步。

后端检查唯一 ID、任务/目标/日程引用、依赖循环、纯日期与时间戳、状态类型、时区与偏好。任务时间块最长24小时，外部忙碌/非任务事件允许跨日及全天多日（最长366天）。单任务细化草案 `targetTaskId` 只允许包含该原任务，展示用合成 goal 不写入真实 goals；新目标草案确认前不创建任务。

待办沿用 `tasks` 中的 `SeraTask`，不新增实体类型或 schema。`goalId`、截止日期和日历时间块均可为空；没有 `checklist` 时可直接完成整项，有清单时通过 `completedChecks` 保存子项进度，子项勾选不自动完成整项。未完成任务跨日保留，完成和恢复使用原有任务状态接口；轻量待办保存不会自动预留日历时间。已有阶段、最早开始、依赖、提醒等字段在轻量编辑中继续保留。

规划会话可选 `resultEntity: {kind: "task" | "event", id: "..."}`，表示该次输入已确认保存的任务或固定日程。旧数据缺少该字段或值为 `null` 时保持兼容；存在时 `stage` 必须为 `confirmed`。结果 ID 固定为 `planning-<kind>-<SHA256(UTF-8 session.id)>`，摘要使用完整 64 位小写十六进制。它与已有的任务细化字段 `targetTaskId` 含义不同。

规划会话另有可选 `messages` 对话列表，按显示顺序保存，继续使用 schema 2。旧会话缺少该字段或值为 `null` 时按空列表读取；客户端可以依据原始输入、补充与当前理解展示旧会话。每个消息为 `{id, role, text, understanding?}`，`id` 为会话内唯一的 1–128 字符标识，`role` 仅接受 `user` / `assistant`，`text` 最多 10000 字符。一份会话最多 100 条消息，达到上限后须明确开始新输入，不静默裁掉旧消息。只有 assistant 消息可以保存可选的 `understanding` 对象，用于重现当时的结构化建议，紧凑 JSON 的 UTF-8 编码最多 64000 字节，避免对现有 16000 JSON 字符上下文施加更严格的中文或转义字符限制；没有结构化建议时文字不得为空白。消息仅用于持久显示，不接受 `system` 等特权角色，也不会自动把整段历史作为新的 AI 请求上下文。请求仍由当前已确认的 `prompt` / `notes` / `previous` 生成，原有对象版本、幂等和账户隔离规则继续适用。

可选 `composerDraft` 保存尚未发送的输入框文字，最多 10000 字符；缺少或值为 `null` 时读取为空字符串。该字段用于返回、恢复与同步输入草稿，输入时不生成用户消息、不提交 AI 请求。只有用户明确发送后，内容才进入本轮已确认输入。

客户端 `saveTask` / `saveEntry` 的可选 `sourceSessionId` 会将实体和会话完成引用放入同次工作区保存／同批对象同步，结果确认不会先于实体保存。首次完成时后端要求结果实体同批存在；固定日程结果不能指向任务时间块。已存在的完成引用不可被旧快照改写或降级。再次保存同一来源只返回已保存结果，不再次新增或覆盖；若结果已删除，客户端明确提示开始新的输入，不复活原实体。后续正常删除可保留完成引用作为记录，清除规划记录仍可移除会话。账号隔离、对象版本和批次幂等规则继续适用。

## 持久 AI 作业

POST `/api/v1/jobs` 请求 `{kind:plan,input:{title,deadline,dailyBudget,notes,prompt},requestId?}` → 202 `{job}`。GET `/api/v1/jobs/{id}` 轮询；POST `/api/v1/jobs/{id}/cancel` 取消。状态 queued/running/succeeded/failed/canceled；成功 `job.result` 直接为 `{source:siliconflow,model,tasks:[{title,notes,estimatedMinutes,checklist}]}`。每账号最多5个排队/运行作业；requestId（或 Idempotency-Key）重复相同输入返回同一作业，不同输入409。

每日预算是用户的投入目标与偏好。客户端先按 `min(本次投入, 个人偏好)` 排期；仅增加每日投入即可完整排入时，复用同一次模型结果计算有明确上限的候选草案，不再调用模型。草案可选字段 `originalDailyBudget`（15–480）与 `suggestedDailyBudget`（大于原目标，最多1440）必须成对存在，`budgetOverrideConfirmed` 默认 false。未确认的候选可以按该建议上限编辑和重新检查，但不会因此获得确认，也不能提交为正式安排；用户明确确认后，提交才可使用本份草案的建议预算。确认只作用于本份计划，恢复该计划时保留确认状态，不修改个人偏好。

如果实际时段无法容纳全部任务，客户端保留完整任务、原估时和阶段窗口，仅为能按原顺序完整安排的任务前缀保留时间块，其他任务 `entry=null`。草案可选布尔字段 `capacityLimited`、`capacityConfirmed` 缺省 false；显式 null 或其他类型无效，confirmed=true 必须 limited=true。有容量提示且仍有活跃待安排任务时，未经确认不得提交。确认后以同一事务保存全部任务及真实时间块；全待安排也可保存，结果指向正式目标清单。重新检查出现新增待安排任务或待安排工作量/窗口/依赖变化时撤销旧确认，单纯修改备注不增加确认步骤。旧草案缺少字段仍正常读取，工作区继续使用 schema 2。

所有实际时间块仍校验重叠、可用工作日、工作/休息时段、缓冲、阶段和任务截止及依赖。容量确认仅允许保留未排期任务，不允许伪造无冲突的安排、缩减估时或自动延长截止。无有效模型结果、非法阶段等真实错误继续进入错误恢复流程。

长期目标使用同一接口，另支持可选 `referenceNow`（带偏移 ISO 时间）和 `timeZone`。缺少参考时刻时，只在首次模型执行时注入服务器当前时刻，不把动态时刻写入入队规范化输入，以保持恢复请求幂等。模型可返回最多 12 个 `phases: [{id,title,start,end,outcome}]` 及最多 96 项任务；带阶段的任务通过 `phaseId` 引用阶段。服务器校验阶段顺序、起止、目标截止及引用后，给每项任务追加 `phase`、`notBefore`、`deadline`。任务时长为 5–240 分钟的 5 分钟倍数，优先符合每日投入目标，但单项超过该目标本身不构成格式错误；本地排期器再判断是否需要上述有限增加投入的确认。计划不再受原总时长 1440 分钟上限限制。旧版不带阶段的四字段任务仍兼容。模型规划阶段和具体内容，本地排期器在阶段窗口内查找实际时间块，草案确认后保存任务的阶段与最早开始时间。

队列和结果保存在 SQLite，worker 通过租约领取，进程重启可恢复未完成作业。取消后的结果不会覆盖 canceled；已向云端发出的请求无法保证供应商停止计费。旧 POST `/api/v1/ai/plan` 保留兼容。在线模型负责语义理解和拆解，规则引擎负责工作日、时间窗、预算、休息、缓冲、任务依赖与忙碌冲突校验；不可行时返回明确原因。

助手前置理解也通过同一持久作业调用已配置的 SiliconFlow 在线模型：

```json
{
  "kind": "understand",
  "requestId": "account-scoped-unique-id",
  "input": {
    "prompt": "明天不是截止日，我只是想明晚七点和同学聊一下课程目标，大约半小时。",
    "referenceNow": "2026-10-31T16:00:00+08:00",
    "timeZone": "Asia/Hong_Kong",
    "dailyBudget": 90,
    "notes": "",
    "previous": null
  }
}
```

`prompt/referenceNow/timeZone/dailyBudget` 必填；输入时刻必须包含时区偏移，以当前界面时区解释相对日期。`previous` 可携带上轮理解字段与用户补充，最多 16000 JSON 字符；原始输入与补充各最多10000字。成功 `job.result` 为：

```json
{
  "intent": "event",
  "title": "与同学讨论课程目标",
  "summary": "明晚七点讨论半小时，未设置目标截止。",
  "outcome": "沟通课程目标",
  "deadline": null,
  "deadlineIsDateOnly": false,
  "dailyBudget": 90,
  "estimatedMinutes": 30,
  "start": "2026-11-01T19:00:00+08:00",
  "end": "2026-11-01T19:30:00+08:00",
  "questions": [],
  "source": "siliconflow",
  "model": "实际模型名称"
}
```

此例仅说明格式，不是固定模板或真实供应商验收结论。`intent` 为 goal/task/event/other，由模型理解全文、否定和修改。模型默认 `questions: []`，只有核心信息仍不足以推进或存在实质矛盾时才提出一个必要问题；结构允许最多两个以兼容历史输出。`null` 本身不触发追问。不明确的截止或时段保留 null，后端不补“7天后15点”。只有纯日期截止时，模型返回该时区23:59并标记 `deadlineIsDateOnly=true`。每日投入15–480分钟，单任务估时5–480分钟，可为null。模型只提出建议，不直接创建或修改目标、任务、事件；需用户核对与确认。格式、有效日期和时长边界由代码校验；模型失败或输出不合法时作业明确 failed，不静默回退关键词分类或伪造成功。

需要当年考试、节假日等公共事实时，GLM 按需选择 `search_public_web` 和 `read_public_page`。当前运行时使用严格 JSON 操作协议 `{operation,query,url,result}` 适配提供方；模型选择操作，应用真实执行搜索和读取，最终 `finish.result` 校验为原 11 字段后才返回 API。内部命令不暴露成新增业务字段，不做关键词路由。工具内容只作为不可信事实材料，核对官方原文后使用，不能把网页文字当作系统指令。普通理解仍可只用一次模型请求；有查询时最多四次模型响应，最后一轮必须完成，单操作协议最多实际执行三次网页工具，查询总时限 60 秒，不自动重试付费模型请求。服务器可追加 `references: [{url,title,retrievedAt}]` 与 `research`（实际调用数、耗时、核实状态及错误码）。只有成功读取的页面才进入 references；`pages_read` 表示实际读取过原文，不代表服务器已证明模型语义判断正确。查询失败或资料未发布时不能宣称核实，也不应把可查公共日期直接转成用户必须回答的问题。

## Web Push 与日历

GET `/api/v1/push/config` → `{publicKey,enabled}`；POST `/api/v1/push/subscriptions` 保存 `{endpoint,keys:{p256dh,auth}}`；DELETE 同路径传 `{endpoint}`。仅接受可信推送厂商 HTTPS endpoint，避免任意 URL 代理。POST `/api/v1/push/test` 注册一条短期测试投递，实际发送由 worker 执行，202 不代表浏览器已收到。

worker 保存提醒、投递前再次检查账号工作区版本、任务未完成/取消、通知偏好和有效期。跟进为结束后5分钟，默认稍后10分钟。payload 包括 `id,reminderId,entryId,taskId,title,body,route,scope,generation,scheduledAt,fireAt,expiresAt,quietStart,quietEnd,timeZone`；scope=userId，generation=workspace revision（测试推送0）。提醒应答 key 为 `entryId:start`/`entryId:followup`，值 `{status:ack|snoozed,at,scheduledAt,snoozeUntil?}`；只有 scheduledAt 等于本次原始提醒时间时应用，改期不会受旧应答影响。

Service Worker 展示前带 Cookie GET `/api/v1/push/validate?id=...&generation=...` 验证投递、scope、有效期与当前版本。离线时无法验证则不显示，避免旧账号/旧安排通知。发送后无法从推送网络撤回数据包；显示校验尽量缩小在途竞态。推送依赖浏览器权限、HTTPS/localhost、安全上下文和外部推送网络，不保证准时送达。

POST `/api/v1/calendar/ics/preview` 请求 JSON `{content,start,end,timeZone}`，返回 `{entries,warnings,fingerprint}`；仅预览，不自动导入。支持时区、全天、跨日、DAILY/WEEKLY/MONTHLY/YEARLY RRULE、EXDATE/RDATE、单次 RECURRENCE-ID 改期/取消，展开窗口最多366天、2MiB、2000次；拒绝秒/分/小时级重复和 RANGE=THISANDFUTURE，避免无界展开。确认导入后生成 externalBusyEntries，刷新排期约束。

## 实时语音与上传备用路径

POST `/api/v1/asr/tickets` `{sampleRate:16000}` → `{ticket,expiresAt,websocketUrl}`。票据绑定用户和仍有效的会话，HMAC签名、2分钟有效、单次使用。连接 `websocketUrl?ticket=...`，第一条必须为：

```json
{"type":"start","sampleRate":16000,"format":"s16le","channels":1}
```

之后二进制传 PCM16 小端、16kHz、单声道；建议每100ms3200字节，单帧上限32000字节。返回 `status:listening`，`partial` 和 `final` 的 text 均为整段当前转写（覆盖显示）。发送 `{type:finish}` 获取 final，或 `{type:cancel}` 真实结束流。服务限制每账号1路、全局2路、音频60秒、墙钟90秒、空闲15秒；登出/注销使当前流后续帧失效。独立 CPU sherpa-onnx 服务不向云端发送流式音频，访问日志关闭以保护查询票据。

备用 POST `/api/v1/ai/transcribe` 为鉴权 multipart，字段 file，支持真实 WAV/WebM，最多10MiB、0.1–60秒。服务依据 WAV 结构/帧或 ffprobe 数据包校验真实时长，不能相信客户端 durationMilliseconds。WebM 必须有 ffprobe（`FFPROBE_PATH` 可指定），只有一个音频流并为 Opus/Vorbis；不支持时返回错误。此备用路径调用云端 SenseVoice，取消 HTTP 不保证已发出的云端请求停止计费。识别文字可先编辑，再用于创建目标。

本地模型下载会校验固定官方归档 SHA256，加载时复核官方量化组合的完整文件清单（int8 encoder/joiner、float decoder）；缺失/损坏模型不能启动成功。真实性能和固定音频输出见 `docs/LOCAL_ASR.md` 与 `docs/qa/local-asr-benchmark.json`。

## 健康、部署与测试

`GET /health` 与 `/health/live` 报告 API 存活及 schema2；`GET /health/ready` 分别检查数据库、worker 心跳（150秒内）、实际 ASR health/已加载模型、邮件配置与 AI 配置，缺组件503。邮件检查仅确认配置，真实收件需发送测试验收；API活着不代表全部后台能力可用。Compose+Caddy、SMTP/Mailpit、模型卷、备份说明见 `deploy/README.md`。

默认只监听回环。Origin 严格允许本机同源、明确的开发4180/4181和 `SERA_PUBLIC_ORIGIN`，外来网页在调用付费服务之前403；没有通配星号 CORS。原生无 Origin 使用 Bearer。反向代理只信任 `SERA_TRUSTED_PROXIES`，Compose 中 API 端口仅映射回环且由私网 Caddy 代理；不要将信任所有代理的 API 裸露公网。

```powershell
Push-Location backend
.venv/Scripts/python.exe -m unittest discover -v
Pop-Location
flutter test test/auth_repository_test.dart
```

测试使用临时 SQLite、虚构账号和云供应商 stub，不污染真实账号或反复计费。本地 ASR 集成直接加载已校验模型，包含 partial/final/取消、票据重放、同账号并发拒绝、不同账号公平双路与登出后中止。没有模型时该推理集成会显式跳过，先运行下载脚本再验收。公开服务仍需配置自己的域名、TLS、SMTP、备份恢复、配额及运行监控；当前交付不替用户注册域名或发布公网。


## v2最终排期校验与手动时段

正式PUT与对象同步在同一SQLite事务中比较前后差异：新增/改期的未来任务块必须满足不重叠、任务dueAt或dueDate时区截止、依赖先后、未来分段总量（remainingMinutes>=0取remaining，否则estimated）、splittable与多段最短块约束。草案从draft确认成committed时，相关正式块另按当前工作日/时窗/休息/预算/缓冲检查，即使块ID和时间未变也复核。

用户明确指定手动时段可位于规划偏好之外；自动规划遵守偏好。固定/外部会议可以重叠并制造真实冲突，导入新忙碌不反向拒绝已有安排。纯标题/状态/偏好修改及保留历史完成块不会被旧冲突阻断。显式import-guest只做结构校验以保留旧数据，后续新增/改期仍受新规则约束。任一新块失败回滚整批，不留下部分目标/任务。

推送订阅额外校验真实P256公钥点和16字节auth密钥，保存时绑定当前会话摘要；退出仅移除该会话设备订阅，其他设备保留；密码重置移除该账号全部订阅，过期会话的订阅在worker投递前移除且不发送，重新登录后由客户端重绑已有浏览器订阅。未注册订阅请求测试返回409，不能返回假入队。测试payload使用kind:test/generation0，必须命中服务端实际未过期test记录，SW仍强制验证账号；一般提醒不能借generation0绕过快照检查。关闭通知后重新开启会恢复尚未发送的有效提醒，不重发已经sent的记录。


全天事件可携带成对startDate/endDate纯日期（结束日不含在内）。服务端新排期按工作区显示时区将该日期范围展开为午夜忙碌；旧全天数据按entry.timeZone恢复日期再展开。任务dueDate仍使用任务自身timeZone截止，和显示区偏好分开，避免换区把日期变成半天或提前截止。

Web Push使用userVisibleOnly=true。SERA在会话失效/旧账号/旧安排/无法在线验证时不显示任务内容，但某些浏览器可能按自身策略显示通用“站点在后台更新”提示；不能保证操作系统完全没有通知。背景消息需要可达推送厂商服务，页面关闭与完全退出浏览器是不同验收场景。依据：[Chromium Service Worker安全FAQ](https://www.chromium.org/Home/chromium-security/security-faq/service-worker-security-faq/)、[web.dev订阅说明](https://web.dev/articles/push-notifications-subscribing-a-user)、[Microsoft Edge后台通知说明](https://blogs.windows.com/msedgedev/2020/11/16/improving-notifications-badging-microsoft-edge/)。


跨标签账号边界：携带X-CSRF-Token的Cookie API读取同样验证该值与当前Cookie是否一致，旧标签A在另一标签登录B后请求workspace将收到401 account_changed，不能把B数据写入A缓存。SW验证请求没有CSRF，依靠返回scope与payload账号比对。AuthRepository固定调用时Bearer/CSRF并校验发送/响应epoch；旧请求不会改用新账号凭据，迟到结果被丢弃。只有注册/登录设置Cookie；me、退出、注销、重置不在响应改删Cookie，以免旧响应覆盖更晚的新登录。退出的有效性以服务端会话撤销和客户端signed-out标记为准。

同一浏览器、同一站点的多个标签页共享一个当前Cookie账号。Web使用`BroadcastChannel('sera-account')`同步显式登录、注册、退出、注销和密码重置事件；消息只有`apiBaseUrl`和`logged-in/logged-out`，不包含用户ID、邮箱、token或CSRF。接收登录事件的标签页立即废弃旧请求epoch、停止录音，再用不带旧CSRF的`auth/me`跟随当前Cookie；该路径跳过可能尚未跨renderer传播的旧signed-out标记和旧metadata，以服务端Cookie身份为准。退出事件直接清空旧内存，不使用仍可能有效的离线Cookie复活会话。账号恢复不再次广播。登录切换期间不会向平台发布临时signed-out scope；确认后直接切到新账号，防旧标签页撤销新账号推送。原生通道为空实现。浏览器若不支持BroadcastChannel，服务端CSRF读取校验仍阻止跨账号数据读取，但无法保证其他标签页立即同步界面，需要刷新。
