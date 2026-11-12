# 平台能力实现与验收

`platform_services.dart` 按编译目标创建 `SeraPlatformServices`。Android 通过原生 Kotlin MethodChannel / EventChannel；Web 通过 JS interop 调用 `web/sera-platform.js`、AudioWorklet 和 Service Worker。Windows 等非目标平台明确返回不支持，不生成假的授权、录音、日历或通知结果。

## 账户与提醒协议

调用任何账户功能前执行 `setAccountScope(user.id)`；退出时切为 `signed-out`。Android 将账户编号 SHA-256 后用于日历账户、同步映射及通知；Web Service Worker 保存当前账户编号以拒绝其他账户推送。平台脚本和 Service Worker 均不保存 Bearer token、refresh token 或供应商密钥。

每个日程块独立生成 `${entry.id}:start` 和 `${entry.id}:followup` 提醒，开始提醒导航至 `/18?taskId=...`，执行跟进导航至 `/24?taskId=...`。跟进原始时间为日程结束后 5 分钟。

- `scheduledAt`：原始提醒时间的 UTC ISO 字符串，计算于免打扰或稍后调整前。
- `fireAt`：实际投递时间的 Unix 毫秒。
- `validUntil`：开始提醒为日程结束，跟进为结束后一天，超期不投递。
- `generation`：工作区 revision，阻止旧安排覆盖新安排。
- `timeZone`、`quietStart`、`quietEnd`：用户 IANA 时区和免打扰时段。

`Workspace.reminderStates[id]` 使用 `{status:'ack'|'snoozed', at:ISO, scheduledAt:ISO, snoozeUntil?:ISO}`。只有原始 `scheduledAt` 仍相同才应用状态；改期或更改提前分钟后旧状态失效。稍后默认 10 分钟且不能越过有效期。已完成、已取消和收件箱中尚未安排的任务不会创建提醒。

## Android

- Calendar Provider 权限：`READ_CALENDAR`、`WRITE_CALENDAR`。列出真实日历，读取指定来源的展开忙碌事件，建立当前账户专属的本地 SERA 日历。
- 日历逐项增改删：provider `CUSTOM_APP_URI` 中写入源事项编号及内容基线，进程中断或映射遗失时可恢复去重。外部修改与删除冲突逐项返回失败；用户明确确认后才能 `overwriteConflicts:true` 覆盖。失败删除保留映射，下次完整同步可重试。
- 本地通知：Android 13+ 运行时通知权限、通知渠道、AlarmManager、支持时使用精确闹钟；权限不足时明确报告非精确提醒及可能延迟。Receiver 核验账户、版本、有效期和免打扰。重启、升级、时间/时区和精确闹钟权限变化后重排；打开应用也会重排。
- 文件：SAF 打开 ICS、创建 ICS / JSON 文件。取消及存储失败明确报告；写入失败尝试清理未完成的新文件。
- 音频：AudioRecord 16 kHz 单声道 s16le；文件录音输出真实 WAV，实时流每约 100ms 一帧 3200 字节 PCM，60 秒上限。取消或切换账户停止并释放麦克风。
- Release 使用私有 `.local/signing/key.properties`；支持 `SERA_SIGNING_PROPERTIES` Gradle 属性或环境变量。缺少配置直接失败。远程接口要求 HTTPS；只给 `localhost` / `127.0.0.1` 开放明文用于 `adb reverse` 课程演示。

不是所有模拟器都附带 Calendar Provider。遇 `calendar_unavailable` 必须安装可信系统组件或在具备系统日历的设备验收。不得用内存日历冒充设备能力。

## Web / PWA

- 设备日历 API 在浏览器中不可直接访问，使用真实 ICS 文件导入和下载；基础本地解析支持 UTC / floating / 固定时区、每日/每周/每月有限重复、EXDATE、RDATE、全日和取消/透明事件。复杂 VTIMEZONE / DST / 序号规则交给已登录后端 `/api/v1/calendar/ics/preview` 解析并预览。
- 未订阅 Push 时只在页面保持打开期间安排提醒。订阅后由服务端持久调度和 Web Push 投递，避免同时运行前台计时器造成重复提醒。
- Push 配置、订阅和测试接口使用 `/api/v1/push/*`。Service Worker 在显示每条推送前，使用当前同源 HttpOnly 会话调用 `/api/v1/push/validate?id=...&generation=...` 校验最新业务状态。测试通知也必须通过后端已登记的测试投递校验；payload 无法绕过验证。
- Worker 拒绝其他账户、退出账户、过期、提前到达、旧 generation、重复、免打扰中的推送；点击仅允许任务详情、跟进或提醒中心内部路由。
- 前台通知、订阅、取消订阅和查询订阅均通过 Worker `get-scope` 核对持久账户；另一个标签切换账户后，旧页面返回 `stale_account` 并停止推送操作，不能显示旧账户内容或取消新账户订阅。主动 `setAccountScope` 才能重新初始化账户。
- 只缓存静态壳资源；API、健康检查、带 Authorization 的请求和非 GET 请求不缓存。离线资源在成功访问后缓存。构建使用 `--no-web-resources-cdn` 将 CanvasKit 放到本地，避免离线加载依赖外部 CDN。
- Web 构建完成后运行 `python web/generate_offline_manifest.py build/web`。脚本按实际输出生成内容哈希清单，覆盖 bootstrap、main、所有所需本地 CanvasKit 变体、字体及页面素材；首屏先等待完整缓存准备，解决第一次访问尚未被 Worker 接管时漏缓存运行文件的问题。新版本所有文件通过大小和 SHA-256 校验后才原子切换；失败继续使用完整旧版，旧标签保留其版本，容量或网络错误提供重试提示且不无限阻止在线启动。
- 浏览器需 HTTPS 或 localhost。Web Push 依赖浏览器/系统的推送与通知服务，关闭页面后可投递；强制退出浏览器、撤销站点权限、操作系统禁用后台活动或网络断开不能保证即时展示。失败会保留诊断，订阅变化需重新打开应用完成带身份的服务器登记。
- MediaRecorder 文件模式输出浏览器真实 WebM/WAV；实时模式用 AudioWorklet 将设备实际采样率转换为 16 kHz 单声道 s16le，100ms 帧，无 WAV 头；60 秒/10 MiB 上限。权限请求期间取消也会释放随后获得的麦克风轨道。

