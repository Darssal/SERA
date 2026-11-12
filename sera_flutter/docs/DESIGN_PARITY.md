# 设计基准、Flutter 页面与差异说明

## 基准与实现方式

本工程以已确认的 `h5-prototype` 为视觉和核心操作基准，参考原始 `screens` 设计导出、`h5-slice/layouts` 布局记录与切图资源。页面全部使用原生 Flutter Widget 重新组织，文字、表单、按钮、卡片、日历与弹窗可交互；没有把 H5 或整张设计图嵌入应用。

保留 01–55 设计编号。Flutter 同时接受简短路径 `/08` 与完整路径 `/08-plan`，Web 地址默认为 `/#/08`。详情页通过 `taskId`、`eventId`、`draftId`、`goalId` 关联真实工作区数据；缺少对应记录时显示创建或返回入口。`/#/gallery` 可以浏览全部设计页面／状态。

## 设计规范对应

| 参数 | 设计基准 | Flutter 对应 |
| --- | --- | --- |
| 页面背景 | `#F7F8FA` | `SeraColors.bg` |
| 内容卡片 | `#FFFFFF` | `SeraCard` / `surface` |
| 主文字／次文字 | `#182321` / `#65736D` | `ink` / `muted` |
| 主品牌色／浅色底 | `#176B59` / `#E7F2EC` | `brand` / `mint` |
| 警示文字／浅底 | `#946018` / `#FCF3DF` | `amber` / `amberBg` |
| 危险操作文字／浅底 | `#B3433C` / `#FBECE9` | `red` / `redBg` |
| 分割线 | `#E2E7E5` | `line` |
| 字体 | Noto Sans SC，别名 SeraSans | 本地 `sera-noto-sans-sc.ttf` |
| 主要字号 | 28 / 19 / 17 / 15 / 14 / 12 / 11 | Intro、Section、标题、按钮、正文、说明和标签 |
| 页面左右留白 | 22 px | Scaffold 内容左右 22 logical px |
| 卡片圆角／内边距 | 20 px / 20 px | `SeraCard` 默认值 |
| 按钮圆角／高度 | 14 px / 至少 50 px | `SeraButton` 默认值 |
| 品牌与图标 | SVG、透明 PNG | `assets/brand`、`assets/icons`，按比例显示和着色 |
| 底部主操作 | 固定动作区 | Scaffold 滚动内容与 footer 分开布局，结合安全区 |

公共卡片、按钮、字段、输入框、提示、标签、任务行、日程行和进度条统一从 `lib/ui/core` 引用。页面使用同一套颜色与字体，后续视觉反馈应优先修正公共定义，再处理页面局部差异。

## 原生实现中需要单独评审的差异

- **系统区域**：H5 内绘制的 9:41、信号和电池没有复制进 Flutter 内容。Android 系统状态栏与底部安全区交给平台，Web 使用浏览器视口。
- **日期与内容**：默认使用真实启动日期和工作区数据。原设计固定日期、静态任务数和进度不再硬编码。`DEMO_DATE=2026-10-28` 只用于可重复的课程演示。
- **表单与输入**：日期／时间使用 Flutter 原生选择器；软键盘、焦点、文字选择和返回行为遵循平台组件。字号放大、长标题和窄屏会使内容自然换行与滚动。
- **规划与进度**：07 与 51 等待真实生成／保存完成；不靠固定延时假报成功。HTTP 模式的 AI 拆解来自服务端，任务数量与时长随实际结果变化；本机模式清楚标注本地模板来源。
- **外部能力**：Android 通过原生平台通道读取外部日历并逐项同步自有日历，使用系统通知和 AudioRecord；Web 使用 ICS、Service Worker / Web Push 和 AudioWorklet。50 展示真实流式识别及可编辑结果，备用云端上传由用户触发。权限、服务、浏览器网络或设备系统组件缺失时显示实际失败与恢复入口。平台实测与尚未覆盖的环境见 [DELIVERY_V2.md](DELIVERY_V2.md)。
- **冲突状态**：22、23、48、53 读取当前数据与校验结果，没有为了匹配静态图而伪造客户会议、版本冲突或同步失败。42 展示实际保存／连接状态，不虚构“5/6 已同步”。
- **草案与离开**：输入、澄清与草案按账号持久化；44 表示保留草案并离开，55 不声称已经写入正式任务。正式确认原子写入目标、任务和时间块，重复确认不会重复创建；系统日历同步在业务保存后独立进行。
- **Web 展示**：桌面宽屏将移动内容居中显示；手机按可用宽度布局。设计图是 390 px 基准，不把整个画布按比例缩放来代替响应式布局。

