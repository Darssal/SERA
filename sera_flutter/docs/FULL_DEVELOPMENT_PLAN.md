# SERA 全量开发与验收追踪（v2）

> 2026-11-01版本提示：本页保留早期v2范围及对应历史证据，旧通过数字、未配置说明和逐项状态不能直接视为当前版本结论。当前源码为2.0.8+10；最新五专项复查、已确认缺陷、待补验收及交付版本差异见[全盘要求复查](FULL_REVIEW_20261101.md)。历史记录不删除，也不冒充最新版重新通过。

批准方案：Android + Web；以已确认55页H5为界面基准，Flutter原生Widget，FastAPI/Uvicorn + SQLite WAL单主机后端，真实SiliconFlow语义拆解、本地sherpa-onnx流式ASR、Web HttpOnly/原生Bearer、对象级同步、平台日历与提醒。更新日期：2026-10-31（Asia/Hong_Kong）。

本文件区分“代码已实现”“自动化通过”“实际平台验收”。**实现落地不自动等于整项完成**。R01–R32按已有可追溯证据分别记录；未实际运行的设备版本、失败分支与外部服务不勾完成。最终发布构建、截图、设备操作与包哈希已由 [DELIVERY_V2.md](DELIVERY_V2.md) 统一记录；集成测试APK的业务/平台验证与正式签名APK/AAB的安装启动分别列证，不互相替代。

## 已形成的可运行基线

- v2应用模型与UI已落地：目标生命周期、任务状态/依赖/拆段、多块日程、草案重查、专注恢复、回顾与搜索。
- 账号、邮箱动作、数据隔离、schema2迁移、对象级同步、作业/推送worker、ICS与独立ASR已实现。
- 后端最近一次完整测试：53项通过（包含4项新增模型选型/完整性回归），临时SQLite和虚构账号；本地ASR两项真实模型测试未跳过。包含纯日期截止/全天显示区、推送会话清理和新块事务校验。最终完整执行记录以交付记录为准。
- 真实本地模型采用官方 int8 encoder/joiner + float decoder；已修复错误 int8 decoder 导致的漏字并锁定四文件哈希。当前10.053秒固定样本计算RTF 0.02288、14次partial；实时节拍首partial P95为1.1121/1.1213秒，finish→final为19.98/36.38毫秒。相同6条合成语料严格CER25.83%，三条纯中文句0，中英混合仍有漏错；非真人准确率，详见[LOCAL_ASR](LOCAL_ASR.md)。
- `/health/ready` 在隔离QA栈8788读取为ready：数据库、worker心跳、8791模型服务、local邮件模式和AI配置可用。local邮件就绪只代表本机投递配置；不等于外部SMTP送达。
- Compose基础/dev配置与官方SHA512校验后的Caddy配置验证通过。Docker Engine当前npipe info 500，容器启动、公网TLS未实跑。
- 已从源码/构建ZIP与独立模型ZIP解包到新TEMP目录，用现有Python3.11虚拟环境在8792/8793启动实际API/worker/ASR。Webhash、Cookie注册/me、个人workspace CRUD、解包模型真实静音PCM推理、在线备份与新目录恢复后原会话/数据均通过，结束核对自有端口关闭；见[clean-directory-rehearsal.json](qa/clean-directory-rehearsal.json)。这是隔离新目录复现，不是干净OS或容器运行。
- 最终Web候选d75a6c2971b1在Chrome/Edge完整通过真实UI登录/两步首次设置、离线保存/刷新、停止真实SW并离线新开文档、联网同步、双标签账号跟随与旧CSRF读取401。初轮缺失缓存、空工作区409竞争和Edge广播早于storage传播均已修复并复验。证据见[web-offline-accounts.json](qa/web-offline-accounts.json)；额外诊断触发既有429限流单独记录，未据此虚报成功控制台指标。
- 最终自动化记录见[flutter-regression.json](qa/flutter-regression.json)：静态分析无问题，Flutter157通过/1项付费AI测试显式跳过、Node32通过、离线清单Python3通过、重启证据解析Python2通过。MuMu1已完成真实平台复跑、17秒业务集成和重启提醒观测；正式发行签名、APK/AAB校验、分包安装与最终通用Release APK安装另见[build-artifacts.json](qa/build-artifacts.json)及[aab-device-validation.json](qa/aab-device-validation.json)。

