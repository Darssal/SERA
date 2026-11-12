# SERA 序日 · Android + Web 全栈应用 2.2.1

当前源码 **2.2.1+33（2026-11-10）**，在 [Web 管理后台概览](http://127.0.0.1:8787/#/admin/overview)加入真实运营统计：近 7／30／90 天注册、独立发帖评论人数、发布内容与评论，配合逐日趋势、内容分类及互动排行。点击或使用键盘可查看某日数值，逐日数据和统计口径按需展开。统计只对官方开放，普通管理员保留原社区概览；不读取私人任务、日历和专注内容，不增加新的导航或图表依赖。完整定义与限制见 [运营统计说明](docs/ADMIN_ANALYTICS.md)。

桌面使用侧栏和表格，窄屏使用抽屉；普通应用继续保持今日／计划／日程／社区四栏。点赞／报名由于缺少完整事件时间，只显示全站现存累计；保留的模拟内容也计入，删除或取消会改变现存统计，不将发帖评论人数冒充访问量或日活。

后台包含概览、内容管理、官方发布、管理员与申请、用户、操作记录、运行状态七个区域。查询、分类、分页、详情、图文与活动发布复用真实服务；内容移除和账号停用／恢复需要填写原因，管理员四项权限仍由官方逐人分配。用户身份脱敏，个人任务、日历、专注与密码不会提供给后台；操作审计与业务同事务提交，停用账号撤销现有登录、推送和未完成作业，保留其数据。

使用现有“序日官方”账号，或官方授予权限的社区管理员账号登录。后台与应用共用登录，无需安装第二套服务。入口也位于社区管理的“打开 Web 管理后台”。完整页面、权限矩阵、10 个后台接口、账号配置、启动和课程演示步骤见 [后台说明](docs/ADMIN_CONSOLE.md)。管理查询集中在后台，没有向用户主界面新增搜索或管理菜单。

2.2.1 已执行静态分析无问题、Flutter **1063 通过、1 项原有可选 HTTP 测试跳过**，现有后端 **467 通过**，统计接口 **18 通过**，原后台兼容 **27 通过**，配置与交付 **25 通过**，Web 平台与真实缓存升级 **41 通过**，离线清单 **3 通过**。当前库 7／30／90 天已独立对账，发布 Web 构建成功；浏览器完成 1536／320／390px 和筛选、键盘选日、排行详情、明细检查，新增 error／warn 为 0。原始记录与交付证据见 [本轮验收](docs/ADMIN_ANALYTICS_QA_20261110.md)。本轮 Web 与源码交付位于 `.local/releases/sera-2.2.1+33/`；没有重新生成或宣称已测试 Android，上一有效签名 APK/AAB **2.2.0+32**保留在 `.local/releases/sera-2.2.0+32/`，其历史验收见 [后台验收](docs/ADMIN_CONSOLE_QA_20261109.md)。模型与私有配置另行保留，不含在源码或客户端包中。

## 2.1.4 社区与图览基线

**2.1.4+31 已更新到[社区预览](http://127.0.0.1:8787/#/community)**。多图详情改为一个左右轮播图片区和紧凑圆点；点开进入深色全屏，显示关闭与张数，支持横滑、双击缩放和放大后平移。静态分析无问题；Flutter **977 通过、1 项原有可选测试跳过**，其中社区专项 **80 通过**、图览行为 **13 通过**；Web 平台／真实资源缓存升级 **41 通过**，离线清单 **3 通过**。浏览器实际验证 320/390px、鼠标翻页与缩放、圆点、X／Esc 关闭、页码及未发送评论保留，控制台无 error/warn。release Web 和签名 APK/AAB 已构建并校验，交付目录 `.local/releases/sera-2.1.4+31/`；MuMu 安卓设备-1 未运行，本轮未安装或实测。范围与截图见[图览记录](docs/COMMUNITY.md#214-多图轮播与全屏查看2026-11-09)和[视觉对照](design-qa.md)。

**2.1.4+31（2026-11-09）社区基线**按课设互动要求新增[社区](http://127.0.0.1:8787/#/community)第四栏；今日、计划、日程保留原职责。社区采用自然错列的双列图文瀑布流，纯文字自动形成大字封面，详情使用作者栏和扁平评论列表，图片支持横滑、页数圆点和深色全屏缩放；支持日常动态、使用反馈、最多三张图片、官方活动、点赞、评论和活动参与。下拉刷新、上拉分页与触底更新使用真实后端数据，不自动公开个人任务和日历。

按追加反馈，社区照片封面采用各自原始宽高比，横图较矮、竖图较高，两列独立接续；仅无效尺寸及极端长条图保留宽松保护。已补充横图封面的模拟日常《晚霞刚好，不赶时间》，现有模拟帖共 16 条，素材和模拟身份明确标注。实际 320/390px 对照为 `natural-covers-final-320.jpg`／`natural-covers-final-390.jpg`，详情横滑与全屏能力保留。

官方可用准确用户名或邮箱添加已有用户为管理员，逐人设置发布官方动态、发布活动、管理帖子、管理评论四项权限，并审核普通用户申请。只有服务端配置的官方所有者能分配权限；普通管理员不能升权，撤回权限后后端立即拒绝相应操作。申请／管理集中在一个页面。管理员被移除后可重新申请，旧审批重试不能恢复已撤回的权限。

本机新建的“序日官方”账号凭据只保存在 `.local/community-private/official-account.json`，所有者配置为同目录 `official.env`。`official@sera.example` 是课程示例地址，没有真实邮箱且未验证；以用户名登录。运行、权限、接口与课程演示见[社区说明](docs/COMMUNITY.md)。发布、评论和申请失败保留输入；未登录时可阅读，登录后返回原社区页面。社区写入需联网，不伪装离线发布成功。

图片选择使用系统照片选择器，支持 JPEG、PNG 和静态 WebP。后端校正方向、移除元数据、等比缩小并保留透明背景；未发布图片只限本人读取，失败可逐张重试。详情保持图片比例。无头像用户以稳定颜色和昵称首字表示，官方作者使用品牌头像。未增加视频、搜索、榜单、私信或头像上传，避免偏离日常分享和反馈的实际需求。

2.1.3 已更新本机[社区预览](http://127.0.0.1:8787/#/community)。Web 产物为 `.local/web-community-masonry-20261109`，交付目录为 `.local/releases/sera-2.1.3+30/`；新增 12 条带模拟身份的帖子、3 张 AI 示意图及 18 条自然评论，均通过真实 API 保存。静态分析无问题；Flutter **963 通过、1 项原有可选测试跳过**，Web 平台与真实构建缓存升级 **41 通过**、离线清单 **3 通过**。浏览器检查 320/390px、图片与文字封面详情、评论输入、点赞恢复和返回。Android 签名 APK/AAB 构建完成；MuMu 安卓设备-1 当前未连接，本轮没有设备安装和系统能力实测。变更、引用和证据见[本轮记录](docs/COMMUNITY.md#213-瀑布流大字封面与评论2026-11-09)及[视觉对照](design-qa.md)。

2.1.1 已更新本机[社区预览](http://127.0.0.1:8787/#/community)，Web 产物为 `.local/web-community-feedback-20261109`，交付目录为 `.local/releases/sera-2.1.1+28/`。静态分析无问题；Flutter **947 通过、1 项可选测试跳过**，后端 **465 通过、2 项真实 ASR 推理跳过**；平台／真实构建缓存升级 **41 通过**。签名 APK/AAB 构建及校验完成。浏览器已用真实文件选择器完成两图发布、刷新、点赞评论、分类与分页，并检查 320/390px。MuMu 安卓设备-1 启动后自行退出、ADB 拒绝连接，未完成该设备安装或系统相册实测。完整范围、回退副本和日志见[图文社区验证](docs/COMMUNITY.md#211-图文社区验证2026-11-09)。

2.1.0 回归基线：静态分析无问题，Flutter 全量 922 通过、1 项可选测试跳过；后端 441 通过、2 项真实 ASR 推理未执行。浏览器已实际检查官方登录返回、刷新恢复、报名取消、权限编辑、表单与离开保护。旧 APK/AAB 保存在 `.local/releases/sera-2.1.0+27/`，对应 Web 产物为 `.local/web-community-20261109`；后续图文功能以[社区说明](docs/COMMUNITY.md)的 2.1.1 验证记录为准。

## 2.0.24 历史基线

上一版源码及 Web 版本为 **2.0.24+26（2026-11-09）**：[今日](http://127.0.0.1:8787/#/04)、[计划](http://127.0.0.1:8787/#/17?filter=todo)。带检查项的任务可点击右侧箭头向下展开，直接勾选子项并更新数量；今日、计划、目标任务清单行为一致。点击标题仍进入详情，没有子项的任务不显示空展开入口。默认收起，保存后保持展开，收起不取消已保存的勾选；全部子项完成不会自动完成父任务。已完成或取消任务只读，保存期间禁用写入，失败保留原值可重试。

本轮静态分析无问题；最终全量 Flutter **893 通过、1 项原有可选测试跳过、0 失败**，包含新增 13 项子项交互与滚动测试。覆盖真实持久化、失败重试、详情双向同步、重载、完成撤销、320px 大字体、减少动态效果、展开行离屏恢复及 300 项远处任务定位。减少动态效果时直接切换展开内容，避免零时长高度动画的布局异常。执行记录为 `.local/todo-inline-analyze-final-20261109.log`、`.local/todo-inline-full-tests-final-20261109.log`、`.local/todo-inline-focused-final-20261109.log`。

本版沿用现有 `setCheck` 和完成撤销路径，不增加业务字段、依赖或新页面；实现依据与取舍见 [极简记录](docs/MINIMAL_AUDIT_20261108.md#2024-列表内展开子项2026-11-09)。本次更新 Web 与 Flutter 源码，Android APK/AAB 仍为下面记录的 2.0.22+24。

Web 发布文件在 `.local/web-inline-checklist-20261109`，8787 静态目录已更新；2.0.23 回退副本在 `.local/web-before-inline-checklist-2023`。`main.dart.js` SHA-256 为 `9D1E25554A833BC5E533F2B8D809280A3F7FA878DE305B63689ADD1B41672541`，离线清单版本 `be928258f6ac`，构建日志 `.local/todo-inline-web-build-final-20261109.log`。浏览器截图目录为 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-inline-checklist/`。

浏览器实际走通“今日 → 展开第一项任务 → 收起 → 再展开 → 对应任务详情 → 返回”，子项内容与详情一致，返回后保持展开，控制台无 error/warn。截图 `today-expanded.jpg` 为本轮实际发布页面。浏览器没有勾选或更改已有任务；保存、重载、失败与完成撤销由隔离仓储测试验证。未启动额外测试服务。

## 2.0.23 日程界面基线

2.0.23 历史版本为 **2.0.23+25（2026-11-09）**：[月视图](http://127.0.0.1:8787/#/14)。日程摘要由彩色卡片改为平面列表：标题下显示完整时间和实际地点，小图标区分任务/日程，保留整行点击，移除重复的时长及“目标任务”泛标签。今日下一项日程和工作周展开列表复用同一组件。静态分析无问题，相关 Flutter 回归 40 项通过，覆盖 55 路由的 320/360/390/430px、大字体、日历选择及详情跳转。Web 构建与截图记录见本机 `.local/calendar-agenda-*-20261109.log` 和 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-calendar-agenda/`。该次未重新生成 Android 包，下面的 APK/AAB 为 2.0.22+24。

本版 Web 产物为 `.local/web-calendar-agenda-20261109`，8787 预览目录已切换为相同构建；2.0.22 回退副本为 `.local/web-before-calendar-agenda-2022`。主程序 SHA-256：`164CBB49A6D1860F898F534227AF3E4E525CD41B33F00F70D349C6052743543A`，离线清单版本 `f439ce313d03`。仅替换公开静态资源，现有 API、worker、ASR 及账户数据库保持运行。

浏览器实际验证“月视图 → 11月10日 → 回顾并记下下一步 → 对应任务详情 → 返回月视图”，选中日期与原任务时间保留，控制台无 error/warn。对照截图为 `month-before.jpg`、`month-after.jpg`。没有保存业务修改；本轮仅调整共享组件样式，没有新增依赖或性能提升声明。

## 2.0.22 工程基线

上轮源码与发布版本为 **2.0.22+24（2026-11-08）**，主要入口为 [今日](http://127.0.0.1:8787/#/04)、[计划](http://127.0.0.1:8787/#/17?filter=todo)、[日程](http://127.0.0.1:8787/#/12)。该轮按已确认的极简计划落地；后续开发共同遵守根目录 [AGENTS.md](../AGENTS.md)。

- AI 草案直接展示创建/更新范围、任务与安排，用户一次明确确认后保存。旧 `/10` 链接回到对应草案，保留参数，不会自动保存；过期、冲突、取消、幂等与账号归属继续校验。
- “修改时间”沿用同一任务编辑器并优先展示时间字段；其他信息在原表单展开，输入保留。今日、计划与目标任务清单复用完成/撤销；目标暂停、恢复、归档归入已有编辑入口，目标完成仍需验收。
- 任务查询只计算当前筛选并一次建立首段安排索引；任务和目标任务采用惰性列表及局部订阅，保留稳定 ID 定位和返回位置。删除无引用直接依赖与运行素材声明，旧模板生成器移入历史测试夹具，已保存草案仍可编辑确认。
- Web 升级复用路径、大小和 SHA-256 匹配的缓存资源，候选完整后才切换；跨 worker 使用 Web Locks 协调，兼容旧标签页与无锁浏览器。后端纯校验和事务存储从 HTTP 兼容处理器提取，公开接口及持久格式不变。

本版验证：静态分析无问题；全量 Flutter **880 通过、1 项原有可选 HTTP 测试跳过、0 失败**；后端 **411 通过**；Web 平台 Node **41 通过**，含实际构建资源的五次升级测试；离线清单 Python **3 通过**。自动化覆盖 55 路由的 320/360/390/430px、大字体、键盘与减少动态效果。浏览器实际验证已有任务时间输入、展开/收起、放弃修改、目标编辑状态菜单及三栏返回；控制台无 error/warn，未保存业务修改或发起录音/供应商请求。

性能记录：100/300/1000 项任务首屏均构建约 8 行；JIT 查询与 widget harness 原始结果在 `.local/minimal-engineering-list-benchmark.json`。本次 Web 清单 74 文件、41,781,504 字节；升级复用 67 文件 / 34,767,490 字节，下载 7 文件 / 7,014,014 字节，未变中文字体与渲染资源无需重下。`.local/minimal-engineering-cache-benchmark.json` 的耗时和内存来自 Node 内存缓存测试环境，不代表浏览器启动或 Android profile 性能。具体测量、研究、取舍和待测边界见 [本轮验收记录](docs/MINIMAL_AUDIT_20261108.md)。

发布 Web 位于 `.local/web-minimal-engineering-20261108`，8787 服务目录已更新为同 SHA 构建；2.0.21 回退副本为 `.local/web-before-minimal-engineering-2021`。`main.dart.js` SHA-256：`8457AFE488B64DF8192DC560FDB436D129481B9CDB1345D05073BF24F30BC1FC`，离线清单版本 `18246b0e2029`。现有 API/worker/ASR 和账户数据库未重启或替换。

Android APK 与 AAB 已完成 release 构建，位于 `.local/releases/sera-2.0.22+24/`，文件为 `sera-2.0.22+24.apk`、`sera-2.0.22+24.aab`，校验见同目录 `SHA256.json`。APK 签名验证通过（v2），包名 `com.sera.sera_flutter`，版本 `2.0.22` / `24`。包连接本机 `http://127.0.0.1:8787`，MuMu 运行后需映射 8787/8790 端口。**MuMu 安卓设备-1 当前未运行，本版尚未安装或完成系统日历、通知和录音设备实测**，设备启动与滚动/内存 profile 单独待测。没有额外启动模拟器或常驻测试环境。

执行日志在 `.local/minimal-engineering-{analyze,full-tests-final,backend-tests,platform-final,manifest-tests,web-build,apk-build-final,aab-build,apk-signature}.log`；实际浏览器截图在 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-minimal-engineering/`。首次 APK 的 `--no-pub` 构建保留失败日志；正常发布构建重新生成注册表后成功，不应在测试生成物之后省略该步骤。

## 历史版本记录（2.0.21 及以前）

2.0.21 历史源码版本为 **2.0.21+23（2026-11-08）**；以下测试与构建数字保留为回归参考，不代表当前版本。

2.0.21 整理任务、日程、规划、账户、备份、语音与提醒的用户文案：日程详情删除重复的锁定机制说明；编辑页改为“固定这个时间 / 自动安排不会改动这个时间”。“时间块、估时、工作空间、会话、调度精度”等改为具体安排、预计用时、安排与记录、登录状态及提醒时间；内部 ID 不再作为同步失败事项的标题。数据格式仅在备份内容区说明，查看/复制与实际保存文件继续分清；确认范围、覆盖后果、不可撤销提醒和录音上传说明保留。没有改变现有数据、业务规则或接口。

2.0.21 验证：`flutter analyze --no-pub` 无问题，全量 Flutter 回归 **869 通过、1 项原有可选 HTTP 测试跳过、0 失败**，发布 Web 构建成功。既有测试适配新文案后继续验证完成撤销、草案、账号、同步冲突选择与实际数据；覆盖 55 路由和 320/360/390/430px。浏览器在默认移动预览中检查日程编辑、固定时间开关、离开未保存页面的确认、隐私入口及返回；页面正常渲染，控制台无 error/warn，没有保存测试日程或改动既有记录。截图在 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-plain-language/`。执行记录为 `.local/plain-language-analyze.log`、`.local/plain-language-full-tests-final.log`、`.local/plain-language-web-build.log`。本版未生成新 APK/AAB 或运行 Android 设备测试。

2.0.20 按同一极简标准检查原 55 个页面/状态和新增账户页：移除日程详情的“添加会前准备任务”、完成与确认结果的任意首任务推荐、固定入门模板和欢迎页示例、生成过程的静态步骤、提醒页重复返回、设置页重复账户/日历/通知入口。目标继续从在线 AI 创建；旧模板草案与预填链接仍能恢复、编辑和提交。推送测试归入已有诊断区域；普通邮箱验证隐藏开发工具，验证完成后隐藏刷新按钮。保留真实状态、编辑、保存、完成、撤销及失败恢复，不改动既有用户数据。逐组记录见 [极简界面检查](docs/MINIMAL_AUDIT_20261108.md)。

2.0.20 验证记录：`flutter analyze --no-pub` 无问题；全量 Flutter 测试 **869 通过，1 项原有可选 HTTP 测试跳过，0 失败**；发布 Web 构建成功。自动化覆盖原 55 路由的 320/360/390/430px，并检查旧草案、真实仓储变更、完成撤销、页面返回、邮件验证与开发工具条件。浏览器实查 390px 下的账户、隐私、欢迎、今日语音弹层及返回操作，控制台无 error/warn。窄屏覆盖以自动化结果为准；浏览器视口覆盖请求未改变此标签页的实际 390px 尺寸，不计为额外 320px 实查。未提交业务修改或发起供应商请求。2.0.20 没有新建 APK/AAB 或启动模拟器，Android 安装、录音与系统能力不作为该版的新增验收结论。

保留 **今日 / 计划 / 日程** 三栏。今日提供录入、当天任务、专注续接与最多一条即将发生的固定日程，账户头像仅保留在今日。计划页移除搜索、更多菜单及重复录入卡，仅保留任务/目标切换、未完成/已完成和列表；目标视图保留创建及真实进度。今日菜单移除全局搜索，保留回顾和提醒。日程移除重复安排计数，空态压缩成一行；只有所选日期存在未锁定的未完成任务安排时才显示调整按钮。目标与 AI 空态也去掉大图标占位。日/周回顾移除重复投入图表及任意首个目标的进度和跳转，保留真实完成/专注汇总、任务列表、复盘输入和保存。

今日“交给 AI 安排”默认打开紧凑的“按住说话”弹层。按住录音，松开完成流式识别；有结果后出现可编辑校对框，确认才调用在线 AI。也支持点按或键盘开始/结束，文字输入作为次选；文字模式的主操作仍是“让 AI 安排”，手动添加任务为次操作。临时识别不覆盖已确认输入，取消与切页释放麦克风，账号变化忽略迟到结果；失败后才提供显式云端备用。无日期任务进入计划，不强行占用今日。原有编辑、草案确认、持久化、账户隔离、错误处理与撤销继续使用。

路由兼容：`/04` 为今日；`/17`、`/20` 分别是计划的任务/目标视图，均选中计划导航，保留历史筛选与对象定位参数；`/12`–`/14` 为日程。`/37` 与已加载的 `/49` 使用今日组件并支持保存后返回原页。AI/语音保留 `from=today/tasks/goals` 来源，成功后回到原业务页面。

2.0.18 回归基线：`flutter analyze --no-pub` 无问题；全量 Flutter 测试 **861 通过，1 项原有可选 HTTP 测试跳过，0 失败**；发布 Web 构建成功。自动化覆盖 55 路由的 320/360/390/430px、1.5 倍字体、键盘、输入保留、真实仓储变更、页面返回和完成撤销；语音专项 23 项测试使用 MethodChannel 与模拟 WebSocket，覆盖长按松开、权限/原生启动未完成时取消、切页、账号切换、销毁、重复操作和键盘录入。浏览器实查默认语音/文字切换、计划去冗余、日程空态与有任务时的条件操作、工作周与回顾页，以及 320/390px 和桌面 1024px 居中布局，控制台无 error/warn。浏览器验证未提交业务修改、触发麦克风或供应商请求。2.0.18/2.0.19 均没有生成新版 APK/AAB，Android 安装、实机录音和系统能力不作为这两版的新增验收结论。

2.0.21 历史构建输出在 `.local/web-plain-language-20261108`。现有服务沿用 `.local/web-simplicity-release-20261108`，内容已替换为本轮同 SHA 构建，2.0.20 保存在 `.local/web-before-plain-language-2020`；API/worker/ASR 进程与账户数据库未重启或替换。`main.dart.js` SHA-256：`36A53B86A626BBF04700F3BB57710E55CC0F65359CADF8B5CF9DB17A54635A04`；离线清单 86 文件、约 39.9 MiB，版本 `692c6286c594`。2.0.20 日志继续保留在 `.local/flow-minimal-analyze.log`、`.local/flow-minimal-full-tests-final.log`、`.local/flow-minimal-web-build.log`，截图位于 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-flow-minimal/`。2.0.18 回归日志与语音专项继续保留在 `.local/minimal-voice-*.log`、`.local/voice-hold-tests.log`，对应截图在 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-voice-minimal/`。

可选登录与本机记录行为见 [2.0.9 可选登录验收](docs/DELIVERY_OPTIONAL_LOGIN_20261108.md)；历史完整测试边界见 [2.0.8 核心测试](docs/DELIVERY_CORE_TEST_20261101.md)。历史构建与测试记录不代表当前 Android 包版本。

以已确认的55页H5原型为布局、操作和素材基准，并按后续极简反馈调整，用Flutter原生Widget实现任务、目标、日程、AI规划、草案编辑确认、重排、专注、回顾与设置。搜索旧路由仅保留兼容，不在主界面提供入口。v2已接入真实账号、按用户隔离的持久数据、离线队列、平台日历/通知、实时语音和可部署后端。页面未使用整张设计截图或WebView承载。

## 技术方案

| 层 | 实际选型与用途 |
| --- | --- |
| 客户端 | Flutter 3.47.2 stable / Dart 3.13.2；Android + Web共用界面与领域模型 |
| 状态与路由 | Provider + ChangeNotifier、go_router；稳定对象ID和深链接 |
| 请求与离线 | Dio、Sembast/Sembast Web、path_provider；缓存与操作队列同事务保存，按userId隔离 |
| 会话 | Android系统安全存储中的Bearer；Web HttpOnly/SameSite Cookie + CSRF，刷新me恢复 |
| 服务端 | FastAPI/Uvicorn、SQLite WAL、对象版本CAS、幂等批次、持久作业与推送worker |
| AI | SiliconFlow语义拆解；独立Dart规则引擎验证预算/依赖/休息/缓冲/忙闲/截止 |
| 语音 | 独立sherpa-onnx CPU流式ASR、短期单次票据与WebSocket；WAV/WebM上传云端识别作为明确备用路径 |
| 平台 | Android日历/系统通知/PCM录音原生桥；Web ICS交换、AudioWorklet、Service Worker/Web Push |
| 部署 | 单主机Compose+Caddy，开发Mailpit/本机邮件sink，正式SMTP可配 |

选择这套方案可以复用已有Flutter工程与H5设计规范，保留课程中可解释的Widget/状态/仓储结构，同时把真实账号、同步、AI和平台能力放在明确边界中。精确依赖以pubspec.lock、backend/requirements.txt及requirements.lock.txt为准。实现细节见[架构说明](docs/ARCHITECTURE.md)。

## 安装与启动

需要Flutter、Python3.11、Android SDK/JDK17及可用设备；默认可直接本机使用，云端保存需要用户从头像进入“账户与设置”主动登录。首次在sera_flutter目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start-fullstack.ps1
```

若本机自定义镜像提示缺少 `image_picker_ios`，先在当前窗口设置 `$env:PUB_HOSTED_URL='https://pub.dev'`，再执行安装或构建。当前锁文件来自官方包源，保留旧依赖版本；不需要为图片选择降级 Flutter 或插件。

浏览器打开 `http://127.0.0.1:8787/`。setup安装锁定依赖、下载校验本地模型并创建本机私有release签名配置；模型已提供为独立量化模型资源包（int8 encoder/joiner + float decoder）时，可先将其解压到backend目录，再用setup的-SkipModel避免重新下载。启动脚本构建同源Flutter Web，并由supervisor启动API、worker和ASR；Ctrl+C停止整套子进程，已有构建可用-SkipBuild。

脚本可读取上级用户提供的密钥文件；也可用-AiKeyFile指定服务端文件，或配置SILICONFLOW_API_KEY/SILICONFLOW_API_KEY_FILE。密钥不会复制到Flutter构建、工作区或交付包。未配置密钥时账号/CRUD仍工作，云端AI请求明确报未配置，不会冒充AI成功。

默认地址为API/Web8787、本地ASR8790。开发邮件默认写入数据库同目录mail目录，测试链接指向 /#/verify-email 与 /#/reset-password；正式邮件需要自己的SMTP。完整环境变量、账号/同步/AI/ASR契约和错误边界见[API文档](docs/API.md)。

如果只开发后端，可分开启动三个终端：

```powershell
backend/.venv/Scripts/python.exe backend/server.py --ai-key-file ../硅基流动AI接口api.txt
backend/.venv/Scripts/python.exe backend/worker.py --db backend/sera.sqlite3 --ai-key-file ../硅基流动AI接口api.txt
backend/.venv/Scripts/python.exe backend/local_asr.py --db backend/sera.sqlite3
```

接口说明为 `http://127.0.0.1:8787/docs`。/health/live只说明API存活，/health/ready分开报告数据库、worker心跳、已加载ASR、邮件配置和AI配置；缺组件返回503，不能把API可访问当作全部后台能力可用。

## Android、Web开发与构建

```powershell
# Android调试：脚本建立adb reverse，传可用设备ID
flutter devices
powershell -ExecutionPolicy Bypass -File ./scripts/run-android.ps1 -Device '设备ID'

# Android官方模拟器也可直接连接宿主
# 若ASR票据仍使用默认127.0.0.1:8790，先转发该端口；或在服务端配置可达的SERA_ASR_WS_URL。
adb -s '设备ID' reverse tcp:8790 tcp:8790
flutter run -d '设备ID' --dart-define=API_BASE_URL=http://10.0.2.2:8787

# 发布Web：使用当前网页同源API，不写死本机端口
powershell -ExecutionPolicy Bypass -File ./scripts/build.ps1 -Target web

# 可安装本机调试APK
powershell -ExecutionPolicy Bypass -File ./scripts/build.ps1 -Target apk -Debug

# 独立release签名；正式移动端使用自己的HTTPS后端
powershell -ExecutionPolicy Bypass -File ./scripts/build.ps1 -Target aab -AndroidApiBaseUrl https://your-api.example.com -HideReview

# 显式备用本机模式（无账号/云AI，不作为完整联网功能验收）
flutter run -d chrome --dart-define=API_BASE_URL=
```

默认API_BASE_URL=same-origin：Web取当前origin，Android取127.0.0.1:8787（需adb reverse）。Web Cookie认证推荐同源；开发端口4180/4181的CORS许可不代表浏览器必然允许跨站Cookie。Android HTTP仅供调试，release应配置HTTPS。release构建已要求独立keystore；签名材料保存在.local/signing或外部SERA_SIGNING_PROPERTIES，源码包不包含私钥和密码。

Web输出在build/web，APK在build/app/outputs/flutter-apk，AAB在build/app/outputs/bundle/release。当前 Web 回归与构建核验见本文件顶部本轮验证；编译成功和设备运行分别记录。旧权限分支、通知/日历/录音操作证据保留在[历史交付记录](docs/DELIVERY_V2.md)。

## 核心演示

用户明确选择的手动时段允许在规划偏好之外；自动规划严格遵循偏好。服务端对新任务块与草案提交进行最终约束校验，外部/固定会议可以保留真实冲突供重排处理。

1. 打开“今日”→“交给 AI 安排”→按住说话并松开校对（或切换“文字输入”）→“让 AI 安排”→核对日期与预算→在线 AI 生成→编辑草案→确认后生成目标、任务和日程；手动创建在文字输入的次操作中。从“计划”切换任务/目标查看记录，需要云端保存时从今日头像进入账户登录并同步。
2. 任务详情设置检查项、优先级、依赖、阻碍、剩余工作和拆段；多时间块共享同一任务。完成/取消后更新未来安排和提醒。
3. 导入ICS或连接Android日历读取外部忙碌→识别冲突→查看建议→确认只移动可调整任务→历史查看/安全撤销。
4. 开始专注→暂停/继续→退出重开恢复→记录实际时长→反馈/回顾与目标验收。
5. 实时语音录入→查看partial/final→修改识别稿→送入目标规划；可取消、重录；云端上传备用识别会清楚标明来源。
6. 断网编辑→缓存及队列保留→重开→联网同步；多端同对象修改产生409时人工核对本地/远端，不覆盖无关数据。
7. 通知设置主动授权→开启并成功注册Web Push→请求测试；后端202只代表入队，实际后台到达需关闭页面后观察系统通知与点击恢复。
8. “账户与设置”登录并同步→已有云端记录与本机记录增量合并→差异显式选择；失败保留本机副本并允许重试。账号导出/邮箱验证/密码找回/注销保持可用；切换账号隔离缓存、通知和日历映射。

逐项实现、已有证据和未验证环境见[R01–R32追踪](docs/FULL_DEVELOPMENT_PLAN.md)。

## 项目目录

```text
lib/application/   Controller、会话边界、平台协调与业务用例
lib/domain/        schema2模型、规则排期、日期理解与演示数据
lib/data/          认证、HTTP、本机数据库、离线操作队列与仓储
lib/platform/      Android/Web能力契约、ICS、提醒请求与PCM录音
lib/ui/            共用样式组件和55页界面/异常恢复
assets/            原切图、SVG图标与本地中文字库
android/           原生桥、日历/通知/音频权限和签名构建
web/               平台桥、Service Worker、AudioWorklet及Web入口
backend/           FastAPI、认证/同步、AI/ASR、持久worker与接口测试
deploy/            Compose+Caddy+Mailpit、镜像与SQLite备份恢复
scripts/           安装、启动、构建、签名与交付包装
test/             领域、仓储、Widget、平台及Node测试
docs/              接口、架构、实现追踪、ASR指标与许可材料
```

## 测试、部署与证据

```powershell
flutter analyze
flutter test
node --test test/platform_worker_test.mjs test/platform_bridge_test.mjs
Push-Location backend
.venv/Scripts/python.exe -m unittest discover -v
Pop-Location
backend/.venv/Scripts/python.exe -m unittest discover -s test -p admin_backend_test.py -v
backend/.venv/Scripts/python.exe -m unittest discover -s test -p admin_analytics_backend_test.py -v
backend/.venv/Scripts/python.exe -m unittest discover -s scripts -p 'test_*.py' -v
```

后端自动化使用临时SQLite与虚构账号，付费供应商使用stub，本地ASR集成真实加载模型。固定音频推理的真实性能与复现命令见[LOCAL_ASR](docs/LOCAL_ASR.md)，权重与运行库分别核对的许可见[ASR归属](docs/licenses/ASR-NOTICE.md)。

早期版本已通过Chrome/Edge真实离线保存、冷/热重开、重连同步和双标签账号隔离，见[历史浏览器记录](docs/qa/web-offline-accounts.json)。早期交付源码/构建包与独立模型包还曾解压到新TEMP目录，在8792/8793用全新数据库启动实际服务，并验证会话、任务、本地推理与备份恢复，见[历史交付目录复现](docs/qa/clean-directory-rehearsal.json)。该复现复用了已安装Python3.11依赖，未声称干净操作系统或容器验收；2.0.2 的新执行结果单独登记。

Compose/Caddy、开发Mailpit、正式SMTP、模型卷初始化及备份恢复见[部署说明](deploy/README.md)。基础/dev Compose配置与官方校验Caddy配置验证已通过；宿主Docker Engine npipe错误使容器运行未验，不将配置校验称为部署成功。公网域名、真实TLS/SMTP和商店发布需要对应外部环境。

当前已实现真实账号系统与多用户数据隔离，不能再按v1“无鉴权、只用标准库、SharedPreferences整份JSON、52项旧测试”描述。2.0.3+5 的截图和 Web／APK／AAB 构建核验以[简洁风优化交付记录](docs/DELIVERY_MINIMAL_20261031.md)为准；本轮聊天与导航改动沿用 schema 2，新增会话字段向后兼容，历史构建产物按其各自版本理解。
