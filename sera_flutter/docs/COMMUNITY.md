# 社区：页面、权限与课程演示

社区是用户明确要求的课设互动模块，成为“今日 / 计划 / 日程 / 社区”第四栏。它服务官方活动、动态、用户日常分享和使用反馈，不自动读取或公开个人任务、目标、日历和专注记录。延续 Flutter、Provider、go_router、Dio、账号和 FastAPI/SQLite；`image_picker 1.2.4` 处理系统选图，后端使用 `Pillow 13.0.0` 校验和规范图片。按用户明确提出的左右独立排列需求，采用精确锁定的 `flutter_staggered_grid_view 0.7.0` 实现惰性瀑布流，避免维护额外的自定义渲染器。

## 页面与操作

| 页面 | 地址 | 主要操作 |
| --- | --- | --- |
| 信息流 | `/#/community` | 最新／使用反馈／官方分类、双列图文卡片、阅读、点赞、进入详情、发布 |
| 帖子／活动 | `/#/community/post/<id>` | 图片横滑与全屏查看、点赞、评论、评论分页、活动参与／取消、自有内容删除 |
| 发布 | `/#/community/compose` | 日常动态／使用反馈、最多三张图片；有对应权限时发布官方动态或活动 |
| 申请／管理 | `/#/community/manage` | 普通用户申请；官方添加管理员、逐人调整权限和审核 |

游客可阅读，写入时登录后返回原社区页面。普通动态正文必填、标题可选；活动还需标题和日期时间，地点可选。发布失败保留输入，相同请求重试复用操作编号；保存成功才显示到信息流。离开未发布表单会提示。社区是多人共享内容，离线时明确报错，保留表单输入，不显示虚构的离线发布成功。

信息流按需构建并分页，评论有独立分页。点赞与参与由服务端真实计数，不虚构热度。用户要求的演示账号和帖子明确标注模拟，评论也通过这些账号实际保存。普通用户可以删除自己内容；具备对应管理权限的管理员可管理他人帖子或评论。删除前说明对象和后果，不把个人任务的撤销语义套用到共享帖子。

双列卡片借鉴参考图的封面、标题、头像昵称与点赞位置，保留 SERA 的浅色与绿色。每张卡片根据实际封面比例和标题行数自然增高，下一张接续较短的一栏；单一滚动容器保持分页、刷新、稳定对象 ID 和可见项按需构建。照片封面预览宽高比限制为 0.65–1.25，详情在同一图片区内横滑，完整图片保持比例；纯文字用真实标题或正文首段形成大字封面，不补虚构照片。头像采用用户 ID 对应的稳定颜色和昵称首字，官方所有者使用品牌头像，授权管理员发布官方内容时仍显示自己的作者头像。详情使用作者栏、正文、真实日期和扁平评论列表，底部保留评论输入与实际点赞。当前没有新增头像上传、视频、搜索、热榜、私信或无后端能力的互动按钮。

下拉刷新读取最新内容，向上浏览到末尾自动加载下一页；已到底时上拉更新已浏览范围，失败保留列表并允许重试。按钮操作不因滚动重复触发。普通动态可选择“使用反馈”，通过自由文字、截图和评论讨论，不增加工单编号、虚构处理进度或额外审批流程。

## 图片发布与保存

发布表单选择 JPEG、PNG 或静态 WebP，最多三张、每张上传不超过 8 MiB。选图取消保留文字和已选照片；每张独立显示上传结果，可删除或只重试失败项。所有选中图片上传成功后才能发布，失败保留输入，已成功图片不重复上传。发布成功前图片仅本人可读；表单退出后没有被帖子引用的上传在 24 小时后由后续上传顺带清理。

后端核对真实格式与 MIME，拒绝损坏文件、多帧及超过 1600 万像素的图片；校正 EXIF 方向并去除元数据，以正确比例缩小到最长边 1600px。透明内容保存 PNG，其余规范为 JPEG。图片二进制独立保存到 `community_media`，列表仅查询元数据；发布绑定与帖子写入同一事务。跨账号引用、过期图片、重复提交、撤销会话和删除重试由服务端校验，删除帖子或注销账号会一并清理附件。

Android 系统选择器导致应用被回收时，仅允许在同一服务器、账号和登录状态下恢复上次选图；恢复后仍需检查和明确发布，不会自动分享。该恢复保存轻量归属标记，不持久化令牌或完整帖子草稿。实际设备结果与自动化模拟通道分别记录。

