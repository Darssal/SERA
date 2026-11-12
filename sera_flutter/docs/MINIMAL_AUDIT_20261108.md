# 极简界面与文案检查（2026-11-08）

## 2.2.1 运营统计（2026-11-10）

用户要求后台增加运营分析与可视化，用于了解社区内容和互动。现有概览只有累计数量，不能回答近期何时发布、哪些类型较多、哪些内容获得互动。因此在同一概览加入四项指标、两幅趋势、分类和可打开详情的排行；不新增主导航、预测、目标配置或私人任务统计。

使用现存时间字段和原生 Flutter 绘制，不新增依赖、数据库表或客户端埋点。高级的逐日明细和统计口径按需展开。维护成本是一个只读聚合接口、带会话取消边界的 DTO／控制器与图形交互测试；避免另建通用分析平台。记录缺失的点赞／报名事件时间只允许累计，不补造历史，不将发帖评论人数称为访问或日活。统计基于现存数据，明确演示数据与删除的影响。决策、官方资料及实际验收详见 [运营统计说明](ADMIN_ANALYTICS.md)。

## 2.2.0 Web 管理后台（2026-11-09）

版本 **2.2.0+32**。用户明确要求完整 Web 后台，用于课设社区运营。本轮将相关管理操作集中为七区：概览、内容管理、官方发布、管理员与申请、用户、操作记录、运行状态；用户侧今日／计划／日程／社区四栏与极简操作保持原有职责。后台查询服务审核定位问题的真实需求，不把搜索、更多菜单或运营统计重新放回用户主界面。

| 取舍 | 实际实现与必要复杂度 |
| --- | --- |
| 复用现有技术栈 | 同一 Flutter Web、Provider、go_router、Dio 与 FastAPI；发布／图片／授权沿用社区业务，不新增后台前端框架、角色体系、数据库或直接依赖 |
| 按任务分区 | 七个相关管理上下文；宽屏侧栏与表格，窄窗口抽屉与横向表格滚动，按当前窗口约束适配，不直接拉宽普通手机页面 |
| 权限仍由服务端决定 | 沿用官方名单与四权限；每次请求和事务重新验证，普通管理员只看到可用区，不能使用官方专属用户管理、授权、审计或状态接口 |
| 账号与数据安全 | 后台用户身份脱敏，不读取个人工作区；独立状态附表，停用撤销会话／推送／语音票据并取消作业，恢复需重新登录，原工作区和内容保留 |
| 删除和处理可核对 | 原因必填、稳定操作 ID、共用社区删除边界；业务变更与审计同事务，失败回滚，重复提交不产生第二次管理操作 |
| 输入和异常恢复 | 发布离开确认，分区间表单保留，账号变化清空旧内容与弹窗；列表筛选、游标、错误与重试按账号归属，失败不冒充成功 |
| 不把配置冒充健康 | 状态页不发送外部请求；配置存在用 `configured`／`healthy:null`，实际数据库读取和 worker 心跳独立表达 |

新增维护成本限于七区响应式页面、现有业务的管理查询、独立操作收据／审计与账号状态附表，以及实际权限／恢复回归。没有加入私人任务运营、任意密码重置、邮箱编辑、通用角色编辑器、站内消息、批量删除或假统计。管理端继续遵守“少概念、明确结果、可靠失败恢复”的原则。

本轮主动核对的一手依据：

- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)：最小权限、默认拒绝、逐请求验证和授权测试落实为现有官方／四权限服务端边界，而不是由菜单和客户端角色标志决定允许行为。
- [Flutter Large screen devices](https://docs.flutter.dev/ui/adaptive-responsive/large-screens)：基于窗口可用宽度改变导航和内容排布，表单限制阅读宽度，支持鼠标、键盘和表格滚动；复用现有 Widget，不引入新桌面 UI 框架。

已实际执行管理员后端隔离验收 **27 项全部通过，0 失败**，最终重跑日志 `.local/admin-backend-delivery-20261109.log`。覆盖账号与权限变化、Cookie CSRF、真实删除级联与幂等、原因保留和事务回滚、账号停用／恢复与工作区保留、公开作者检索隐私、稳定分页、旧身份迁移及外键、9 个实际端点 OpenAPI／DTO 契约和状态页不调用外部服务。最终静态分析无问题，Flutter 1013 通过／1 项原有可选 HTTP 测试跳过；现有后端 467、配置交付 25、Web 平台 41、清单 3 项通过。浏览器七区、320/390px 窄屏与 1536px 桌面、草稿保护及三轮登录实际完成；修复旧焦点清理后无新增控制台错误。Web 与签名 APK/AAB 已构建校验，MuMu 本轮未实测。详见[后台说明](ADMIN_CONSOLE.md)与[最终验收及边界](ADMIN_CONSOLE_QA_20261109.md)。

## 2.1.4 多图集中浏览（2026-11-09）

版本 **2.1.4+31**。用户提供了多图轮播和全屏大图参考。本轮将详情中的纵向多图合并为单个左右轮播图片区，下面使用 6px 紧凑圆点指示当前图片，让正文和评论保持接近；图片不再逐张拉长页面。点击图片进入深色全屏，只保留关闭 X、张数和看图操作，日常页面仍采用 SERA 浅色与绿色。横滑切图，双击或捏合缩放，放大后平移；关闭恢复原页码、滚动位置和未发送评论，不增加分享、收藏或关注入口。

实现复用 Flutter 官方 [PageView](https://api.flutter.dev/flutter/widgets/PageView-class.html) 与 [InteractiveViewer](https://api.flutter.dev/flutter/widgets/InteractiveViewer-class.html)，没有新增依赖、公开接口或数据库迁移。集中分页避免多张图片同时占据纵向阅读空间；当前图片与缩放状态只绑定当前账号、帖子和媒体版本。身份变化、内容删除或附件变化时停止绘制旧图并精确移除该图览，保留异步归属和资源释放边界，不能误关后来打开的页面。

社区封面按用户后续反馈放开普通照片的比例限制，横图与竖图按原图形成不同高度；保持双列独立接续，只有极端条幅保留宽松边界，不制造随机高度。新增一条明确模拟的横图首封面供实际查看，保留原帖子和图片顺序。300／1000 项末项的真实跳转／返回和惰性构建继续验证。

静态分析无问题，Flutter **977 通过／1 项原有可选测试跳过**，含图览 **13 项**真实触控／鼠标、页码、输入、重试和账号边界行为。浏览器 320/390px 实查，修正圆点间距／对比度和未缩放时鼠标手势被吞的问题；鼠标路径转交框架原生分页物理，没有新阈值或依赖。Web 平台／真实资源缓存 **41 通过**，清单 **3 通过**；新版本静态资源增加 33,623 字节，71 项未变资源复用。Web、签名 APK/AAB 已构建校验；MuMu 安卓设备-1 未运行，不计设备实测。截图、返回方式区别及执行范围见 [design-qa.md](../design-qa.md) 和[社区记录](COMMUNITY.md#214-多图轮播与全屏查看2026-11-09)。

## 2.1.3 社区自然错列与平铺评论（2026-11-09）

用户明确提出两栏不必对齐，并补充帖子详情与评论参考；保留 SERA 浅色和绿色。卡片根据实际封面比例和标题高度自然接续短列，封面外不包重复面板；纯文字采用真实标题或正文首段的大字封面。详情完整标题自然增高，正文、日期、评论平铺，底部只保留真实评论输入和帖子点赞。没有重新引入搜索、推荐或无后端能力的关注／收藏／分享。

新增精确锁定 `flutter_staggered_grid_view 0.7.0` 仅解决此明确布局问题，替代固定尺寸 SliverGrid；复用单一滚动、惰性 delegate、稳定 key 与一次构建索引。包只依赖 Flutter，避免维护自定义渲染器；未改 REST、持久数据格式或数据库版本。判断依据是[包作者 Masonry 说明](https://pub.dev/packages/flutter_staggered_grid_view/versions/0.7.0)及[API](https://pub.dev/documentation/flutter_staggered_grid_view/latest/flutter_staggered_grid_view/SliverMasonryGrid-class.html)，不把“不加依赖”机械套用于已确认需求。

新增模拟内容均明确标注，4 个模拟账号、12 帖、3 张 AI 示意图和 18 条实际保存的评论；没有虚构互动计数。导入前备份，重复导入不新增、不复活已删除内容，旧内容及个人工作区、报名和权限对比保持一致。

静态分析无问题，Flutter **963 通过／1 项原有可选测试跳过**；300/1000 条异高列表逐窗真实构建 <20，末项可达；320px 1.5/2 倍字体、长标题和键盘输入／幂等重试通过。Web 平台及真实构建升级 **41 通过**、离线清单 **3 通过**。新版静态资源比中间版增加 9,919 字节；升级复用 70 项 34,781,464 字节，只下载 4 项 7,205,635 字节。这是测试框架和真实文件字节，未宣称实机启动／内存 profile。

浏览器检查 320/390px、详情评论、输入、点赞恢复与返回，控制台无 error/warn；源图和实际截图同次对照，见 [design-qa.md](../design-qa.md) 与[完整证据](COMMUNITY.md#213-瀑布流大字封面与评论2026-11-09)。Web 已更新，APK/AAB release 构建成功；MuMu 安卓设备-1 当前未运行，设备实测仍单独待验。保留旧版 Web 和构建，不常驻新的测试服务。

## 2.1.1 社区图文、反馈与刷新（2026-11-09）

版本保持 **2.1.1+28**。用户明确选择双列图文信息流与真实图片发布，并提出使用反馈分类、头像一致性与滚动刷新要求。本轮围绕社区浏览、发布和失败恢复实现这些能力；个人任务与日程继续保持私有，既有技术栈与原直接依赖约束不变。

| 需求与取舍 | 已落实实现与可靠性边界 |
| --- | --- |
| 双列图文 | 使用 Flutter 自带惰性 `SliverGrid.builder`；文字帖也能正常展示，图片加载失败可重试，不用占位图片冒充附件；不增加 masonry/瀑布流依赖或第二套列表状态 |
| 日常与反馈 | 帖子 `category` 为 `daily` / `feedback`，旧请求与记录默认日常；使用反馈筛选取真实反馈帖子，官方与普通反馈均可出现；活动不能归为反馈；分类进入幂等内容比较 |
| 同一作者身份一致 | `authorIsOfficial` 由服务端真实所有者名单或系统作者决定，与内容的 `isOfficial` 分开；管理员代发官方内容仍使用本人昵称与头像，官方所有者的所有内容保持同一品牌头像 |
| 真实滚动与刷新 | 下拉刷新、接近底部分页和已到末页后的刷新调用仓储；保留式刷新先完整读取已浏览范围，再原子替换。保留筛选、稳定 ID 与滚动控制器，中途失败保留旧列表，账号或筛选变化后忽略迟到结果；不从局部结果推算点赞或评论数量 |
| 图片选择与上传 | 最多三张 JPG/PNG/WebP、每张输入不超过 8 MiB；客户端缩图并提供本地预览，服务端再次解码验证。二进制上传复用既有认证与 CSRF，逐张保持上传重试 ID；图片顺序进入发布幂等内容，正文仍必填 |
| 失败与恢复 | 选图取消不上传；单张失败不清空其他成功图片；过期错误带具体媒体 ID，只重传受影响图片。Android 选图期间被回收后的恢复以 API 地址、用户 ID、会话 ID 标记核对归属，不存 token，不跨账号展示，不自动发布 |
| 服务端媒体边界 | 独立社区迁移 4；上传时修正方向、去除 EXIF/GPS 等元数据、保留透明度，限制输入像素并缩小长边。未发布媒体仅上传者可读，24 小时后失效；发布事务绑定本人媒体后才公开读取。读取不进入静态离线缓存，删除与注销继续清理关联数据 |

新增依赖只覆盖已确认需求中的现有能力缺口：`image_picker: 1.2.4` 提供 Android/Web 系统选图及 Android 进程重启后的选择恢复；`Pillow==13.0.0` 提供后端真实解码、方向处理和去元数据重编码。维护成本是两端选图与格式兼容验证、媒体存储及清理、上传失败和账号归属恢复；不引入瀑布流库、通用媒体管理框架、对象存储服务或持续文章草稿系统。已有 Provider、Dio、认证传输、SharedPreferences 轻量存储及 SQLite 事务继续复用。

本轮核对的一手资料与适用决定：

- [Flutter SliverGrid](https://api.flutter.dev/flutter/widgets/SliverGrid-class.html)：采用惰性构建，真实帖子和计数留在控制器，行视图可以按稳定 ID 重建。
- [Flutter RefreshIndicator](https://api.flutter.dev/flutter/material/RefreshIndicator-class.html)：刷新回调等待实际读取完成；与滚动分页共用仓储，不用延时动画冒充刷新。
- [Flutter 官方 image_picker](https://pub.dev/packages/image_picker) 与 [pickMultiImage API](https://pub.dev/documentation/image_picker/latest/image_picker/ImagePicker/pickMultiImage.html)：锁定 1.2.4，设置 1600×1600、质量 85、`requestFullMetadata:false`。此版本剩余名额为 1 时内部转单图选择，无需自行维护另一选择流程；Android 恢复能力与账号标记一起接通。
- [image_picker Web 实现说明](https://pub.dev/packages/image_picker_for_web)：浏览器文件类型筛选不能替代验证；客户端检查实际文件头，服务端真实解码。Web 取消行为仍依赖浏览器支持；不声称所有浏览器均已实测。
- [Pillow Image](https://pillow.readthedocs.io/en/stable/reference/Image.html) 与 [ImageOps.exif_transpose](https://pillow.readthedocs.io/en/stable/reference/ImageOps.html#PIL.ImageOps.exif_transpose)：按格式和尺寸验证后处理方向，复制纯像素再编码，避免把原始元数据发布到社区。

最终后端统一回归：**467 项，465 通过、2 项 ASR 推理测试跳过、0 失败**，包含 **48 项社区行为和 8 项 OpenAPI 合同测试**；记录为 `.local/community-photo-backend-final-20261109.log`。媒体合同使用隔离数据库和真实 PNG 字节验证上传、未发布访问限制、发布绑定与公开读取；社区业务回归覆盖图片类型、像素、幂等、归属、过期和清理。另修复失效 Cookie 阻断公开读取：只对公开 GET 的 401 降为游客，所有写入与管理仍需有效身份，不修改跨标签共享 Cookie。两项 ASR 跳过不能计为本轮语音推理通过。

静态分析无问题；Flutter 全量 **947 通过、1 项原有可选 HTTP 测试跳过**，平台真实构建升级 **41 通过**，脚本 **25 通过**，离线清单 **3 通过**。320px 大字体及 300/1000 条惰性图文列表通过；补齐平台滚动物理父链后，刷新返回时原位置断言继续通过。浏览器实际使用文件选择器完成两图发布、刷新、点赞和评论，320/390px 无溢出。发布 Web、签名 APK/AAB 已构建并校验；升级复用 70 项／34,781,464 字节，下载 4 项／7,193,348 字节。MuMu 安卓设备-1 启动后退出、ADB 拒绝连接，实际相册与设备行为未验收；注入选择器与模拟 HTTP 不能代替此项。详情与证据见[图文社区验证](COMMUNITY.md#211-图文社区验证2026-11-09)，历史版本保留。

## 2.1.0 社区与管理员（2026-11-09）

用户明确新增课设互动需求，主导航调整为今日 / 计划 / 日程 / 社区四栏。社区承担官方活动、动态和用户日常分享；个人任务与日历不自动公开。信息流、详情、发布、申请／管理四个页面覆盖需求，暂不增加搜索、排行榜、私信、积分、媒体占位按钮或第二套个人资料系统。

管理员权限仅有四项直接能力，官方在同一管理页添加已有用户、逐人分配或撤回，并审核普通用户申请。管理身份不等于官方所有者，只有服务端所有者能分配权限；用户只需理解可执行的操作，无需接触内部角色编码。新模块复用已有认证、传输、主题、动画和事务存储，无新增依赖，工作区格式不变。实现依据、接口及课程演示见[社区说明](COMMUNITY.md)。

这是已确认需求对原三栏边界的明确更新。取舍继续以真实流程为准，保留真实共享数据、失败恢复、权限与会话隔离，避免只做展示卡片或在客户端假装计数成功。

日期：2026-11-08（Asia/Hong_Kong）。范围是原 55 个页面/状态和新增账户页面。本次处理展示与入口，不迁移用户数据，不改变在线 AI、排期、保存和同步规则。

## 2.0.20 页面删减标准

- 移除没有当前业务依据的下一步推荐、固定示例和模板推荐。
- 移除同页或相邻页面的重复信息与重复入口。
- 页面只展示本次实际状态；静态步骤清单不能冒充运行进度。
- 低频诊断归入已有诊断区域，开发工具由真实环境或显式演示开关决定是否显示。
- 保留完成、编辑、保存、撤销、确认范围、失败原因、权限处理与恢复路径。

## 页面检查记录

| 页面或流程 | 本次处理 | 保留的实际操作 |
| --- | --- | --- |
| 欢迎与首次设置（01–04、37、38、49） | 欢迎页删除固定示例日程和功能宣传；目标空态删除固定入门模板入口及无引用的 UI 文件 | 开始、跳过、真实偏好与日历连接；今日录入、任务、专注续接与下一项日程 |
| AI 输入、澄清与草案（05–10） | 生成中删除固定步骤清单；确认页删除重复的首项任务推荐卡 | 在线语义理解、真实生成阶段、原文与草案编辑、保存范围、确认与返回修改 |
| 保存与调整结果（11、22、23、51、52） | 保存中删除固定步骤清单；结果页删除任意首任务“下一项”卡 | 真实结果、数量、时间差异、待安排内容、取消、撤销及返回 |
| 日程与同步（12–16、32、41、42） | 2.0.19 已删除“添加会前准备任务”；本次检查保留真实日程内容和同步状态，不增加替代按钮 | 日期切换、事件编辑、ICS、权限、来源选择、逐项同步失败和重试 |
| 计划与目标（17–21） | 目标创建只保留 AI 入口；账户入口已集中在今日 | 任务/目标切换、完成/撤销、详情、目标进度、旧草案继续编辑与提交 |
| 执行、回顾、提醒（24–29、45–47） | 完成结果删除无依据的下一项及重复目标卡；完成文案准确为“完成任务”；提醒空态改一行；任务提醒删除正文重复返回 | 暂停/继续/结束、完成/剩余工作/阻碍、实际专注、复盘保存、提醒设置；顶部返回恢复原任务和筛选 |
| 账户、偏好与隐私（30、31、33、36、54，新增账户页） | 账户卡合并重复账户安全入口；隐私页移除重复日历/通知跳转；演示重置默认关闭；后台推送测试移入已有诊断区域；普通邮件验证不显示本地开发工具；邮箱验证完成后不再显示刷新按钮 | 登录/验证/找回/注销、偏好、导出与清理、权限与免打扰；本地开发模式仍可完成邮件验证 |
| 历史、兼容与异常（34、35、39、40、43、44、48、50、53、55） | AI 生成失败移除无关的手动新任务引导；旧搜索只保留兼容路由 | 历史与草案、继续/重试/修改要求、离线内容、删除与放弃确认、过期重查、语音校对、撤销冲突、草案恢复 |

## 数据与兼容

删除模板推荐入口不会删除已保存的模板目标、任务或草案。领域层保留旧草案重载、编辑、确认提交和幂等保护。日程准备任务旧链接继续兼容，不再作为日程详情的主操作。必要的业务错误、权限说明、隐私选择和不可逆操作说明均保留。

## 验证证据

- 静态分析：`.local/flow-minimal-analyze.log`，无问题。
- 全量 Flutter 回归：`.local/flow-minimal-full-tests-final.log`，869 通过、1 项原有可选 HTTP 测试跳过、0 失败。
- 发布构建：`.local/flow-minimal-web-build.log`，2.0.20+22 历史构建成功。
- 规划专项：`.local/planning-simplification-tests.log`、`.local/planning-confirm-simplification-tests.log`。
- 设置与邮件：`.local/flow-minimal-settings-tests.log`。
- 主页面与历史草案：`.local/minimal-main-pruning-tests.log`。
- 最终版本、校验值与测试数量见 README 顶部；浏览器截图见 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-flow-minimal/`。

浏览器实际验证 390px 的账户入口合并、隐私列表、欢迎页、今日语音弹层及返回路径，控制台无 error/warn。仅阅读与切换页面，没有保存业务数据、启动麦克风或请求供应商。320px 覆盖由自动化完成：本次浏览器视口覆盖请求未改变目标标签页实际 390px 尺寸，因此不计作 320px 浏览器验收。截图 `profile-390.jpg`、`privacy-390.jpg`、`welcome-390.jpg` 均为本轮实际页面。

测试使用隔离仓储、模拟网络与平台通道验证数据变化，不代表本轮新增了外部供应商、短信、邮件投递或 Android 实机联调。此次不启动额外模拟器或后台测试服务。

## 2.0.21 用户文案调整

以日程详情“已锁定 · 重排任务时保留”的反馈为起点，检查任务、日程、规划、账户、备份、提醒与语音页面。重复的内部机制说明直接移除；涉及用户选择的内容，用具体动作和后果说明。

| 原表述 | 调整后 |
| --- | --- |
| 日程详情：时间安排 / 已锁定 · 重排任务时保留 | 删除重复字段，保留“固定日程”标识 |
| 编辑开关：锁定时间 | 固定这个时间；自动安排不会改动这个时间 |
| 时间块、首个时间块、剩余工作量、估时 | 安排/时段、第一段用时、还需用时、预计用时 |
| 未提交草案 | 待确认草案 |
| 执行跟进、调度精度、精确闹钟调度 | 未开始时再提醒、提醒时间、允许准时提醒 |
| 同步失败事项的内部 ID | 有名称时显示日程名称，已删除等无法找到名称时显示“有一项日程未同步” |
| 本机/云端冲突、提交一批操作 | 这台设备/云端内容，并说明选择会替换哪些修改 |
| 工作空间、账户会话、会话有效期 | 安排与记录、账户与安全、登录有效期 |
| 主入口中的 JSON、复制完整 JSON | 查看与复制数据、复制内容；格式仅在备份内容区说明 |
| 手机号身份设置、邮件凭证、冷却 | 邮箱与密码、邮件中的链接、倒计时 |
| 实时转写、发送至服务端识别 | 边说边出字、上传识别；保留录音上传提示 |

确认范围、不可撤销的后果、外部日历修改限制、录音上传说明和失败后的下一步继续保留。没有改动账号、排期、保存、同步、通知或在线 AI 的业务规则；旧链接与已有记录继续兼容。既有测试只更新必要的入口定位和文案断言，仍验证实际数据与操作结果。

本版静态分析无问题；全量 Flutter 测试 869 通过、1 项原有可选 HTTP 测试跳过、0 失败；发布 Web 构建成功，8787 预览已更新为 2.0.21+23。验证记录位于 `.local/plain-language-analyze.log`、`.local/plain-language-full-tests-final.log`、`.local/plain-language-web-build.log`；构建校验值见 README 顶部。

浏览器默认移动预览中，实际走过“日程 → 添加日程 → 切换固定时间 → 返回 → 放弃修改 → 日程”，确认新措辞、开关值变化、未保存确认及返回正常；随后检查“今日 → 账户与设置 → 数据与隐私”。页面不为空，无错误遮罩，控制台无 error/warn。截图保存在 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-plain-language/event-edit.jpg` 和 `privacy.jpg`。浏览器没有保存业务修改，没有新建日程、触发录音、发送短信或邮件；本版未运行 Android 设备或新增 APK/AAB。

## 2.0.22 产品、架构与性能简化落实

版本：**2.0.22+24**。本节追加记录本轮实际实现，前述 2.0.20、2.0.21 记录继续保留。范围从界面删减扩展到查询、列表构建、静态资源更新和后端职责边界；沿用 Flutter、Provider/ChangeNotifier、go_router、FastAPI、SQLite 和现有仓储，不迁移用户数据或更换技术栈。

### 长期准则与本轮取舍

根目录 [AGENTS.md](../../AGENTS.md) 已把软件极简主义列为长期开发准则：新能力必须对应真实问题，删除前核对运行引用、动态资源和旧数据用途；常用操作直达，高级选项在相关上下文展开；不把删除的入口重新包装成更多菜单、推荐卡或新设置。账号隔离、取消迟到响应、事务队列、幂等、版本冲突与完整缓存切换是可靠性要求，继续保留。性能结论必须附带测量环境，不能用代码行数或隐藏内容代替实际优化。

| 处理 | 已落实内容 | 保留边界 |
| --- | --- | --- |
| 保留核心 | 今日 / 计划 / 日程三栏；计划内包含任务和目标；今日默认语音录入、在线 AI 理解、文字与手动添加备用 | 目标进度、任务完成与撤销、日历、提醒、离线恢复、账号与隐私不因精简而删除 |
| 合并确认 | AI 草案直接显示创建或更新范围，并接受一次明确确认，复用原提交流程 | 旧 `/10` 及其后缀链接回到对应 `/08`，保留查询参数，不因打开旧链接产生业务写入；过期重查、修改保留、幂等与取消继续有效 |
| 按上下文展开 | 修改任务时间进入同一编辑表单的时间部分；其余字段按需展开，展开/收起不丢输入 | 普通任务编辑仍可访问完整字段；返回与放弃恢复原列表、筛选和对象 |
| 简化目标详情 | 只展示当前状态、完成标准、截止、真实进度和任务；暂停、恢复、归档移入原“修改目标信息”弹层 | 修改一次保存；取消不落盘；目标完成仍需核对标准并显式验收，不随最后一个任务完成而自动结束 |
| 复用完成流程 | 今日、计划和目标任务清单统一使用 `completeTaskFromList` 与 `SeraCompletionUndo` | 未来安排处理、实际专注历史、持久撤销及后续修改冲突保护保持一致 |
| 移除无运行入口的生成器 | 正式控制器不再提供 `createStarterGoalDraft`，原固定入门模板仅留在测试历史夹具 | 旧 `local-template` 草案仍可重载、编辑、确认与幂等重试，不删除既有目标、任务或草案 |
| 清退无引用资源 | 移除 `cupertino_icons` 直接依赖；不再声明无用装饰目录及备用品牌图为运行资源 | 原始素材文件保留；实际使用的品牌图、动态 SVG 图标目录与完整中文字体保留 |
| 缩小计算与构建范围 | 当前筛选按需查询；任务与首段安排建立单次快照索引；任务清单及目标任务清单改为惰性 `SliverList`，按所需字段订阅 | 原条目顺序、稳定对象 ID、深链接定位、滚动位置、完成撤销与账号隔离继续测试 |

### 研究依据与具体决策

以下来源在本轮核对；右侧是结合当前产品作出的实现选择，不把通用原则视为所有页面一律缩短的要求。

| 依据 | 对 SERA 的具体决定 |
| --- | --- |
| [NN/G：Aesthetic and Minimalist Design](https://www.nngroup.com/articles/aesthetic-minimalist-design/)：无关信息会争夺重要信息的注意力 | 保留真实目标标准、进度、确认范围与失败恢复；删除重复确认页、预设推荐和重复状态选择 |
| [NN/G：Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)：优先呈现常用选择，将较少使用的能力按需展开 | 时间编辑先展示本次修改的时间字段；目标状态移入已有编辑弹层，不增加新的菜单层级 |
| [Martin Fowler：YAGNI](https://martinfowler.com/bliki/Yagni.html)：不提前承担假设需求的实现与维护成本 | 删除没有正式入口的固定模板生成器和无引用依赖；保留实际用户记录的读取与提交兼容，不另造通用框架 |
| [Flutter：Architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)：按职责划分 UI 与数据边界，建议应适配具体项目 | 继续现有控制器与仓储，复用任务完成/撤销；后端只抽出已有纯校验和存储职责，不进行大重写 |
| [Flutter：Performance best practices](https://docs.flutter.dev/perf/best-practices)：长列表使用惰性构建，控制构建成本，并在合适环境测量 | 用 SliverList 与局部订阅减少首屏构建和无关重建；以同一任务/首段安排顺序验证索引查询，不将 JIT 测试耗时当设备帧率 |
| [MDN：Cache](https://developer.mozilla.org/en-US/docs/Web/API/Cache)：缓存更新、版本及清理由应用明确管理 | 按新清单的路径、大小与 SHA-256 验证旧资源；未变资源复用，缺失、变化或损坏时下载；完整候选准备成功后才切换，失败继续使用旧完整版本 |
| [MDN：WorkerNavigator.locks](https://developer.mozilla.org/en-US/docs/Web/API/WorkerNavigator/locks)：worker 可申请同源锁协调共享操作 | 对资源准备、版本提交、标签页绑定和清理串行协调；无 Web Locks 时保守保留其他完整缓存，避免清理并发版本或仍在使用的旧标签页资源 |

静态字体不按固定中文字符子集裁剪；当前优化优先复用未变化的完整字体和其他大资源。缓存计数仅用于内部验收，不新增用户设置。登录接口、用户 API、写请求及带认证数据的响应不进入静态资源缓存。

### 后端职责边界与兼容

`backend/workspace_validation.py` 承接原有纯校验、变更元数据和规划结果一致性规则；`backend/workspace_store.py` 承接事务存储。FastAPI、同步和排期调用这些职责明确的边界，`server.py` 继续重导出旧调用需要的符号。仍有业务用途的 HTTP 字节兼容桥保留；没有开启第二个隐藏监听器，也没有更换 `/api/v1` 契约、错误类型、数据库版本或业务规则。完整后端回归见下表，兼容以实际入口和数据断言为准。

### 自动化与测量记录

| 验证 | 本轮结果 | 证据 |
| --- | --- | --- |
| Flutter 静态分析 | 0 issues | `.local/minimal-engineering-analyze.log` |
| Flutter 最终全量回归 | **880 通过、1 跳过、0 失败**；原有可选 HTTP 测试继续单独标记 | `.local/minimal-engineering-full-tests-final.log` |
| 后端回归 | **411 通过** | `.local/minimal-engineering-backend-tests.log` |
| Python 离线资源清单 | **3 通过** | `.local/minimal-engineering-manifest-tests.log` |
| Node 平台、离线与缓存回归 | **41 通过、0 失败**，含真实发布资源的 5 次冷加载/升级审计 | `.local/minimal-engineering-platform-final.log` |
| 任务列表测量 | 100 / 300 / 1000 任务，390×844 widget harness 首屏均构建 **8 行**；验证筛选和首段安排顺序一致 | `.local/minimal-engineering-list-benchmark.json` |
| 缓存复用测量 | 使用真实旧版与候选 Web 发布字节，对完整升级与复用数量做断言 | `.local/minimal-engineering-cache-benchmark.json` |

列表查询运行环境为 Windows x64、Dart 3.13.2 VM JIT。以 `todo` 筛选的 **30 次合计**为例，原查询/索引查询分别为：100 任务 `12.903 / 2.094 ms`，300 任务 `49.557 / 1.739 ms`，1000 任务 `599.802 / 4.039 ms`。这些是本机微基准诊断值，包含 JIT、顺序与预热等环境影响；其他筛选的原始结果也保存在同一 JSON。widget harness 的 eager 对照只渲染行，正式惰性页面还包含导航和筛选，不能据两者耗时计算设备体验提升比例。能确认的是构建数量减少、查询结果一致，以及稳定 ID 定位和返回测试通过。

发布资源缓存测量结果：

| 指标 | 记录值 |
| --- | ---: |
| 候选完整资源数 | 74 |
| 候选完整资源字节 | 41,781,504 B |
| 已验证并复用的资源 | 67 个，34,767,490 B |
| 需要下载的资源 | 7 个，7,014,014 B |

缓存测量运行在 **Node VM 与内存 CacheStorage/IndexedDB 测试容器**，使用真实发布文件。5 次记录中，容器冷缓存准备为 `56–66 ms`，升级准备为 `58–63 ms`；heapUsed 为 `8,959,000–10,595,840 B`，RSS 为 `255,139,840–423,878,656 B`。这些数值仅描述测试容器，不能标为浏览器真实启动时间、Flutter 应用内存或 Android 性能。设备 profile、真实冷/热启动、帧率和滚动性能仍待测。

### 本轮发布与实际浏览器检查

- Web **2.0.22+24** 已构建并更新本机预览。候选目录为 `.local/web-minimal-engineering-20261108/`，可回退版本保留在 `.local/web-before-minimal-engineering-2021/`；构建记录为 `.local/minimal-engineering-web-build.log`。
- 候选 `main.dart.js` 的 SHA-256 为 `8457AFE488B64DF8192DC560FDB436D129481B9CDB1345D05073BF24F30BC1FC`。
- 浏览器实际打开已有任务的时间编辑，将原 15 分钟改成 20 分钟，展开和收起其他信息后输入仍保留；随后返回并放弃，原任务仍为 15 分钟。此项验证的是表单保留和取消，不是一次已保存业务修改。
- 浏览器查看了目标详情及其状态选择，没有保存状态修改；查看今日默认语音入口，没有启动录音或上传语音。
- 本轮截图目录为 `C:/Users/rytram/.codex/visualizations/2026/11/08/sera-minimal-engineering/`，文件包括 `time-editor.jpg`、`time-input-preserved.jpg`、`goal-detail.jpg`、`voice-entry.jpg`。
- Android release APK 已构建成功，证据为 `.local/minimal-engineering-apk-build-final.log`。MuMu 安卓设备-1 当前未运行，本轮没有 Android 安装或设备交互验收；APK 构建成功不能替代设备验收。

Android 首次使用 `--no-pub` 的构建失败另保留在 `.local/minimal-engineering-apk-build.log`：旧 `GeneratedPluginRegistrant.java` 仍引用开发依赖 `integration_test`，而 release Gradle 正确排除了该依赖。已只读核对本机 Flutter 3.47.2 源码：`flutter_command.dart` 的 `regeneratePlatformSpecificToolingIfApplicable` 在 `shouldRunPub == false` 时提前返回；`packages.dart` 说明单独 pub get 以非 release 模式生成注册文件，后续正常构建应重新生成。改用正常 `flutter build apk --release` 后，工具按 release 模式重新生成注册文件并排除开发插件，构建通过。既有 `scripts/build.ps1` 默认保留 pub 步骤，无需手工改生成文件或将测试依赖移入生产依赖。

最终 Android 产物已复制至 `.local/releases/sera-2.0.22+24/`，校验记录为同目录 `SHA256.json`：

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `sera-2.0.22+24.apk` | 77,764,817 | `D582C36D0C5BD8FD0CA8578A559C4F7BD8442BD1413B64C3E0C6B1A916C73D7B` |
| `sera-2.0.22+24.aab` | 74,869,228 | `E0ECAD84A907B56F26914ACC112BA73866C76CB49FCF69E88B1364DD3D5210EC` |

AAB 构建记录为 `.local/minimal-engineering-aab-build.log`；APK 的 `apksigner verify --verbose` 通过 v2 签名校验，`aapt dump badging` 确认包名 `com.sera.sera_flutter`、versionName `2.0.22`、versionCode `24`。两份包均连接演示主机回环 API，设备运行前需 `adb reverse` 8787/8790；正式远端使用既有构建脚本传入 HTTPS API。私钥和密码未复制到交付目录。

复现本轮检查可在 `sera_flutter/` 中执行；性能审计会覆盖指定本机 JSON，修改输出路径即可保留旧记录：

```powershell
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
backend/.venv/Scripts/python.exe -m unittest discover -s backend -p 'test_*.py'
backend/.venv/Scripts/python.exe -m unittest discover -s test -p 'platform_offline_manifest_test.py'
node --test test/platform_worker_test.mjs test/platform_bridge_test.mjs
dart run scripts/task_list_benchmark.dart
flutter test --no-pub test/task_list_scale_test.dart

# 使用完整实际发布文件核验升级，并输出五次容器测量
$env:SERA_CACHE_BASELINE = (Resolve-Path .local/web-plain-language-20261108).Path
$env:SERA_CACHE_CANDIDATE = (Resolve-Path .local/web-minimal-engineering-20261108).Path
$env:SERA_CACHE_REPORT = Join-Path (Get-Location) '.local/cache-benchmark-recheck.json'
node --expose-gc --test test/platform_worker_test.mjs test/platform_bridge_test.mjs

# 正常发布步骤保留 pub 以重新生成平台注册表
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Target web -HideReview
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Target apk -HideReview
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Target aab -HideReview
```

浏览器验收结束时已取消未保存表单并恢复计划任务页，控制台无 error/warn。实际截图包含 `plan.jpg`。自动化进程、Node 审计和非驻留 Gradle 构建均已退出；未启动额外模拟器或新测试服务。

## 2.0.24 列表内展开子项（2026-11-09）

用户指出今日的 `0/2 项` 只能进入详情查看，执行时需要重复切页。本轮将现有检查清单放到任务行下按需展开，服务今日执行及计划检查流程；继续使用现有 `setCheck`、任务模型、完成及撤销逻辑。新增成本限于共用行的展开状态、一个可选勾选回调和三处接线，不增加新的任务层级、导航、设置或依赖。

- 今日、计划和目标任务清单保持同一行为：含检查项时显示向下箭头，取代原被动目标图标；没有检查项时不显示空展开入口。点击标题仍进入详情。
- 展开/收起仅改变当前界面，不写业务数据；勾选子项即时持久化，保存成功后更新数量，保存失败保留原值并允许重试。收起不撤销已保存的勾选，全部子项完成不自动完成父任务。
- 保存期间禁用父任务和子项写入；完成或取消的任务可展开只读，与详情相同，避免额外修改破坏完成撤销的版本保护。
- 默认不构建隐藏子项，仅展开行在惰性列表中保持状态；稳定任务 ID 防止排序或数据刷新串用展开内容。高度和箭头过渡遵守减少动态效果设置。
- 使用 Flutter 的 [CheckboxListTile](https://api.flutter.dev/flutter/material/CheckboxListTile-class.html) 复用整行勾选与语义合并；展开按钮提供 [expanded 语义](https://api.flutter.dev/flutter/semantics/SemanticsProperties/expanded.html)。这与已采用的按需披露原则一致，不另造交互框架。

业务专项 10 项已通过，覆盖三入口的保存、计数、收起重开、父任务完成/撤销、详情双向同步和重载、失败重试、保存期间禁用以及无检查项任务的正常详情入口。记录为 `.local/todo-inline-focused-20261109.log`；最终集成、发布及浏览器证据随本轮交付在 README 顶部记录。

最终新增专项为 13 项，另覆盖 320px / 1.5 倍字体的长子项、减少动态效果、展开行滚出后返回与详情返回，以及存在展开行时的 300 项任务远距离定位。测试发现零时长 `AnimatedSize` 在减少动态效果和长内容布局下会触发重入布局错误，已改为该模式直接显示内容，普通模式再使用高度动画；没有放宽异常或定位断言。静态分析无问题，最终全量 **893 通过、1 跳过、0 失败**；日志为 `.local/todo-inline-analyze-final-20261109.log`、`.local/todo-inline-focused-final-20261109.log`、`.local/todo-inline-full-tests-final-20261109.log`。本轮未宣称设备性能提升或重新执行外部平台联调。