这些差异不等同于已经完成逐像素验收。字体栅格、原生选择器、Android 软键盘与安全区需要分别核对。自动化路由和布局检查的实际结果由交付验证记录说明。

## 55 页面逐项映射

“原图”链接指向原始 3× 设计导出，“H5”指向已确认可交互原型的对应页面，“布局”保留 Image to Slice 的节点与样式记录。Flutter 中 07、11、51 等页面需要前置业务上下文，直接访问时会显示当前状态或必要操作入口。

| 编号与页面 | 原图 | H5 | 布局 | Flutter 路由 | 原生实现文件 |
| --- | --- | --- | --- | --- | --- |
| 01 欢迎与价值引导 | [原图](../../screens/01-welcome@3x.png) | [H5](../../h5-prototype/index.html#01-welcome) | [布局](../../h5-slice/layouts/01-welcome.json) | `/01` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 02 设置可用时间与偏好 | [原图](../../screens/02-preferences@3x.png) | [H5](../../h5-prototype/index.html#02-preferences) | [布局](../../h5-slice/layouts/02-preferences.json) | `/02` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 03 连接日历说明 | [原图](../../screens/03-connect@3x.png) | [H5](../../h5-prototype/index.html#03-connect) | [布局](../../h5-slice/layouts/03-connect.json) | `/03` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 04 今天 · AI 入口与执行概览 | [原图](../../screens/04-today@3x.png) | [H5](../../h5-prototype/index.html#04-today) | [布局](../../h5-slice/layouts/04-today.json) | `/04` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 05 AI 对话与意图识别 | [原图](../../screens/05-assistant@3x.png) | [H5](../../h5-prototype/index.html#05-assistant) | [布局](../../h5-slice/layouts/05-assistant.json) | `/05` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 06 目标澄清与约束确认 | [原图](../../screens/06-clarify@3x.png) | [H5](../../h5-prototype/index.html#06-clarify) | [布局](../../h5-slice/layouts/06-clarify.json) | `/06` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 07 AI 生成计划中 | [原图](../../screens/07-generating@3x.png) | [H5](../../h5-prototype/index.html#07-generating) | [布局](../../h5-slice/layouts/07-generating.json) | `/07` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 08 AI 计划草案与任务拆解 | [原图](../../screens/08-plan@3x.png) | [H5](../../h5-prototype/index.html#08-plan) | [布局](../../h5-slice/layouts/08-plan.json) | `/08` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 09 编辑草案任务 | [原图](../../screens/09-edit-plan-task@3x.png) | [H5](../../h5-prototype/index.html#09-edit-plan-task) | [布局](../../h5-slice/layouts/09-edit-plan-task.json) | `/09` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 10 计划提交确认 | [原图](../../screens/10-confirm@3x.png) | [H5](../../h5-prototype/index.html#10-confirm) | [布局](../../h5-slice/layouts/10-confirm.json) | `/10` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 11 计划创建与同步成功 | [原图](../../screens/11-applied@3x.png) | [H5](../../h5-prototype/index.html#11-applied) | [布局](../../h5-slice/layouts/11-applied.json) | `/11` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 12 日程 · 日视图 | [原图](../../screens/12-calendar-day@3x.png) | [H5](../../h5-prototype/index.html#12-calendar-day) | [布局](../../h5-slice/layouts/12-calendar-day.json) | `/12` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 13 日程 · 工作周视图 | [原图](../../screens/13-calendar-week@3x.png) | [H5](../../h5-prototype/index.html#13-calendar-week) | [布局](../../h5-slice/layouts/13-calendar-week.json) | `/13` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 14 日程 · 月视图 | [原图](../../screens/14-calendar-month@3x.png) | [H5](../../h5-prototype/index.html#14-calendar-month) | [布局](../../h5-slice/layouts/14-calendar-month.json) | `/14` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 15 固定日程详情 | [原图](../../screens/15-event-detail@3x.png) | [H5](../../h5-prototype/index.html#15-event-detail) | [布局](../../h5-slice/layouts/15-event-detail.json) | `/15` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 16 编辑固定日程 | [原图](../../screens/16-event-edit@3x.png) | [H5](../../h5-prototype/index.html#16-event-edit) | [布局](../../h5-slice/layouts/16-event-edit.json) | `/16` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 17 任务列表与收件箱 | [原图](../../screens/17-tasks@3x.png) | [H5](../../h5-prototype/index.html#17-tasks) | [布局](../../h5-slice/layouts/17-tasks.json) | `/17` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 18 任务详情与执行入口 | [原图](../../screens/18-task-detail@3x.png) | [H5](../../h5-prototype/index.html#18-task-detail) | [布局](../../h5-slice/layouts/18-task-detail.json) | `/18` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 19 快速添加任务 | [原图](../../screens/19-new-task@3x.png) | [H5](../../h5-prototype/index.html#19-new-task) | [布局](../../h5-slice/layouts/19-new-task.json) | `/19` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 20 目标总览 | [原图](../../screens/20-goals@3x.png) | [H5](../../h5-prototype/index.html#20-goals) | [布局](../../h5-slice/layouts/20-goals.json) | `/20` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 21 目标详情与里程碑 | [原图](../../screens/21-goal-detail@3x.png) | [H5](../../h5-prototype/index.html#21-goal-detail) | [布局](../../h5-slice/layouts/21-goal-detail.json) | `/21` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 22 AI 冲突识别与重排建议 | [原图](../../screens/22-replan@3x.png) | [H5](../../h5-prototype/index.html#22-replan) | [布局](../../h5-slice/layouts/22-replan.json) | `/22` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 23 重排前后对比与确认 | [原图](../../screens/23-replan-diff@3x.png) | [H5](../../h5-prototype/index.html#23-replan-diff) | [布局](../../h5-slice/layouts/23-replan-diff.json) | `/23` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 24 执行跟进与阻碍反馈 | [原图](../../screens/24-checkin@3x.png) | [H5](../../h5-prototype/index.html#24-checkin) | [布局](../../h5-slice/layouts/24-checkin.json) | `/24` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 25 任务专注进行中 | [原图](../../screens/25-focus@3x.png) | [H5](../../h5-prototype/index.html#25-focus) | [布局](../../h5-slice/layouts/25-focus.json) | `/25` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 26 专注结束与任务结果确认 | [原图](../../screens/26-focus-result@3x.png) | [H5](../../h5-prototype/index.html#26-focus-result) | [布局](../../h5-slice/layouts/26-focus-result.json) | `/26` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 27 提醒中心 | [原图](../../screens/27-reminders@3x.png) | [H5](../../h5-prototype/index.html#27-reminders) | [布局](../../h5-slice/layouts/27-reminders.json) | `/27` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 28 今日回顾 | [原图](../../screens/28-daily-review@3x.png) | [H5](../../h5-prototype/index.html#28-daily-review) | [布局](../../h5-slice/layouts/28-daily-review.json) | `/28` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 29 本周回顾 | [原图](../../screens/29-weekly-review@3x.png) | [H5](../../h5-prototype/index.html#29-weekly-review) | [布局](../../h5-slice/layouts/29-weekly-review.json) | `/29` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 30 我的 | [原图](../../screens/30-me@3x.png) | [H5](../../h5-prototype/index.html#30-me) | [布局](../../h5-slice/layouts/30-me.json) | `/30` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 31 AI 与规划偏好 | [原图](../../screens/31-ai-preferences@3x.png) | [H5](../../h5-prototype/index.html#31-ai-preferences) | [布局](../../h5-slice/layouts/31-ai-preferences.json) | `/31` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 32 日历与同步 | [原图](../../screens/32-calendar-sync@3x.png) | [H5](../../h5-prototype/index.html#32-calendar-sync) | [布局](../../h5-slice/layouts/32-calendar-sync.json) | `/32` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 33 提醒与免打扰 | [原图](../../screens/33-notification-settings@3x.png) | [H5](../../h5-prototype/index.html#33-notification-settings) | [布局](../../h5-slice/layouts/33-notification-settings.json) | `/33` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 34 AI 对话记录 | [原图](../../screens/34-history@3x.png) | [H5](../../h5-prototype/index.html#34-history) | [布局](../../h5-slice/layouts/34-history.json) | `/34` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 35 全局搜索 | [原图](../../screens/35-search@3x.png) | [H5](../../h5-prototype/index.html#35-search) | [布局](../../h5-slice/layouts/35-search.json) | `/35` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 36 数据与隐私 | [原图](../../screens/36-data-privacy@3x.png) | [H5](../../h5-prototype/index.html#36-data-privacy) | [布局](../../h5-slice/layouts/36-data-privacy.json) | `/36` | [main_screens.dart](../lib/ui/screens/main_screens.dart) |
| 37 今天 · 首次使用空状态 | [原图](../../screens/37-empty-today@3x.png) | [H5](../../h5-prototype/index.html#37-empty-today) | [布局](../../h5-slice/layouts/37-empty-today.json) | `/37` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 38 目标 · 尚未创建 | [原图](../../screens/38-empty-goals@3x.png) | [H5](../../h5-prototype/index.html#38-empty-goals) | [布局](../../h5-slice/layouts/38-empty-goals.json) | `/38` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 39 AI 生成失败与重试 | [原图](../../screens/39-ai-error@3x.png) | [H5](../../h5-prototype/index.html#39-ai-error) | [布局](../../h5-slice/layouts/39-ai-error.json) | `/39` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 40 离线保存与待同步 | [原图](../../screens/40-offline@3x.png) | [H5](../../h5-prototype/index.html#40-offline) | [布局](../../h5-slice/layouts/40-offline.json) | `/40` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 41 日历权限未开启 | [原图](../../screens/41-calendar-permission@3x.png) | [H5](../../h5-prototype/index.html#41-calendar-permission) | [布局](../../h5-slice/layouts/41-calendar-permission.json) | `/41` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 42 日历同步部分失败 | [原图](../../screens/42-partial-sync@3x.png) | [H5](../../h5-prototype/index.html#42-partial-sync) | [布局](../../h5-slice/layouts/42-partial-sync.json) | `/42` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 43 删除任务确认弹窗 | [原图](../../screens/43-delete@3x.png) | [H5](../../h5-prototype/index.html#43-delete) | [布局](../../h5-slice/layouts/43-delete.json) | `/43` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 44 离开未保存草案底部弹层 | [原图](../../screens/44-discard@3x.png) | [H5](../../h5-prototype/index.html#44-discard) | [布局](../../h5-slice/layouts/44-discard.json) | `/44` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 45 设置任务提醒底部弹层 | [原图](../../screens/45-reminder-sheet@3x.png) | [H5](../../h5-prototype/index.html#45-reminder-sheet) | [布局](../../h5-slice/layouts/45-reminder-sheet.json) | `/45` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 46 任务完成反馈与撤销 | [原图](../../screens/46-completed@3x.png) | [H5](../../h5-prototype/index.html#46-completed) | [布局](../../h5-slice/layouts/46-completed.json) | `/46` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 47 没有可用时间与剩余任务安排 | [原图](../../screens/47-no-capacity@3x.png) | [H5](../../h5-prototype/index.html#47-no-capacity) | [布局](../../h5-slice/layouts/47-no-capacity.json) | `/47` | [task_screens.dart](../lib/ui/screens/task_screens.dart) |
| 48 草案过期与重新检查 | [原图](../../screens/48-stale-plan@3x.png) | [H5](../../h5-prototype/index.html#48-stale-plan) | [布局](../../h5-slice/layouts/48-stale-plan.json) | `/48` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 49 今天 · 内容加载骨架 | [原图](../../screens/49-loading@3x.png) | [H5](../../h5-prototype/index.html#49-loading) | [布局](../../h5-slice/layouts/49-loading.json) | `/49` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 50 语音输入与实时转写 | [原图](../../screens/50-voice@3x.png) | [H5](../../h5-prototype/index.html#50-voice) | [布局](../../h5-slice/layouts/50-voice.json) | `/50` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 51 确认后的写入进行中 | [原图](../../screens/51-writing@3x.png) | [H5](../../h5-prototype/index.html#51-writing) | [布局](../../h5-slice/layouts/51-writing.json) | `/51` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 52 重排成功与关联提醒更新 | [原图](../../screens/52-adjusted@3x.png) | [H5](../../h5-prototype/index.html#52-adjusted) | [布局](../../h5-slice/layouts/52-adjusted.json) | `/52` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 53 撤销遇到后续修改 | [原图](../../screens/53-undo-conflict@3x.png) | [H5](../../h5-prototype/index.html#53-undo-conflict) | [布局](../../h5-slice/layouts/53-undo-conflict.json) | `/53` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 54 通知权限拒绝与站内提醒 | [原图](../../screens/54-notification-permission@3x.png) | [H5](../../h5-prototype/index.html#54-notification-permission) | [布局](../../h5-slice/layouts/54-notification-permission.json) | `/54` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
| 55 草案保存成功且未写入日历 | [原图](../../screens/55-draft-saved@3x.png) | [H5](../../h5-prototype/index.html#55-draft-saved) | [布局](../../h5-slice/layouts/55-draft-saved.json) | `/55` | [planning_screens.dart](../lib/ui/screens/planning_screens.dart) |
