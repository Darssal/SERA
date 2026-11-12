# SERA 路由动效与验收

## 实现范围

`lib/ui/core/sera_motion.dart` 集中定义页面身份、路由过渡、减少动态效果和真实模态样式。`lib/app.dart` 的账号、界面索引、通用页面和错误页均通过 `SeraMotion.page` 创建 `CustomTransitionPage`。不增加依赖，不改变业务重定向、URL、对象参数、网络请求或原有 go/push/replace/pop 的含义。

2026-10-31 的本轮代码已完成55页、25组页面行为及36处弹层/选择器的源码审查。最终4个专项文件共40项已随冻结源码全量执行通过，包含最后的键盘可见区域、原生卡片居中、barrier和State保持断言；证据为 `.local/feedback-flutter-test-release-live.log`。6个核心/测试文件当前SHA-256均匹配该次 `.local/feedback-release-source-manifest.json`。全量整体为389通过、1个独立live API用例失败，因此不宣称整版最终通过。专项自身不并发运行 Flutter/Dart/ADB/构建；设备与最终构建由界面集成对话执行。

## 过渡规则

| 场景 | 路由 | 进入 | 返回 |
| --- | --- | --- | --- |
| 主导航、日程同级切换 | 04、12、13、14、20、30 | 160ms 淡入，无位移 | 160ms |
| 详情、设置、辅助页 | 其余普通详情、列表与设置 | 220ms 淡入，从右侧18px进入 | 160ms，沿原位置反向退出 |
| 编辑、新增 | 09、16、19 | 240ms 淡入，从下方16px进入 | 160ms |
| 规划与引导步骤 | 01、02、03、05、06、08、10、11、22、23、52、55 | 200ms 淡入，从右侧12px进入 | 160ms |
| 生成、提交、错误与骨架状态 | 07、39、49、51 | 160ms 淡入，无位移 | 160ms |
| 完整页面形式的确认/语音设计 | 43、44、45、50 | 240ms、下方16px | 160ms |
| 账号、注册、验证、找回/重置 | 所有账号路由 | 即时呈现 | 即时呈现 |
| 真实 Dialog | screen 所有者传 `dialogStyle(context)` | 160ms Material原生过渡 | 160ms |
| 真实 BottomSheet | screen 所有者传 `sheetStyle(context)` | 240ms Material原生过渡 | 160ms |

页面采用 `easeOutCubic(animation.value)` 同一个值映射，进入中立即返回不会因为切换曲线发生位置跳变。模态使用统一 easeOutCubic / easeInCubic 样式。整屏位移为固定逻辑像素，避免不同屏宽导致不同幅度；路由与既有430px外层均裁剪，外侧保持原背景色。导航区域背景使用 `SeraColors.bg`，过渡透明处不露出默认白底。

43/44/45 仍是原设计的完整页面；真实删除、离开草稿、提醒等弹层继续使用原生 Dialog/BottomSheet，不把设计索引页改造成透明路由。

## 状态与业务保护

细节补充：app的同步/离线提示条使用 `SeraBannerTransition`，初始状态直接显示，后续出现/收起以160ms尺寸过渡；不交叉复制Navigator、不移动页面key、不重建下方表单。隐藏立即排除触控、读屏与焦点；减动态在动画中启用会立即完成，关闭设置不会倒退。

`SeraMotionScope`统一全部既有ExpansionTile（含SeraDisclosure）的轻量时长和减动态策略，不修改表单child/key。`SeraMotion.pickDate/pickTime`以原生DatePickerDialog/TimePickerDialog提供共享样式，保留中文本地化、输入模式、验证、取消与结果；`scrollDuration(context)`用于错误定位滚动的160ms/零动画。Picker只扩展显示范围以包含既有初始日期，不在打开/取消时自动改写日期。

TimePicker外层始终使用同一可滚动视口，正常高度保持原生卡片居中，短屏时允许整张卡片在键盘上方滚动；不缩小文字/触控区域、不清除viewInsets，键盘padding仍只由原生Dialog应用一次。这解决当前SDK输入模式最小目标196px与内部最小高度216px的冲突。外层采用deferToChild命中，弹窗外的空白仍交给ModalBarrier；键盘变化不会替换Picker State、输入、entry mode或校验错误。