## R01–R32逐项状态与证据

| 编号 | 项目 | 当前状态 | 已实现范围 | 已有证据 | 尚待实测 / 明确边界 |
| --- | --- | --- | --- | --- | --- |
| R01 | 工程与配置 | 已实现；隔离交付目录复现通过 | Flutter Android/Web工程v2.0.0+2；脚本区分setup/run/build/sign/package；前后端依赖锁；运行数据与凭据排除。 | qa/clean-directory-rehearsal.json：源码/模型包哈希、安全解包、新目录actual supervisor、Web/会话/数据/模型/恢复通过；两套Compose config通过。 | 复用了已安装Python依赖，未声称干净OS安装；最终文档重打包按qa/clean-directory-rehearsal.json的运行摘要与main/APK/AAB哈希核对等价。 |
| R02 | 注册登录与会话 | 已实现；Web与MuMu1真实会话流程通过 | 随机盐PBKDF2密码；会话摘要/7天过期/撤销；Web HttpOnly+CSRF与原生安全存储；邮箱验证及重置。 | qa/mumu1-business.json：生产UI注册、退出/再登录恢复原任务与专注记录、密码确认注销及独立会话401；qa/web-offline-accounts.json：Cookie重开/双标签；后端与Auth仓储自动化。 | 邮箱动作已有本地/SMTP socket自动化，不代表真实外部SMTP送达；API24、API33+及其他厂商安全存储分支仍需对应设备。 |
| R03 | 迁移与账号切换 | 已实现；最终Chrome/Edge双标签实测通过 | 旧guest只显式导入；账号独立Sembast缓存、旧请求关闭、平台scope切换；注销清理；Cookie当前账号跨标签一致。 | qa/web-offline-accounts.json：真实A退出/B登录广播、同文档B身份、B无A任务、旧CSRF401；确定性初始化409与传播竞态回归。 | 多设备通知/系统日历清理及完整迁移界面以实际Android/交付记录补证；此Web记录不代替所有设备。 |
| R04 | 导航与首次使用 | 已实现；最终Web/MuMu1首次使用实测通过 | 登录/设置、4主导航、带task/draft参数路由、缺失对象与深链恢复。 | qa/mumu1-business.json：UI注册→首次偏好/连接日历→完成标记持久；qa/web-offline-accounts.json：Chrome/Edge两步引导、刷新和同文档账号路由；qa/flutter-regression.json路由/首次设置回归。 | 系统通知实际点击后的完整应用深链、所有返回栈组合及其他Android版本仍未由上述流程穷举。 |
| R05 | 目标生命周期 | 已实现；领域/界面用例已编写 | 创建编辑、active/paused/completed/archived、验收完成、现有目标调整草案复用task ID。 | test/v2_domain_test.dart；controller_features.dart；目标详情实际状态入口。 | 逐个目标状态在最终两端版本手动复验。 |
| R06 | 任务完整状态 | 已实现；自动化及真实收件箱/完成流程通过 | 独立/目标任务、检查项、priority、dueDate/dueAt、todo/in_progress/blocked/done/canceled与恢复。 | qa/mumu1-business.json：UI创建5分钟收件箱任务、完成专注不自动完成任务、显式完成并保留实际时长；qa/web-ai-voice.json执行/完成；领域与后端类型/引用回归。 | blocked/canceled/恢复等全部状态组合及统计口径有自动化，不把收件箱与完成实测扩展成所有状态的设备穷举。 |
| R07 | 依赖与拆段 | 已实现；自动化覆盖 | 依赖环拒绝；前置完成检查；多块、splittable/minBlockMinutes/remainingMinutes、部分排期。 | test/v2_domain_test.dart多块/依赖/重排；backend/server.py依赖DFS；test/platform_ics_reminder_test.dart多块提醒。 | 实际设备多块日历同步及通知不重复待验收。 |
| R08 | 日程与时间语义 | 已实现；跨日API及最终MuMu1全天/时区复跑通过 | 固定事项增改删、全天/跨日、时区字段；外部忙碌独立保留；锁定约束。 | qa/mumu1-platform.json：最终日期修复后真实Provider重跑、洛杉矶DST结束日全天写入/回读及时间戳保持；qa/flutter-regression.json纯日期/UTC；qa/web-ai-voice.json的UTC保存刷新。 | 上述覆盖指定日期和API32 Provider字段；其他设备系统时区切换、复杂重复跨DST实例及所有系统日历UI显示未穷举。 |
| R09 | 目标理解与澄清 | 已实现；交互用例已编写 | 原始prompt/notes及澄清输入持久；可确认日期/预算；显式日期词规则；新目标重置上下文。 | test/prompt_date_test.dart、planning_flow_test.dart；planningSessions模型与规划输入页。 | 供应商多种真实中文目标的语义质量及无关追问需人工评价。 |
| R10 | 真实AI与排期 | 已实现；真实Chrome流程与规则回归通过 | SiliconFlow语义拆解、严格JSON/时长检查；Dart预算/休息/缓冲/依赖/忙闲排期；容量不足报错。 | qa/web-ai-voice.json：一次真实SiliconFlow生成4任务/100分钟、标题编辑并提交、API与UI一致；最终d75a6构建确认既有任务持久；领域/后端供应商stub回归。 | 完整生成记录与最终只读smoke的构建分别注明；多种自然目标的语义质量仍需评价，不把一次目标或默认跳过的付费测试视为全面供应商验收。 |
| R11 | AI取消及记录恢复 | 已实现；持久队列API自动验收 | SQLite作业/租约/状态/幂等key，取消不覆盖终态；输入会话、重试与恢复；清对话保留正式业务。 | backend/test_app.py作业重放/取消；persistent_ui_flows_test.dart；Http仓储轮询与取消。 | 云端已发出的请求无法保证停止计费；断网杀进程后实际恢复待两端复验。 |
| R12 | 草案编辑 | 已实现；Chrome标题编辑/确认实测及自动化通过 | 标题、估时、顺序、移除、暂不排期、确认前预览；草案与正式任务/日程分离。 | qa/web-ai-voice.json：实际草案标题编辑、提交及服务器任务核对；planning_flow_test.dart、persistent_ui_flows_test.dart与controller草案操作。 | 估时/顺序/移除等所有编辑组合、Android草案全流程及长文本/键盘适配仍不由单一标题编辑实测代替。 |
| R13 | 提交与过期草案 | 已实现；事务和版本自动化覆盖 | 重新读取外部忙闲，calendarFingerprint/baseTaskVersions过期检查；幂等确认；单任务targetTaskId细化。 | backend/test_v2_contract.py目标展示/单任务细化；domain/repository tests；sync整批回滚。 | 真实外部日历在草案期间变化、失败重试不留半成品需设备复验。 |
| R14 | 冲突重排 | 已实现；规则回归覆盖 | 真实冲突建议、确认后修改、保护锁定/固定项；建议clamp到当前时刻；保留原截止。 | domain_test.dart、v2_domain_test.dart；findAvailableSlot/applyReplan；已修locked丢失。 | 22/23从真实设备日历变化进入、撤销补偿路径待实测。 |
| R15 | 历史与撤销 | 已实现；并发保护覆盖 | 有界前后快照、对象变化保护、撤销失败不覆盖新修改；平台补偿独立报告。 | domain_test.dart、repository_test.dart、persistent_ui_flows_test.dart；history模型。 | 系统事件删除/撤销部分失败及只重试失败项需实际设备证据。 |
| R16 | 专注恢复 | 已实现；MuMu1真实专注流程/账号重开通过 | 持久FocusSession、运行/暂停/继续/结束、累计实际秒数、重启恢复；结束不自动完成任务。 | qa/mumu1-business.json：真实启动/暂停/继续/结束、暂停不增长、秒数与focus record一致、结束不自动完成、退出再登录保留记录；qa/web-ai-voice.json的Chrome执行；领域/界面持久化回归。 | 已验证完成记录跨会话恢复；运行中杀进程、长时间后台、系统时钟跳变和Web运行中专注重开的所有分支仍需专项实测。 |
| R17 | 剩余工作与阻碍 | 已实现；真实业务状态保存 | remainingMinutes、blockedReason、明确延期/补排、稍后与ack状态、scheduledAt保护。 | controller_features.dart；任务/跟进页面；backend/test_app.py多块ack/snooze/改期失效。 | 系统通知稍后按钮与跨端恢复需设备复验。 |
| R18 | 今日/本周回顾 | 已实现；Chrome回顾持久与刷新实测通过 | 计划任务完成、计划/实际时长、目标进展、反馈持久ReviewRecord；按真实数据计算。 | qa/web-ai-voice.json：实际回顾保存到API并刷新保留；persistent_ui_flows_test.dart、task_screens.dart及后端review字段回归。 | 本周、跨日完成与多时区统计需按模型口径进一步人工对照，Chrome单次回顾不代表全部周期与Android路径。 |
| R19 | Android日历授权读取 | 已实现；最终源码MuMu API32平台复跑通过 | CalendarContract权限、来源选择、实例读取、全天及重复会议；明确读取范围。 | qa/mumu1-platform.json的postIntegrationSourceChanges为passed_final_reexecution：权限授予后真实Provider读取及最终全天修复回归均已重跑；qa/flutter-regression.json平台映射回归。 | 权限拒绝/撤销弹窗、其他Provider及重复实例差异仍需对应环境；API32权限授予不代替所有版本授权分支。 |
| R20 | Android日历写入同步 | 已实现；最终源码MuMu API32平台复跑通过 | 自有SERA日历、稳定映射、增改删、冲突保护、逐项结果、只重试失败项。 | qa/mumu1-platform.json：最终日期修复后实际CRUD、unchanged去重、外部修改冲突、明确覆盖和删除失败重试；最终签名产物安装另见qa/build-artifacts.json。 | 平台集成测试APK与最终Release安装分开记证；跨多个真实设备账号切换系统清理、厂商Provider差异未由单台模拟器穷举。 |
| R21 | Web ICS交换 | 已实现；解析自动化通过 | 本地ICS预览导入/导出；复杂VTIMEZONE/规则走鉴权后端preview；外部忙碌持久化并约束规划。 | platform_ics_reminder_test.dart；backend/test_v2_contract.py RRULE/EXDATE/改期/取消/多日全天。 | 真实外部ICS文件在Chrome/Edge选择/下载/再导入；账号OAuth双向同步不在本交付范围。 |
| R22 | Android系统提醒 | 已实现；真实MuMu1调度及重启恢复通过 | 权限/渠道、定时取消与重算、点击路由、去重、稍后、免打扰与账号scope。 | qa/mumu1-platform.json真实AlarmManager/NotificationManager调度取消；qa/mumu1-reminder-reboot.json：boot ID真实改变、未重开Activity/未伪造广播，持久提醒在重启后出现。 | 重启项是主机观测实验，非Flutter测试通过数；通知实际点击导航、锁屏/时间跳变、免打扰实际投递时刻及API33+通知授权仍未由此验收。 |
| R23 | Web前台及后台推送 | 已实现；最终Chrome真实关页投递通过 | Notification权限、前台定时、SW+PushManager、VAPID订阅、worker投递、scope/gen/expiry/quiet与服务端validate。 | docs/qa/web-push.json对应d75a6c2971b1：真实PushManager订阅/后端登记，应用页全部关闭后SW已shown，重开前getNotifications匹配唯一测试投递；无模拟push事件。 | 该实测通过配置的可达推送网络；通知点击完整恢复、Edge/其他推送厂商、完全退出浏览器与OS后台限制保留边界，不保证所有环境准时送达。 |
| R24 | 真实语音输入 | 接口/录音/推理链路已验证；官方配置修复与固定语料复测完成 | Android/Web录音、PCM实时ASR票据/WS、partial/final/取消/限流；WAV/WebM云备用；识别稿可改。 | qa/mumu1-platform.json真实AudioRecord PCM/WAV；qa/web-ai-voice.json以官方固定音频模拟麦克风的实际Worklet/WS partial/final、取消及识别稿进入目标；最终中文权限拒绝、0PCM/0finish回归；后端真实模型与时延记录。 | qa/asr-fixed-corpus.json保留修复前后原始结果：6条合成语料严格CER25.83%，非真人准确率，中英词仍需校对。静音final、样本时延和模拟麦克风不代表真人自然语音质量；Android麦克风至文字全流程及权限拒绝/恢复未由PCM产出单项代替。 |
| R25 | 离线与待同步 | 已实现；最终Chrome/Edge离线冷热重开通过 | 账号隔离Sembast事务缓存+稳定ID队列、未知结果幂等重放、离线身份恢复、重连同步；86资源hash包原子缓存，API不缓存。 | qa/web-offline-accounts.json：断网UI保存、reload、停止真实SW并新开文档后同taskID/说明保留，恢复联网后服务器GET确认任务。 | 冷测停止了SW与文档，未声称彻底退出浏览器进程；桌面移动尺寸视口不代表手机浏览器。Android杀进程另见最终设备证据。 |
| R26 | 多端与冲突处理 | 已实现；CAS/幂等/差异处理覆盖 | 独立entityVersions、409冲突列表、保留本地/远端与人工选择；墓碑阻止旧对象复活。 | backend/test_app.py 501批次/回滚/墓碑；offline_repository_test.dart不覆盖无关远端对象。 | 两个实际客户端同时编辑→选择解决→继续队列需手工复验。 |
| R27 | 提醒中心与搜索 | 已实现；持久界面用例覆盖 | 带对象上下文搜索、提醒/冲突/跟进/回顾入口、应答状态持久。 | persistent_ui_flows_test.dart；主界面搜索与通知中心；reminderStates。 | 最终真实任务/日程/草案混合查询、过期/不存在对象路由需浏览器复核。 |
| R28 | 偏好/隐私/数据管理 | 已实现；MuMu1注销及隔离备份恢复实测通过 | 预算/休息/缓冲/免打扰/时区与AI上下文控制；文件导出、清记录、删除账号和本地清理。 | qa/mumu1-business.json：密码确认UI注销及独立会话401，未清未知用户数据；qa/clean-directory-rehearsal.json在线备份/新目录恢复原会话与任务；后端导出/级联回归。 | 真实导出下载打开、注销后的所有系统日历/通知补偿以及部署备份保留策略仍需专项验收。 |
| R29 | 后端完整性与安全 | 已实现；自动化验收通过 | FastAPI、SQLite WAL、schema2、事务/CAS、鉴权/隔离、Cookie CSRF/Origin、邮箱单次token、请求/音频限制、供应商错误与密钥隔离。 | backend unittest最新53项全通过；含推送审查与最终排期校验；/health/live与/ready；显式OpenAPI。 | 公网域名/TLS、真实SMTP、运行配额/监控及长期负载未在本机测试中冒称完成。 |
| R30 | 55页异常闭环 | 已实现；界面故障注入用例已编写 | 空数据、离线、权限、部分失败、草案过期/保存失败/撤销冲突等真实条件有恢复入口。 | widget_test.dart、planning_flow_test.dart、persistent_ui_flows_test.dart、account_voice_ui_test.dart。 | 逐页浏览器/Android交互与设备权限分支需最终回归，不能以gallery页数代替。 |
| R31 | 视觉适配与可访问性 | 220组布局/大字体自动化通过；核心实屏有证据 | 复用切图、中文字体、共享组件、窄屏与文本缩放；已修静态JSON导致字体manifest500。 | qa/flutter-regression.json：55状态×4宽度共220组，10核心页面320px/150%字体；qa/web-ai-voice.json、web-offline-accounts.json及build-artifacts.json的真实浏览器/发行版登录页目视。 | 自动化布局和核心截图不等于55页逐项人工视觉签收；读屏焦点、实际触摸目标、全部键盘/安全区分支仍需专项人工验收。 |
| R32 | 全量测试与交付 | 自动化/设备/发行签名/交付目录已验证；语音质量核对中 | 自动化、隔离QA栈、Web/Android构建脚本、私有release签名、包装排除凭据、校验与部署说明。 | qa/flutter-regression.json的157通过/1付费AI跳过、Python49/Node32；qa/mumu1-business.json及平台/重启记录；qa/build-artifacts.json的RSA3072/APK v2/AAB JAR签名、实际安装哈希；qa/aab-device-validation.json的4分包安装启动；交付目录复现及扫描JSON。 | 集成APK的全链与Release安装启动分开记录；语音识别质量仍在核对。API24/API33+、通知实际点击、公网TLS/SMTP、Docker实跑及新OS依赖安装未被现有证据替代；最终归档哈希见相邻校验文件与DELIVERY_V2。 |

