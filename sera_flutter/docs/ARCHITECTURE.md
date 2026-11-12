# SERA v2 架构与数据边界

采用Flutter原生Widget覆盖Android/Web，Provider+ChangeNotifier组织应用状态，go_router导航，Dio请求。保留已确认H5的设计规范、素材及55页状态；业务和平台能力通过仓储/服务接口组织，页面不直接写SQLite或调用供应商。

## 极简产品与工程准则

[仓库准则](../../AGENTS.md)适用于后续所有开发：保留今日/计划/日程与核心业务；按用户明确的课设互动要求，新增社区第四栏。移除重复操作、无引用实现和假设扩展，可靠性边界继续保留。研究结论、功能取舍和验证证据集中在[极简检查记录](MINIMAL_AUDIT_20261108.md)，不新增平行的审批或研究系统。

草案页负责展示创建/更新范围并接受一次明确确认；旧 `/10` 及其后缀链接回到对应 `/08`，保留查询参数且不创建数据。确认后复用原保存、重查、幂等和取消路径。任务编辑的可选 `section=time` 只改变同一表单的字段展示顺序与展开状态，普通入口保持完整模式；目标暂停/恢复/归档在原编辑入口，目标验收保持显式。列表完成操作共用完成及撤销实现。

公共 `SeraScaffold` 的 `body` 与 `slivers` 二选一，可传 `scrollKey` 和页面拥有的 `scrollController`。任务与目标任务使用惰性列表；查询只构建当前筛选，单次快照生成任务与首段安排索引，保留原始条目顺序，不引入跨账号缓存。视图按所需不可变字段订阅；深链接定位与完成撤销仍按稳定 ID 处理。