## 官方与管理员

官方所有者由服务端 `SERA_COMMUNITY_OFFICIAL_USER_IDS` 用户 ID 列表配置，可发布、管理、审核和分配权限。公开注册不能申请“官方身份”，客户端传递的标志不能提升权限。

| 独立权限 | 允许的行为 |
| --- | --- |
| `publishOfficial` | 发布带官方标识的动态 |
| `publishActivity` | 发布官方活动，与官方动态权限分别分配 |
| `moderatePosts` | 删除他人帖子 |
| `moderateComments` | 删除他人评论 |

只有官方所有者能添加、修改、移除管理员或审核申请，管理员不能给自己或他人升权。四项权限逐人保存，每个请求重新校验；撤权后旧页面的按钮不能绕过服务器限制。“官方”标识代表授权发布的官方内容；管理员个人动态和评论显示“社区管理员”，不会自动冒充官方动态。

普通用户提交申请理由，官方在同一管理页审核并设置权限。普通用户只读取自己的申请状态，不能读取其他申请或管理员管理数据；添加管理员使用准确用户名或邮箱，不提供全站用户搜索或邮箱列表。管理员被移除后可重新申请。账号注销通过外键删除其社区内容、互动、权限和申请。

## 新建官方课程账号与启动

本机已按用户要求新建“序日官方”。用户名、随机密码及对应数据库信息只保存在 `.local/community-private/official-account.json`，所有者配置为同目录 `official.env`。课程账号邮箱 `official@sera.example` 是保留示例地址，没有真实收件箱，未标记邮箱验证成功；使用用户名登录。正式部署需配置自己可接收邮件的账号。

在新的部署中，可用以下本地运维命令创建新的官方账号；已有用户名／邮箱冲突会失败，不覆盖原账号。命令先备份数据库，不回显密码、不发邮件、不跳过邮箱验证。同一私有目录再次执行保留原凭据。

```powershell
backend/.venv/Scripts/python.exe scripts/provision-community-official.py
./scripts/start-fullstack.ps1 -SkipBuild -AiModel zai-org/GLM-5.3-Flash -EnvFile @('.local/smtp.env','.local/sms-auth.env','.local/public-lookup-20261031/public-web.env','.local/community-private/official.env')
```

环境文件须已经存在；其他部署只传实际需要的文件。Compose 使用 `deploy/.env` 中同名变量。凭据、所有者配置和备份都在私有目录，源码打包排除 `.local`，Web 和 APK 不包含账号密码或所有者名单。

## 课程演示顺序

1. 未登录打开社区，查看官方欢迎动态和明确标注的课设演示活动。
2. 普通账号登录，发布日常，进入详情点赞、发表评论，刷新后核对持久结果；参与活动后再取消。
3. 普通账号进入“申请管理社区”，填写理由提交，看到待审核状态。
4. 官方账号进入“社区管理”，批准该申请，仅选择需要的权限；或用准确用户名添加已有账号。
5. 被授权账号重新读取社区，展示管理员标识及对应发布／管理操作；验证未授予操作会被拒绝。
6. 官方修改权限或移除管理员，再以原账号重试操作，确认撤权生效。测试账号与测试帖子使用隔离数据库，不删除用户已有内容。

## 接口

所有路径前缀为 `/api/v1/community`。读取结果含当前会话 `viewer`，返回 `Cache-Control: no-store`；沿用现有 Cookie/CSRF 与 Bearer 会话。

| 方法与路径 | 用途 |
| --- | --- |
| `GET /posts` | `filter=all|official|feedback`、稳定游标、每页 20 条；含图片元数据 |
| `GET /posts/{id}` | 帖子与评论页，支持 `commentCursor` |
| `POST /posts` | 带 `requestId` 发布；正文 1–5000、标题最长 120；`category=daily|feedback`、`mediaIds` 最多三项 |
| `POST /media` | 带 `Idempotency-Key` 的图片原始二进制；返回 ID、尺寸、格式、大小和读取 URL |
| `GET /media/{id}` | 已发布图片可读；未发布图片只限当前所有者，其他请求返回 404 |
| `POST /posts/{id}/comments` | 带 `requestId` 评论，1–1000 字 |
| `PUT /posts/{id}/like` | `{liked:bool}`，重复设置不累计 |
| `PUT /posts/{id}/join` | `{joined:bool}`，仅活动 |
| `DELETE /posts/{id}`、`DELETE /comments/{id}` | 自有内容或对应管理权限 |
| `GET /management` | 当前用户管理能力与可访问的数据 |
| `POST /admin-applications` | `{requestId,reason}`，理由 1–500 字 |
| `POST /admins` | `{identifier,permissions}`，官方添加已有账号 |
| `PUT /admins/{userId}` | `{permissions}`，四项布尔值完整提交 |
| `DELETE /admins/{userId}` | 官方撤销管理员身份与权限 |
| `PUT /admin-applications/{id}` | `approved|rejected`，批准时给定权限 |