## 已执行的阶段与剩余验收

M0–M1（基线、身份、模型、契约）代码已落地；M2（核心业务）、M3（AI/语音接口）、M4（平台能力）、M5（离线/隐私/部署）均有真实实现、自动化与对应平台证据。M6/M7已有浏览器、MuMu平台/业务、发行签名/安装及隔离交付目录复现记录；ASR配置修复后的新模型/源码候选仍须重新复现并核对识别质量，旧运行摘要不沿用为新候选基准。实际已测构建和包哈希见DELIVERY_V2及各JSON，未提供的外部环境继续保留边界。

本轮发现并修复的阻断包括：静态JSON字体manifest被当对象处理而500；Web Cookie恢复发送空Bearer导致误登出；跨日日程后端24小时限制；重排建议落在过去；locked标记丢失；单任务细化合成goal引用；Web Push测试generation0被本地快照误拦；浏览器订阅成功而服务器失败的补偿；关闭通知再开启时原cancelled投递不恢复。每项修复对应自动化用例，浏览器/设备效果仍按最终版本确认。

## 必走的最终场景

1. 注册→邮箱验证→首次设置→文字目标→真实AI→编辑草案→确认→多块日程→专注→反馈/回顾；重置密码后旧会话失效。
2. 外部会议/ICS→真实冲突→保留锁定项的建议→确认重排→提醒重算→安全撤销；后续修改阻止旧撤销覆盖。
3. 麦克风权限允许/拒绝→真实PCM流partial/final→编辑稿→目标；取消、断网、重录、60秒边界可恢复。
4. Android系统日历增改删/重复同步/逐项失败，通知权限/锁屏/点击/重启恢复；以实际设备证据区分已测/未测。
5. 离线编辑→关闭/杀进程→重开→队列恢复→重连；另一客户端同时改同对象→展示差异→人工解决，不覆盖无关数据。
6. 浏览器主动允许并成功注册Push→关闭全部应用页面→worker真实投递→SW含Cookie验证→系统通知→点击恢复；无订阅、会话过期、退出、改期和免打扰不冒充送达。
7. A账号→退出→B账号→A重新登录；缓存、任务、通知、日历映射隔离；账号导出和注销级联清理。
8. 从新目录按setup启动、下载校验模型、签名构建、排除凭据打包、在线备份/隔离恢复；容器/正式域名需对应环境另验。

## 交付与平台边界

- Web日历提供真实ICS交换；Google/Microsoft OAuth账号双向同步需要对应应用凭据，未实现冒充授权连接。
- 页面关闭后Push依赖浏览器厂商推送服务、联网、有效Cookie、通知权限和浏览器后台策略；完全退出浏览器或系统限制可能不送达。当前本地验证不保证公网/所有手机行为。
- ASR本地服务及录音/推理协议真实运行；固定音频、加速计算指标与实际麦克风端到端延迟分开记录。当前识别质量仍在核对，配置修复后的候选需独立验证，不能用旧时延、静音final或接口成功推导语音准确率。
- 公开域名/TLS、商店账号、外部SMTP和真机兼容性需要真实环境证据。未提供条件时保留待验收，不用模拟器/配置解析/静态成功页代替。

运行与契约：[README](../README.md)、[API](API.md)、[架构](ARCHITECTURE.md)、[部署](../deploy/README.md)、[最终交付记录](DELIVERY_V2.md)。