同一进入或退出过渡中若 normal→reduced→normal，已经即时呈现/隐藏的状态锁存到该次Controller结束，防止重现退出页、重新位移或重新锁触控。下一段在正常设置下恢复轻量动画。

- 页面 key 同时使用 GoRouter 原始实例key、规范screen编号以及 taskId/eventId/draftId/goalId/sessionId。连续push相同URL保留独立栈实例，go/replace切换不同对象不会误用旧编辑器初始化状态。
- 新建16/19的实际预填参数以及05/06的new/prompt参与身份；已有task/event/draft忽略无效的新建预填。query顺序不影响身份。key诊断输出不包含prompt、notes、凭证或token值。
- Page类型始终为CustomTransitionPage，输入、自动保存、controller通知或无障碍开关不会创建UniqueKey，不会重新播放进入动画。
- `maintainState:true` 和恒定的动画child保留push栈下原页面的草稿、滚动、焦点、Timer。主导航仍使用原go行为，未承诺新增跨底栏的持久页面或滚动缓存。
- 动画帧只更新透明度与Transform；不调用请求、不增加业务延时、不复制提交页。进入或退出中的页面吸收触控，非current页面排除读屏节点；系统和浏览器返回仍可中断动画。
- 保留 `auth_shell.dart` 的账号树key和先销毁旧controller的边界，不在账号树之间保留outgoing child。账号页采用即时过渡。
- 退出动画中的Widget仍可能mounted；业务异步操作必须核对route/account/session/request所有权，详见共享 `motion-integration.md`。不要仅以mounted认定迟到回调仍可导航。

## 减少动态效果与键盘

读取MediaQuery.disableAnimations、accessibleNavigation，以及引擎独立的reduceMotion标志。过渡State通过WidgetsBindingObserver监听后者的变化。启用时无淡入、无位移、无动画触控等待；Dialog/BottomSheet样式返回 `AnimationStyle.noAnimation`。

如果已经安装的路由在进入后才开启减动态设置，其内部Navigator反向controller可能仍保留原时长。退出subtree会立即Offstage，停止绘制、读屏与触控命中，让底页立即可用；实际route资源仍按Navigator原生命周期清理。表单不因设置变化重建，不用Timer伪造动画结束。

键盘在转场开始时已经打开，则该次转场只淡入。位移决策在运行期间固定，键盘中途收起不会突然引入16/18px偏移。底栏和日程分段入口由UI所有者同步unfocus，不等待键盘动画；转场模块不主动夺走或清空表单焦点。

## 自动验收命令

以下全部由界面集成对话在 `sera_flutter` 目录串行运行。最终40项由15个模块行为、9个Picker/Scope/Banner细节、8个真实App导航及8个Picker视口边界组成，已在适配后、最后断言冻结后的源码上通过。视口边界含320×568/430×600各bottom inset 0/260/320六组，以及内外点击、键盘开关保持State两项；按钮完整Rect需在根MediaQuery计算的键盘上方，字段中心可见，正常430×700卡片中心为(215,362)±1px。

当前最终静态分析为 `.local/feedback-flutter-analyze-release.log` 的No issues found；菜单对象身份和phone路由/token边界的15项回归见 `.local/feedback-menu-phone-final.log`。旧384pass/1skip运行早于最后补强，不用它证明最终40项。较晚冻结全量的唯一失败为 `repository_test.dart: optional live Python SQLite API roundtrip, planning and undo`。首个seed初始化夹具问题修正后，后续 `.local/feedback-live-planning.log` 实际到达generatePlan并返回AI响应超时，仍无live规划/undo通过声明；由UI集成方继续处理，本专项不修改其仓储/服务配置。

```powershell
& 'D:/development/flutter/bin/dart.bat' format lib/app.dart lib/ui/core/sera_motion.dart test/sera_motion_test.dart test/sera_motion_details_test.dart test/motion_navigation_test.dart test/sera_motion_small_viewport_test.dart
& 'D:/development/flutter/bin/flutter.bat' analyze
& 'D:/development/flutter/bin/flutter.bat' test test/sera_motion_test.dart test/sera_motion_details_test.dart test/motion_navigation_test.dart test/sera_motion_small_viewport_test.dart
```