社区使用独立附加表，不修改 workspace schemaVersion 2。事务同时检查当前会话、对象权限和幂等记录，删除后重试原发布不会复活内容。账号或会话变化会清空客户端帖子标志、管理数据和重试状态，迟到请求不得覆盖新账号界面。

## 设计与工程依据

- [Flutter NavigationBar](https://api.flutter.dev/flutter/material/NavigationBar-class.html)：主导航用于稳定切换主要目的地；社区成为第四栏，发布和管理仍在社区内完成。
- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)：按最小权限、默认拒绝和逐请求校验实现四项能力；不能仅依赖隐藏按钮。
- [NN/G 极简设计](https://www.nngroup.com/articles/aesthetic-minimalist-design/)：仅保留阅读、分享和管理的直接操作，不添加榜单、搜索、私信、积分或空媒体按钮。
- [Flutter RefreshIndicator](https://api.flutter.dev/flutter/material/RefreshIndicator-class.html)、[ScrollNotification](https://api.flutter.dev/flutter/widgets/ScrollNotification-class.html)：刷新与分页复用滚动手势，网络状态修改安排在布局完成后，避免滚动中重复请求。
- [Flutter CircleAvatar](https://api.flutter.dev/flutter/material/CircleAvatar-class.html)：用户无头像时使用稳定颜色与首字，官方作者身份与官方内容标识分别表达。
- [image_picker](https://pub.dev/packages/image_picker)：复用 Android 系统照片选择器及 Web 文件选择；处理 Android `retrieveLostData`，请求图片而非完整元数据。
- [Pillow 发布版本](https://pypi.org/project/pillow/)、[ImageOps.exif_transpose](https://pillow.readthedocs.io/en/stable/reference/ImageOps.html#PIL.ImageOps.exif_transpose)、[图片解码和校验](https://pillow.readthedocs.io/en/stable/reference/Image.html)：服务端检查像素和实际格式，校正方向后重新编码，避免直接公开任意上传文件。

## 2.1.4 多图轮播与全屏查看（2026-11-09）

版本 **2.1.4+31**。根据用户提供的多图详情与大图参考，将多张图片从纵向堆叠改为单个左右轮播图片区，让正文和评论更快可达。图片区以下使用 6px 圆点、12px 中心间距；紧凑圆点共用较大的点击区域，按最近圆点选择，读屏提供当前张数及前后切换动作。多图帖子的信息流封面保留张数提示，单图不显示分页圆点。SERA 页面继续使用浅色与绿色，深色仅用于全屏看图。

点击当前图进入深色全屏，顶部保留关闭 X 和“当前张数／总张数”；左右滑动切图，双击或捏合缩放，放大时拖动平移图片。关闭或系统返回后恢复详情原位置、未发送评论和所选图片。账号、帖子或媒体版本变化会停止显示旧图，并精确移除对应图览路由；迟到返回不能影响新账号或新页面。加载失败仍可单独重试，不用占位图冒充成功。

复用 Flutter 自带 [PageView.builder](https://api.flutter.dev/flutter/widgets/PageView-class.html) 按需创建页面与 `PageController` 管理当前图片；使用 [InteractiveViewer](https://api.flutter.dev/flutter/widgets/InteractiveViewer-class.html) 处理平移和缩放。图片用 `BoxFit.contain` 保持比例，不裁切正文图片；页码仅属于当前账号、帖子和媒体版本。此次没有新增依赖、公开 API 或数据库变更，也没有新增关注、收藏、分享等无后端动作。

追加自然比例反馈：信息流照片不再压入 0.65–1.25 的相近封面，普通照片以原始宽高比设置高度；列宽保持一致，各列按自身卡片高度接续，仅极端条幅使用 0.25–4 保护、无效尺寸回退。原三条多图模拟帖首图都是 1122×1402，另新增一条横图首封面《晚霞刚好，不赶时间》（1448×1086，第二张 1122×1402），通过既有模拟账号和实际 API 写入。现有模拟帖 16 条、7 张不同的 AI 示意素材、18 条原模拟评论；只有新增的一个帖子和两份上传媒体，旧帖子／媒体、工作区、评论、点赞、报名、权限和同步／推送表对比保持一致，第二次导入 0 新增。自然封面与模拟回执分别见 `natural-covers-final-390.jpg`／`natural-covers-final-320.jpg` 及 `.local/community-demo-natural-20261109/verification.json`。

最终验证：静态分析无问题；Flutter **977 通过、1 项原有可选 HTTP 测试跳过、0 失败**，含社区专项 **80 项**、图览行为 **13 项**。覆盖真实触控／鼠标拖动、紧凑圆点点击与语义增减、全屏当前张数、双击放大后平移及还原翻页、关闭后输入与滚动保留、加载重试、账号变化、媒体替换和新页面之下的精确图览移除。浏览器实际检查 320/390px、鼠标横拖、双击／平移／还原、X／Esc 关闭、页码和未发送输入保留，控制台无 error/warn；检查文字已清除，未发布新帖子、评论或点赞。捏合、真实读屏与 Android 系统能力未计入浏览器实测。

首轮浏览器 QA 发现并修正圆点间距／对比度及鼠标手势冲突。Flutter 的鼠标缩放识别器可能先于 PageView 接受拖动；仅在未放大且实际接管鼠标的路径中，将位移／速度交给 PageView 原生 Drag 和分页物理，保持触控与放大后平移。鼠标专项先实际复现失败，再随修复通过；未改成键盘操作冒充拖动验证。浏览器历史后退遵循原 go_router 页面历史返回社区；关闭 X／Esc 保留详情，系统返回由 Widget 回调测试，三者分别记录。

release Web、签名 APK/AAB 构建完成；APK v2 签名、版本 2.1.4／31、AAB bundletool 与 JAR 签名校验通过。Web 候选 `.local/web-community-natural-covers-20261109`，74 项静态资源共 **42,020,722 字节**；相较 2.1.3 增加 33,623 字节，升级复用 71 项／36,147,866 字节，下载 3 项／5,872,856 字节。平台与真实资源升级 **41 项**、离线清单 **3 项**通过；缓存数据来自 Node 内存测试框架，不是浏览器启动或设备性能测量。预览主程序摘要 `2f87ab0fe7c57a2f38f6ce5b6f79fc2260189f4658916872f79d9696cd37256b`，缓存版本 `54b962ac29d35a476c54a8cf6c2e73a1d0751a4b5d9d48b663bc53c2ced59295`。

交付在 `.local/releases/sera-2.1.4+31/`，上一正式版回退 `.local/web-before-community-gallery-213`；中间构建单独保留。最终执行日志 `.local/community-gallery-analyze-final-20261109.log`、`community-gallery-unit-final-20261109.log`、`community-gallery-focused-final-20261109.log`、`community-gallery-flutter-final-20261109.log`、`community-gallery-web-final-20261109.log`、`community-gallery-platform-20261109.log`、`community-gallery-manifest-20261109.log`、`community-gallery-apk-build-final-20261109.log` 与 `community-gallery-aab-build-final-20261109.log`。早期测试路径／模块导入命令错误和鼠标复现失败的原日志保留，不计为最终产品通过。截图与对照结论见 `design-qa.md`。MuMu 安卓设备-1 本轮未运行；没有设备安装或实际相册／捏合验收，没有常驻额外测试服务。

## 2.1.0 基线验证（2026-11-09）

版本为 2.1.0+27，Flutter 3.47.2 / Dart 3.13.2，Windows、项目 Python 3.11 虚拟环境、Codex 内置浏览器。

| 验证 | 实际结果 |
| --- | --- |
| Dart 静态分析 | `flutter analyze --no-pub lib test integration_test`，无问题 |
| Flutter 全量 | 922 通过、1 项原有可选 HTTP 测试跳过；含社区控制器 14、界面 11、导航与恢复 4 项 |
| 后端全量 | 443 项中 441 通过，2 项真实 ASR 模型推理本轮跳过；含社区 26、OpenAPI 6 项 |
| 系统脚本／打包检查 | 25 项通过，含官方账号备份、重跑保留、无邮箱伪验证和私有配置隔离 |
| Service Worker／PCM | 40 项通过 |
| 离线资源清单 | 3 项通过 |
| Web 构建 | release JS 构建成功，离线清单 74 项、约 39.94 MiB |
| Android 构建 | 签名 release APK / AAB 成功，APK v2 签名验证与 bundletool AAB 校验通过，版本 2.1.0、versionCode 27 |

浏览器实际走通：游客阅读 → 官方内容筛选 → 活动详情 → 报名入口登录 → 新官方账号登录后返回原活动 → 报名人数 0→1→取消回到 0 → 刷新保留详情和官方身份 → 官方管理页 → 权限编辑中只选“管理帖子”时其余三项保持关闭 → 取消不授权 → 活动表单输入与日期／时间选择 → 离开提示 → 继续编辑保留输入 → 放弃本次测试草稿返回信息流。未向其他账号授予真实权限，也未发布测试帖子或评论；写入、申请、审批和撤权由隔离数据库的真实 API / Widget 测试验证。

实际浏览器检查覆盖 1280px 桌面居中、320px 与 390px 手机视口；原 55 页自动化继续覆盖 320/360/390/430px，社区测试包含 320px、1.5 倍字体。控制台无 error/warn，截图位于 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-community/`，包括 `feed-390.jpg`、`feed-320.jpg`、`activity-390.jpg`、`permissions-390.jpg` 和 `compose-390.jpg`。

最终日志为 `.local/community-analyze-final-20261109.log`、`.local/community-flutter-final-20261109.log`、`.local/community-backend-tests-20261109.log`、`.local/community-platform-tests-20261109.log`、`.local/community-tools-final-20261109.log` 和 `.local/community-offline-manifest-tests-20261109.log`。界面复制文案调整后社区后端 26 项再次通过。全后端第一次误用系统 Python 缺依赖的记录独立保留，最终通过结果来自项目 `.venv`。

Web 主程序 SHA-256 为 `fe18f8445fb952dab57013cb97eb1322963d0bb924ae618f56a550e236c58d8e`，缓存版本为 `8e1a745b9cd2`。该次本机服务使用 `.local/web-simplicity-release-20261108`，更新前 2.0.24 完整保存在 `.local/web-before-community-2024`；数据库在创建官方账号前已备份。API、worker 和 ASR 按原数据库与私有配置重新启动，未清空个人记录。该基线 APK/AAB 保存在 `.local/releases/sera-2.1.0+27/`；后续图文功能以 2.1.1 记录为准。

## 2.1.1 图文社区验证（2026-11-09）

最终版本为 **2.1.1+28**。双列信息流、日常／使用反馈、稳定头像、真实图片发布、上拉分页及触底更新已接通。回归修复 `AlwaysScrollableScrollPhysics` 未继承平台规则导致的越界停留；在刷新返回但手指未松开时仍核对原滚动位置。旧 Cookie 失效时，社区公开 GET 按游客读取，不写 Cookie；所有写入、个人待发布图片及管理接口仍受原鉴权和 CSRF 保护。

| 验证 | 实际结果 |
| --- | --- |
| Flutter 全量 | **947 通过、1 项原有可选 HTTP 测试跳过、0 失败**；含社区 UI 25、控制器／仓储 21、选图恢复 4、导航 4 项 |
| 后端全量 | **467 项，465 通过、2 项真实 ASR 推理本轮跳过**；含社区 48、OpenAPI 8 项 |
| 平台与真实升级资源 | **41 通过**；包括旧版到新版的真实构建资源缓存升级 |
| 官方账号／环境／打包脚本 | **25 通过** |
| 离线资源清单 | **3 通过** |
| Web | release JS 构建成功，74 项静态资源，41,974,812 字节 |
| Android | 签名 APK/AAB 构建成功；APK v2 签名有效、包名 `com.sera.sera_flutter`、版本 2.1.1／28；bundletool 校验和 AAB JAR 签名验证通过 |

浏览器在独立 `localhost:18789` 测试环境实际选择两个本机合成 PNG → 上传 → 发布使用反馈 → 详情展示两张正确比例图片 → 刷新恢复 → 点赞 0→1 → 评论保存并显示同作者头像 → 返回双列信息流 → 320/390px 检查 → 向上浏览自动加载第二页 → 末页更新已浏览两页 → 筛选使用反馈。后端再次读取确认该帖子含两张图片，尺寸为 720×960、960×720，分类与作者正确。这里的账号、图片及帖子均为隔离测试数据，没有添加到用户主社区。浏览器控制台无 error/warn。自动化另覆盖图片选择取消、失败单张重试、三张上限、过期重传、账号变化和 Android 恢复；这些模拟通道结果不等于实际 Android 相册测试。

主预览已更新为同 SHA 的新版文件，保留原官方登录状态和两条原有官方内容。实际检查确认新的分类、双列文字封面、官方头像与四栏导航；用户记录未清空。截图位于 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-community/`：`photo-feed-390.jpg`、`photo-feed-320.jpg`、`photo-compose-390.jpg`、`photo-detail-390.jpg` 为隔离图文测试，`community-main-211-390.jpg` 为主社区。

本机 Web 产物为 `.local/web-community-feedback-20261109`，服务继续使用 `.local/web-simplicity-release-20261108`。完整 2.1.0 回退目录为 `.local/web-before-community-feedback-210`；数据库迁移前及最后一次修复重启前分别备份于 `.local/community-private/`。新版主程序 SHA-256：`358510a31a891757cb3b92ce775865ce85bbffeaf85565c69bf634cf73e66663`，缓存版本 `67cfc640b2ac`。真实构建升级测试复用 70 项／34,781,464 字节，下载 4 项／7,193,348 字节，未变中文字体与渲染文件不重新下载；耗时和内存来自 Node 内存缓存测试，不能作为浏览器启动或 Android profile 性能。

实际尝试启动 **MuMu 安卓设备-1** 后，设备曾短暂报告启动完成，随后自行退出。`127.0.0.1:16416` ADB 连接被拒绝，MuMu 管理工具返回“vm not running”，因此本版没有安装到该设备，真实相册、权限和系统能力未验收。已关闭本轮启动的残留 MuMu 进程，没有修改模拟器数据；构建结束停止 Gradle 守护进程，临时图文测试服务不常驻。APK 编译、自动化选图恢复与真实设备结果分别记录。

执行日志为 `.local/community-photo-flutter-final-20261109.log`、`community-photo-backend-final-20261109.log`、`community-photo-analyze-release-20261109.log`、`community-photo-platform-build-20261109.log`、`community-photo-tools-20261109.log`、`community-photo-manifest-tests-20261109.log`、`community-photo-web-build-20261109.log`、`community-photo-apk-build-20261109.log`、`community-photo-aab-build-20261109.log`。首轮两项 UI 失败、镜像缺包及首次 AAB 校验命令参数错误分别保留旧日志，最终结果以修复后的全量和 `community-photo-aab-validation-final-20261109.log` 为准。

依赖安装改用官方 `https://pub.dev`，原有依赖版本全部保留，仅新增图片选择所需依赖。若本机配置的镜像缺少 `image_picker_ios`，在当前 PowerShell 窗口执行 `$env:PUB_HOSTED_URL='https://pub.dev'` 后再执行 setup／build；无需更改系统包源或降级图片插件。

## 2.1.3 瀑布流、大字封面与评论（2026-11-09）

最终版本 **2.1.3+30**。依据用户补充的三张参考，使用左右独立接续的双列瀑布流；作者栏、正文与评论采用 SERA 浅色和绿色，无需复制参考应用的黑色主题。封面之外不再包整张圆角面板，标题和头像外置；纯文字以真实标题或正文首段构成低饱和纸色大字封面。照片按真实比例决定预览高度，详情保持原比例；文字详情保留完整标题，长标题和大字体可自然增高，正文仍为可选择全文。

详情作者移到顶部，评论为头像、昵称、正文、真实时间的平铺列表，底部只有评论输入／发送和唯一帖子点赞；大字体时分行给输入留空间。实际活动报名与权限控制的删除保留。没有为了仿照截图增加未接通的关注、收藏、分享、评论点赞或回复按钮。

新增直接依赖 `flutter_staggered_grid_view: 0.7.0`，官方 pub.dev 获取并锁定，MIT，仅依赖 Flutter。真实需求是单一滚动容器内按内容高度错列；固定 SliverGrid 无法按子项高度排布，维护自定义渲染器会增加测试和升级成本。选择 `SliverMasonryGrid` 的惰性 delegate 与稳定 key，单次建立帖子索引，避免每次回调扫描列表。依据：[作者布局说明](https://pub.dev/packages/flutter_staggered_grid_view/versions/0.7.0)、[SliverMasonryGrid API](https://pub.dev/documentation/flutter_staggered_grid_view/latest/flutter_staggered_grid_view/SliverMasonryGrid-class.html)。不改变 REST、数据库版本或个人数据格式。

按用户要求，四个昵称带 `_模拟` 的独立账号发布 12 帖（9 条日常、3 条反馈），其中 3 帖含 AI 生成示意照片；正文说明演示身份与图片来源。另实际提交 18 条相互交流的评论，覆盖 12 帖，内容围绕拆小任务、休息、日期核对、日常和公开范围。导入脚本先备份，通过真实 API 保存并读回；第二次执行 0 新增、18 保留，不恢复用户已删除的演示评论。SQLite 对比确认旧帖子、旧评论、个人工作区、点赞、报名及管理员权限未修改。账号密码、回执和原始生成图只在 `.local/community-demo-20261109/`，不放进源码包。

| 本轮实际检查 | 结果与范围 |
| --- | --- |
| 静态分析 | `flutter analyze --no-pub lib test integration_test` 无问题 |
| Flutter 全量 | **963 通过、1 项原有可选 HTTP 测试跳过、0 失败**；包括社区 UI 33、控制器／仓储 21、导航 4、瀑布流 5、详情布局 3 项 |
| 实际行为 | 左右异高和短列接续、比例上下界、独立点赞与详情路由；320px 1.5/2 倍字体、长标题完整排版；键盘、评论失败输入保留及幂等重试、删除权限／取消／确认；300/1000 条列表每一窗真实已构建卡片 <20，末项可达 |
| Web 平台 | **41 通过**，包括真实构建资源字节的缓存升级；离线清单 **3 通过** |
| Web 发布 | release 构建成功，74 项静态资源共 41,987,099 字节；比 2.1.2 中间版增加 9,919 字节；升级复用 70 项／34,781,464 字节，下载 4 项／7,205,635 字节 |
| 浏览器 | 320/390px 实查两栏错列、图片与大字封面详情、扁平评论、底部输入、返回；真实点赞 0→1→0 并确认列表同步，未提交检查用输入、未删除原内容；控制台检查单独记录 |
| Android | release APK/AAB 构建成功；APK v2 签名、版本 2.1.3／30、AAB bundletool 与 JAR 签名验证通过（交付回执 `android-verification.json`）。ADB 当前无已连接设备，MuMu 安卓设备-1 未运行；不算设备安装、系统相册或系统能力实测 |
| 后端范围 | 本轮未改后端代码和契约；模拟评论通过当前真实 API 保存。既有 2.1.1 后端 465 通过／2 项 ASR 推理跳过属于既有基线，不计为本轮重新执行 |

浏览器截图位于 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-community/`：`masonry-after-390.jpg`、`masonry-after-320.jpg`、`detail-after-390.jpg`、`text-cover-detail-390.jpg`、`comments-after-390.jpg`、`comments-after-320.jpg`。已将源图和实际截图放在同一次视觉输入中比较，主题、内容和功能取舍见仓库 `design-qa.md`；不宣称像素克隆。Web 真实预览为 `http://127.0.0.1:8787/#/community`，原会话与数据库保留；回退版本 `.local/web-before-community-masonry-212`，发布与缓存回执在 `.local/community-runtime-20261109/`。

最终日志：`.local/community-masonry-analyze-final-20261109.log`、`.local/community-masonry-flutter-final-20261109.log`、`.local/community-masonry-platform-20261109.log`、`.local/community-masonry-manifest-20261109.log`、`.local/community-masonry-web-build-20261109.log`、`.local/community-masonry-apk-build-20261109.log` 和 `.local/community-masonry-aab-build-20261109.log`。早期命令误写不存在的文件名，以及图片失败状态中心重试按钮、TextButton.icon 子类型、固定网格末项估算和懒构建后的可点击区域导致的旧测试假设，均保留原日志；最终回归通过实际手势、真实路由和业务数据断言，未跳过这些用例。