今日、计划与目标共用的 `SeraTodoRow` 可按需展开检查项；右侧箭头代替该行原有的目标图标，不增加第二个菜单。展开状态只保存在当前行，不写业务数据；默认不构建子项，仅展开行在惰性列表中 keep-alive。子项复用 `setCheck` 持久化，保存成功后更新计数，失败保留原值；忙碌、完成或取消状态禁用勾选，与详情一致，勾完检查项不自动完成父任务。整项完成及撤销继续使用原路径。选择 [CheckboxListTile](https://api.flutter.dev/flutter/material/CheckboxListTile-class.html) 让子项整行可点击，并用 [expanded 语义](https://api.flutter.dev/flutter/semantics/SemanticsProperties/expanded.html) 标记展开按钮；高度与箭头动画遵守减少动态效果设置，不新增依赖或数据字段。

已无正式入口的目标模板生成器移至历史测试夹具。旧 `local-template` 草案仍由通用模型和草案提交处理，用户数据及来源字段不迁移。运行包仅声明实际引用素材，完整中文字体和动态 SVG 图标保留。

## 分层

| 层 | 职责与实现 |
| --- | --- |
| UI | 任务/目标/规划/执行/账号/平台设置界面，表单、确认和异常恢复；读取Controller与真实平台结果 |
| 应用 | SeraController串行业务写入、草案确认/重查/撤销；AuthShell绑定会话与账号；PlatformCoordinator在持久化后协调平台结果 |
| 领域 | schema2模型、任务依赖与多块排期、纯日期/时间戳、预算/时段/休息/缓冲/忙闲规则 |
| 数据 | AuthRepository、系统安全会话存储/Web Cookie、Sembast账户缓存、稳定ID操作队列、Dio远端仓储 |
| 平台 | Android CalendarContract/alarms/通知/AudioRecord；Web ICS、Notification/PushManager、Service Worker、AudioWorklet |
| API | FastAPI/Uvicorn认证/Origin/CSRF、显式OpenAPI、schema/业务校验与SQLite事务；兼容v1URL，不用v1schema描述新数据 |
| 后台服务 | SQLite持久AI作业与推送worker；独立CPU sherpa-onnx票据WebSocket语音服务 |
| 运维 | 单主机Compose+Caddy、Mailpit开发profile/正式SMTP、持久数据/模型卷、在线备份及隔离恢复 |

Python入口为backend/server.py→app.create_app→Uvicorn。旧RequestHandler仅作为保留原REST验证/静态字节处理的兼容适配器，不启动第二个隐藏HTTP监听器；新增身份、对象同步、作业、推送、邮件和ICS由FastAPI路由处理。OpenAPI显式列出实际路径及schema，未知API不能退回HTML。

`workspace_validation.py` 承载纯数据校验、变更元数据与规划结果一致性规则，`workspace_store.py` 承载事务存储。FastAPI、对象同步和排期校验直接使用这些边界；`server.py` 继续重导出旧符号以兼容已有调用。HTTP 字节桥仍保留有效业务路径，公开 API、错误类型和数据库版本不变。

## 运营统计（2.2.1）

版本 **2.2.1+33** 在现有官方概览增加只读统计，保持后台七区与用户四栏。`AdminAnalytics`、`AdminController.loadAnalytics`、`GET /api/v1/admin/analytics` 使用同一账号和权限边界；区间、会话与权限变化使旧请求失效，已打开的统计在后台写入或官方发布成功后重新读取。

聚合只读取已有账号注册时间与社区公开记录，在单个 SQLite 读取事务中形成一致快照。香港日期的 7／30／90 天窗口提供注册、独立发帖评论人数、内容、评论、互斥分类及正数互动排行。点赞和报名没有事件时间，仅展示现存累计。没有新增访问埋点、统计表、迁移或图表依赖；Flutter 原生绘制配合可读数值、键盘选日与逐日表格。完整口径和限制见 [运营统计](ADMIN_ANALYTICS.md)。

## Web 管理后台（2.2.0）

版本 **2.2.0+32** 按明确需求新增 Web 后台七区：概览、内容管理、官方发布、管理员与申请、用户、操作记录、运行状态。`/#/admin/:section` 使用同一 Flutter 应用的窗口宽度，宽屏侧栏、窄屏抽屉，返回社区后恢复原手机容器。普通用户仍使用今日／计划／日程／社区四栏；管理能力集中在社区上下文，不为主界面增加搜索或统计入口。

后台采用 `AdminConsoleScreen → AdminController → AdminRepository → AuthRepository.authenticatedRequest → admin_api → AdminStore`，延用 Provider、go_router、Dio、FastAPI 和 SQLite，没有新增直接依赖或服务。官方发布与媒体上传继续复用 `CommunityComposeScreen`／`CommunityController`；管理员增改删和申请审核使用既有社区业务。发布表单离开需确认，分区间保留同一表单，切换账号时清空；独立列表保留筛选、稳定游标与失败数据，异步结果绑定账号和会话，旧弹窗精确移除，不关闭后来打开的页面。

`/api/v1/admin` 提供 9 个显式且 `no-store` 的端点。服务端每次读取和写入事务核对当前会话、官方名单和四项权限，菜单可见性不作为鉴权。全部管理员可读取公开帖子；全站评论读取及删除需 `moderateComments`，帖子删除需 `moderatePosts`；用户、审计、运行状态、权限分配与审核仅官方。用户摘要只返回脱敏身份、状态和社区计数，不读取个人工作区正文或凭据。

新增独立 `auth_account_status`、`admin_operations`、`admin_audit` 表，不变更 `users`、身份迁移版本、workspace schema 2 或原社区数据格式。停用事务撤销会话、推送订阅和语音票据，取消活动作业及待发提醒；保留工作区和已发布内容，恢复不复活旧会话。密码、手机和已有会话边界均检查停用状态。删除复用社区共享事务边界，官方发布、权限变更、审核和删除通过最小 hook 同事务记录审计；审计失败整笔回滚。操作原因与幂等收据绑定，结果未知时重试不会重复删除或另建操作。

运行状态只读取数据库、持久心跳与脱敏配置；配置检查用 `configured`／`healthy:null`，不调用供应商、发送邮件、推送或加载语音模型。架构取舍核对 [OWASP 授权建议](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)与 [Flutter 大屏指南](https://docs.flutter.dev/ui/adaptive-responsive/large-screens)，仅采用当前需求需要的授权、窗口适配和恢复边界。权限矩阵、接口、启动、演示与已执行的 27 项隔离后端验收见 [后台说明](ADMIN_CONSOLE.md)；最终构建与浏览器结果以主交付记录为准。

## 社区图片浏览（2.1.4）

多图放在同一个横向图片区内，正文接在图片区之后；圆点反映实际页数，点击进入深色全屏图览。复用 Flutter 原生 [PageView](https://api.flutter.dev/flutter/widgets/PageView-class.html) 按页构建与 PageController 保存当前张数，[InteractiveViewer](https://api.flutter.dev/flutter/widgets/InteractiveViewer-class.html) 负责全屏缩放和平移。图片始终以 contain 保持完整比例，不改原始媒体数据，不新增图片查看依赖。单图沿用同一查看能力，多图才显示圆点。

详情与图览共享媒体身份和当前页，关闭图览后回到同一张图片并保留详情输入。图览归属于当前账号、帖子与媒体集合，变更时只关闭自身路由；控制器与变换资源在退出时释放。正常详情使用既有浅色主题，仅全屏看图使用深色。手机以手势和最少控件操作，Web 补齐鼠标与键盘操作，减少动态效果遵守 SeraMotion。

实际浏览器复现鼠标缩放识别器先接受拖动后，增加仅限未缩放鼠标路径的转交：用 PageView 的 `ScrollPosition.drag` 接收位移与速度，保留框架分页吸附；触控与放大后平移继续由原识别器处理。活动 Drag 在身份／媒体失效与销毁时取消。该差异通过独立鼠标事件回归覆盖，不用触控或键盘测试替代。

## 身份与隔离

社区扩展复用当前认证传输，采用 `CommunityController → CommunityRepository → community_api → CommunityStore`。组件不直接写库或决定角色。社区表与个人工作区分离，不改变 workspace schema 2，也不自动发布个人任务数据。服务端所有者名单和逐人四权限分别校验官方发布、活动发布、帖子和评论管理；只有所有者能分配权限、审核申请。管理状态与点赞等会话标记不进入共享静态缓存，账号与会话切换清空客户端缓存并丢弃迟到结果。可选登录只携带经过白名单验证的本地社区返回路径，AuthShell 在替换工作区前捕获目的地。页面、接口与官方账号配置见[社区说明](COMMUNITY.md)。

2.1.1 补充双列图文与图片发布；2.1.3 按用户明确要求改为自然错列，锁定 `flutter_staggered_grid_view 0.7.0`，使用单滚动容器内的 `SliverMasonryGrid` 和惰性 delegate，保留稳定 key 与索引映射。图片比例和标题行数决定高度，不预先测量整份列表，也不维护自定义渲染器。纯文字卡片使用实际标题或正文首段排版大字封面，详情保留完整文字。作者移入详情标题栏，评论采用扁平头像列表，评论输入和唯一帖子点赞留在底部。该依赖只解决已确认的社区布局问题，无额外平台权限和数据格式变化。帖子分类只有日常 `daily` 与使用反馈 `feedback`；原记录默认日常，活动仍归日常。列表保留全部、官方与使用反馈筛选。`authorIsOfficial` 表达真实作者身份，`isOfficial` 表达内容发布身份；普通管理员发布官方内容时仍使用本人昵称与头像，官方所有者的个人内容与官方内容保持同一头像。下拉刷新、滚动分页和到末页后的刷新接入真实仓储；保留式刷新重新读取已浏览范围后原子替换，已到末页则读取至新末页，失败保留现有列表和游标。筛选、稳定帖子 ID、页面滚动控制器与请求归属分别保留，不用第一页覆盖全部已加载内容，也不保留已被服务器删除的旧条目。

图片选择采用精确版本 `image_picker: 1.2.4`，服务端解码采用 `Pillow==13.0.0`；其余直接依赖约束和既有技术栈不变。`community_image_picker.dart` 选择 JPG/PNG/WebP、限制单图 8 MiB、最多三张，使用 1600×1600、质量 85、`requestFullMetadata:false`；预览直接使用所选字节。Android 选择前只保存 API 地址、用户 ID、会话 ID 与操作标记，正常结束只清匹配标记，低内存重启后的 `retrieveLostData` 仅向相同账号会话提供恢复预览，不自动发布。不同账号、服务器或会话的恢复结果丢弃；Web 不调用 Android 恢复 API。依据与维护成本见[本轮审计记录](MINIMAL_AUDIT_20261108.md)。

媒体使用独立社区迁移 4 表，不改变个人工作区格式。上传为带 `Idempotency-Key` 的原始二进制，继续使用绑定会话的 Bearer/Cookie/CSRF，禁止调用方覆盖认证头。服务端真实解码、检查格式和像素、修正方向、缩小长边并去除元数据；透明图保存为 PNG。未发布图片只允许上传者读取并在 24 小时后失效，正式发布后才公开读取。发布事务按顺序绑定最多三张本人图片，正文仍必填；返回的 `media`、点赞和评论数量均以服务端结果为准。图片与发布分别幂等，上传失败保留其他成功图片，过期错误携带具体图片 ID 以便仅重传受影响项。删除帖子或注销继续由外键清理关联数据。媒体读取采用 `private, no-store`，不进入静态离线资源缓存。

AuthStore以user_id隔离工作区、作业、订阅、同步收据和票据。密码为随机盐PBKDF2-HMAC-SHA256；DB仅保存会话token摘要。Web使用HttpOnly/SameSite Cookie，写请求带绑定会话的CSRF值；me刷新恢复会话标识。Android保存Bearer到系统安全存储。用户scope只传userId给平台/SW，不向SW发送token。

同源浏览器标签页共享一个Cookie当前账号；`sera-account` BroadcastChannel仅广播API地址和登录/退出事件。接收登录事件后废弃旧内存身份与请求epoch、停止语音，以无旧CSRF的me请求重新确认身份，并跳过可能迟于广播传播的旧storage退出标记/metadata；退出事件直接清空内存，避免离线Cookie复活。恢复不广播结果，避免循环；登录恢复期间暂缓平台scope切换，完成后直接跟随新账号。原生为空通道；不支持BroadcastChannel的浏览器仍由服务端CSRF边界保护读取，但其他标签页需刷新同步界面。

AuthShell按账号创建/关闭Controller、离线仓储和平台协调器；旧账号请求不得使用新账号凭据继续写入。后台登录返回采用同一本地白名单，退出仍回到原后台门禁。切换队列在微任务中先释放旧控件焦点并提交焦点更新，再移除旧路由，避免窗口获焦时读取已脱离渲染树的控件。退出可在离线清本机会话并明确服务器撤销未确认；重置密码撤销全会话，注销FK级联删除个人服务数据。Web订阅绑定当前会话hash，退出只清本会话设备订阅，不影响另一设备。

## schema2与持久写入

Workspace保留tasks/entries/goals/drafts/preferences/focusRecords/history，并增加externalBusyEntries、planningSessions、focusSession、reviews、reminderStates、platformSettings与entityVersions。task包含状态、优先级、依赖、可拆/最短块/剩余量及dueDate（纯日期）/dueAt（时间点）。草案保存targetGoalId/targetTaskId、验证版本、日历指纹及baseTaskVersions。

页面输入不直接改共享对象。Controller校验并串行组织变更，仓储持久保存成功后才更新共享data。账号联网模式的本机缓存和待发操作批次在同一Sembast事务中保存；断网允许的编辑不会假装已经写入服务器。重开按userId恢复缓存和稳定操作ID。

远端/api/v1/sync/operations使用对象独立版本与SQLite BEGIN IMMEDIATE。版本键为tasks/id，singleton使用preferences/singleton等；一个批次全部通过才提交。相同操作ID/内容重放返回replayed，结果未知时安全重试；冲突409保留本地和远端差异供明确处理。删除墓碑保留版本，防止旧客户端复活数据。兼容整份PUT仍使用workspace revision，迁移schema1时保留原数据并初始化新字段/对象版本。

历史快照有界；撤销检查当前业务内容仍与after一致，避免覆盖后来修改。平台日历/通知失败与应用内保存分开报告，不因设备权限错误回滚已经保存的任务。

## 规划与AI

规划输入/澄清保存在PlanningSession，未确认草案不进入正式tasks/entries，也不触发系统提醒。新目标与修改已有目标/单任务使用明确目标ID，避免重复创建。确认前重查外部忙闲、对象版本与日历指纹；保留编辑，过期时展示重新检查路径。

AI以持久job形式入队，worker领取租约后调用SiliconFlow，严格校验语义任务结构；取消后的响应不能覆盖终态。供应商只提供标题/说明/估时/检查项，Dart执行真实约束排期，不把模型生成的时间当可信日历。密钥仅服务端环境/指定文件读取。已经发出的付费请求无法保证取消计费。

## 平台与提醒

Android日历与本地日程分别保持稳定ID映射；外部忙碌可以重叠并触发建议，不强行移动会议。Web提供真实ICS文件交换，复杂时区/规则可转后端有界解析；没有虚构OAuth账号双向同步。

Android提醒走系统能力；Web前台Timer与后台WebPush分别实现。远端订阅必须浏览器与服务端都成功；服务端注册失败补偿撤销浏览器订阅并保留错误。worker持久记录提醒，按多块entryId、任务状态、scheduledAt应答、时区免打扰和有效期计算。SW在页面关闭时可独立接收push，含Cookie向同源validate核对scope/generation/expiry后才显示；请求入队不等于浏览器收到，浏览器完全退出行为受系统后台策略限制。

Web构建后通过`web/generate_offline_manifest.py`列出完整公开资源及内容hash。Service Worker完整预缓存Flutter启动脚本、主程序、本地渲染资源、字体和素材，验证成功后原子启用该版本；账号API不进入离线资源缓存。构建脚本与镜像均执行清单生成，缓存版本与实际内容绑定，避免部分壳资源缓存造成断网重开白屏。

升级时先读取上一完整版本中相同路径的静态资源，用新清单的大小和 SHA-256 验证后复制到候选缓存；变化、缺失或损坏的资源才下载。所有并发写入完成后才能提交版本指针；失败时先等待写入结束再清理候选，继续使用旧版本。旧标签页仍绑定原缓存，认证 API 不参与复用。离线准备返回内部资源/字节计数用于验收，不增加用户设置。

多个 Service Worker 实例使用同源 Web Locks 串行执行资源准备、版本提交、标签页绑定与清理。每次候选具有独立名称，`sera-runtime-v5-*` 与旧 worker 清理的 `sera-shell-*` 分离；即使内容版本相同，也先核验并迁入新命名空间。旧标签页继续读取原缓存。无法使用 Web Locks 时保留离线能力，但保守保留其他完整缓存，只删除本次失败候选，避免另一线程或旧标签页丢失资源；旧 v4 缓存不由新 worker 主动清理。这一兼容路径可能占用更多存储，更新失败仍使用完整旧版本。[WorkerNavigator.locks](https://developer.mozilla.org/en-US/docs/Web/API/WorkerNavigator/locks)

## 语音

AudioRecord/AudioWorklet产生真实16kHz单声道PCM16。鉴权API发2分钟单次HMAC票据，独立ASR服务同时核对DB会话，限制每账号1路/全局2路/60秒音频。partial/final均为整段文本，取消/完成释放真实流。模型来源、权重许可和运行库许可分别记录于docs/licenses，官方量化组合（int8 encoder/joiner、float decoder）的原始字节校验后加载。云端WAV/WebM上传是明确备用路径，服务依据实际音频结构与ffprobe验证时长。

## 部署与验收边界

默认回环监听。Compose以持久SQLite WAL数据卷、只读模型卷、API/worker/ASR+Caddy组织单主机，Mailpit仅开发profile；正式外部SMTP、DNS/TLS及商店发布需要对应部署条件。/health/live与ready分开，ready检查worker、已加载模型和配置，不把进程存活当全部能力可用。在线备份用SQLite backup API，恢复先校验归档哈希/DB完整性且拒绝覆盖。

自动化和实际设备/浏览器结果分开记录。[R01–R32](FULL_DEVELOPMENT_PLAN.md)记录代码/测试/待验收边界；当前产物、设备运行和测试总数以[README](../README.md)及[极简验收记录](MINIMAL_AUDIT_20261108.md)为准，[DELIVERY_V2](DELIVERY_V2.md)保留为 2.0.0 历史基线。部署细节见[deploy/README](../deploy/README.md)，接口字段见[API](API.md)。