## 验证命令

```powershell
flutter analyze lib/platform test/platform_channel_test.dart test/platform_ics_reminder_test.dart integration_test/platform_device_test.dart
flutter test test/platform_ics_reminder_test.dart test/platform_channel_test.dart
node --test test/platform_worker_test.mjs test/platform_bridge_test.mjs
flutter build web --release --no-web-resources-cdn
python web/generate_offline_manifest.py build/web
```

指定 MuMu 安卓设备 1 为 `127.0.0.1:16416`，不要默认使用设备 0：

```powershell
adb connect 127.0.0.1:16416
flutter test integration_test/platform_device_test.dart -d 127.0.0.1:16416
```

集成测试会安装测试 APK，测试独立 QA 账户的日历增改删/稳定去重、通知调度/取消、真实 PCM 和 WAV。首次安装后只为 `com.sera.sera_flutter` 授予声明的日历/麦克风权限（Android 13+ 另授通知）；测试等待权限最多 25 秒。`finally` 清除 QA 事项及通知，不触碰业务账户。完成后重新安装正式应用 APK。

可使用配套主机脚本自动在测试 APK 每次重装后为 SERA 授权，并通过 Android 的真实 `content` 命令在应用外修改仅属于 QA 的日历事项，验证覆盖确认及删除重试。以下命令只针对指定的设备 1，不使用默认设备选择：

```powershell
python android/tools/run_platform_qa.py --flutter D:/development/flutter/bin/flutter.bat --adb D:/development/android-sdk/platform-tools/adb.exe --device 127.0.0.1:16416 --external
```

`--external` 编译仅集成测试包含的 loopback 协作服务，使用临时 `adb forward`，结束后清理；生产应用不存在该服务。脚本在修改前确认系统事件的稳定标记包含 `qa-external-conflict`，拒绝修改其他事项。

重启恢复使用独立的主机观察实验，先确认 5 秒正常定时提醒的系统活动通知，再校验 60 秒提醒已落盘，仅重启设备 1；不启动应用、不发送模拟 BOOT 广播，观察唯一提醒能否真实出现：

```powershell
python android/tools/run_platform_qa.py --flutter D:/development/flutter/bin/flutter.bat --adb D:/development/android-sdk/platform-tools/adb.exe --device 127.0.0.1:16416 --reboot-check
```

此模式通过 `flutter run` 启动同一测试文件的 `PLATFORM_QA_REBOOT` 专用入口，避免 `flutter test` 断连后自动卸载 APK 干扰闹钟恢复。就绪后的观察最多 120 秒（首次编译安装另计，准备最多 90 秒），结果写入 `docs/qa/mumu1-reminder-reboot.json`，明确标为 host experiment，不能算作 Flutter 测试通过。只记录合成 QA 标识和布尔证据，不保存原始系统通知内容。结束时仅在持久 QA marker 与本次 runId 匹配后清空测试 APK 数据；随后重新安装正式版本并恢复所需 `adb reverse`。脚本不会更改 root、全局权限、共享磁盘或其他设备实例。没有可观察的系统通知或现有精确闹钟权限时报告失败/环境限制。

本次设备 1 的 Calendar Provider 来源为 Google 官方 SDK `default/x86_64 API32 r02` 系统镜像，ZIP SHA-1 `238452e27d6854d153b6ed119fa783189598eac4` 与官方 SDK XML 一致。`android/tools/extract_sdk_partition.py` 在解压 GPT 镜像后，校验 LP geometry、metadata header 和 tables 的 SHA-256，再只提取 system 逻辑分区。提取的 CalendarProvider APK SHA-256 为 `66bf40ecba45fb2f330c1145c06ab0dbc6dbfc388114af6e6c06c7858cb95588`，APK v3 签名验证通过，AOSP Android 证书 SHA-256 为 `a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc`。

该模拟器最初缺失系统组件，普通用户 APK 因隐藏系统 API 无法初始化。验证了 MuMu 官方实例级可写系统盘产生独立 `system-diff.vdi` 后，组件安装在仅设备 1 的 `/system/priv-app/CalendarProvider`；原有 privileged allowlist 已包含所需许可，无需修改。操作前停机备份配置和独立 diff，操作后恢复 `root_permission=false` 并重启，确认 `su` 不可用、Provider 为 SYSTEM/PRIVILEGED、共享 base 磁盘 SHA-256 未改变。私有 diff 保留组件；没有修改主机安全设置、其他实例或 `hidden_api_policy`。镜像、备份和 APK 位于本机开发工具目录，不属于产品源码交付。

Flutter 原生构建与测试请串行执行；并发 `flutter test` / `pub get` 可能在 Release 编译时重写包含测试插件的生成注册文件。不要手改 `GeneratedPluginRegistrant`。