随后跑全量 `flutter test`，特别覆盖 planning_flow、planning_recovery、understanding_flow、task_suggestion_ui、persistent_ui_flows、first_use_routing、account_recovery、account_voice_ui。单测使用隔离内存数据，不能代替在线理解、账号切换或真实设备验收。

模块测试检查实际中间与结束帧、320/360/390/430和桌面居中裁剪、同URL独立push、实体替换、刷新不重播、表单/scroll/focus返回保持、连续go、动画中返回连续性、减动态动态开关、键盘仅淡入、账号即时页与重叠触控。App导航测试验证真实TaskEditor/EventEditor对象身份、预填变更、未提交不写入、既有对象不被预填覆盖、home输入返回保持及replace栈深度。

Picker测试使用产品实际中文本地化与 `seraTheme()`，保留99:99非法输入、错误提示、16:45正确返回、取消、2052年既有日期及零异常断言。曾遇到的测试默认英文/Ahem换行溢出，在匹配产品本地化后通过；未实际加载字体文件，不能称其为生产字体测量或唯一根因证明。短视口矩阵独立检查原生固定高度与软键盘约束，不放大测试视口、不缩小字号或触控区域，也不清除布局异常来取得通过。

## 浏览器与MuMu1人工场景

使用集成方自己的隔离QA账号、隔离服务及新浏览器标签，保留原8787/#/04未发送输入。宽度320、360、390、430分别检查；桌面1024或1280检查430居中与两侧裁剪。先完成单测和编译，再观察下列流程：

| 场景 | 操作与应观察结果 |
| --- | --- |
| 同级切换 | 今天→日程→目标→我的连续切换，重复点击当前项；底栏不出现方向误导、重复页或白屏，选定日期正确 |
| 详情/编辑 | 列表→任务A→编辑→返回，再进入任务B/日程B；内容、对象ID、标题和保存目标正确，不携带A表单 |
| 表单保持 | 输入合成草稿，滚动到中部，打开辅助页后返回；输入/scroll/focus符合原业务行为，无新增提交 |
| 快速打断 | 进入详情40–80ms后系统返回，连续切换，动画中浏览器后退/前进；不留透明层、不锁点击、不被迟到请求夺回 |
| 规划 | 05显式理解→06→07→08→09→10→51→11，另测失败39/重试、草稿离开44；无重复请求、提交、草稿或结果页 |
| 键盘 | 320/360宽编辑时打开软键盘，再导航/返回/取消；固定按钮可达、无溢出、键盘收起不跳位置 |
| 弹层 | 删除、离开草稿、提醒、时间块、账号确认；打开/取消/确认/动画中返回各一次，不重复确认，退出后controller不被提前销毁 |
| 减动态 | Android“移除动画”或浏览器prefers-reduced-motion，分别在导航前和页进入后开启，再返回；无位移/淡入/不可见触控屏障 |
| 账号边界 | 合成QA账号A→退出→B；第一可见帧和浏览器回退均不出现A的导出/任务/草稿，敏感邮件token不进入证据 |
| 深链接 | 直接进入/09、/16、/18、/21含对象参数的URL；刷新、后退、前进后对象一致，缺失对象走原错误入口 |

## 录屏与性能采样

本轮已取得一次MuMu1 profile实测，原始数据位于 `build/feedback-profile-response.json`，独立复算位于 `.local/coordination/20261031-feedback/motion-frame-review.json`。环境为360×640逻辑像素、DPR 3、约60Hz、benchmarkLive帧策略、内存合成数据、1轮预热/每组5轮。两组都是详情/编辑/偏好等fixture过渡的聚合样本，没有鉴权、网络、原生权限或真实业务写入；返回今天且fixtureWrites=0。

| 聚合样本 | 帧数 | UI p95 / max | Raster p95 / max | Raster超实际约16.667ms预算 |
| --- | --- | --- | --- | --- |
| 正常进入与返回 | 724 | 1.264 / 8.277ms | 18.780 / 21.829ms | 291帧，40.19% |
| 进入60ms后中断返回 | 449 | 1.111 / 5.093ms | 18.737 / 22.391ms | 164帧，36.53% |

按原始微秒数组、nearest-rank方法复算；UI超预算均为0。SDK摘要使用固定16ms预算，其417/724和225/449计数与实际刷新率预算不同，必须分开保留。这次流程测试通过并不等于稳定60fps；当前没有同节奏视觉旁路对照，不能把Raster超时全部归因于动效，也不能宣称性能提升。后续对照应保持相同Controller时长、栈和360/60ms节奏，仅在benchmark中固定opacity1/offset0，交替采样；零时长reduced-motion会改变帧数和生命周期，不作直接baseline。下方为完整采样建议，不能把建议的20轮写成这次实际已执行。

只允许MuMu安卓设备-1，ADB `127.0.0.1:16416`。设备、Flutter、发布构建及主服务均由UI集成对话操作；专项不会并发启动。使用独立 `com.sera.sera_flutter.qa` 包，既有Gradle条件是非release且环境变量 `SERA_ANDROID_QA=1`。不要卸载、清空或覆盖正式包。

在集成方已启动隔离服务并配置设备网络后，可使用自己的API地址：

```powershell
$env:SERA_ANDROID_QA = '1'
# $motionQaApi须由集成方填写实际隔离服务地址，不使用用户真实工作空间。
& 'D:/development/flutter/bin/flutter.bat' run -d '127.0.0.1:16416' --profile --no-uninstall-first --dart-define="API_BASE_URL=$motionQaApi"
```

先记录设备/API32、MuMu分辨率/密度、显示刷新率、宿主负载、Flutter/Dart版本、版本号、源码文件hash、渲染后端、profile/release模式与数据集。独立fixture只能证明该fixture的路由渲染，需另做真实业务流程；不能由fixture推导在线请求或生产数据表现。

录屏可在单独终端由集成方执行（先确认目标设备，再开始30秒场景）：

```powershell
& 'D:/development/android-sdk/platform-tools/adb.exe' -s '127.0.0.1:16416' shell screenrecord --time-limit 30 /sdcard/sera-motion-qa.mp4
& 'D:/development/android-sdk/platform-tools/adb.exe' -s '127.0.0.1:16416' pull /sdcard/sera-motion-qa.mp4 .local/coordination/20261031-feedback/sera-motion-qa.mp4
```

录制主导航→详情前进/返回→编辑→规划步骤→弹层；另录减动态与键盘。只使用合成QA文本，不采集用户原输入、邮件token或真实账号数据。

性能取证使用profile模式的DevTools Performance：预热每组5次，清空时间线，在不录屏时采集20次同一过渡，分别保存详情、主导航、规划步骤和弹层的trace/帧表。记录每组实际UI/Raster帧时长p50/p95/max、超过该设备刷新预算的帧数/总帧数，以及shader/资源初次加载情况；保留原始trace和环境。60Hz的16.67ms仅是对应帧预算，不是未经测量的保证。录屏会额外占用资源，须与无录屏帧采样分开说明。

Web使用release构建，在独立标签DevTools Performance录制同样的20次操作，记录浏览器/版本、硬件加速、视口/DPR与CPU节流设置，保存trace；静态截图只用于检查中间/最终布局。比较前后应使用相同设备、模式、数据集和操作，若没有同条件旧版样本，只报告新版实测，不宣称提升百分比。

最终证据写入本轮QA文档和motion-ready/integration状态：测试命令、退出码、日志路径、录屏路径、trace路径、设备与模式、实际观察、未覆盖项。任何失败记录到integration-issues.md后交还文件所有者修复。禁止使用debug观感或录屏平滑推断稳定60fps。

## API依据

- [CustomTransitionPage](https://pub.dev/documentation/go_router/latest/go_router/CustomTransitionPage-class.html)
- [Flutter disableAnimations](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html)
- 精确参数和生命周期同时核对本机Flutter3.47.2及go_router18.1.2源码；无需拉取新依赖。
