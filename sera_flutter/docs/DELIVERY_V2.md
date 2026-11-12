# SERA v2 开发与验收记录

版本：`2.0.0+2`。记录日期：2026-10-31。本文件区分源码实现、自动化验证、真实系统联调和受环境限制的验收项。

## 运行与产物

工作目录为 `sera_flutter`。完整启动、架构和接口见 [README](../README.md)、[ARCHITECTURE](ARCHITECTURE.md)、[API](API.md)；七条逐步演示见 [DEMO](DEMO.md)，逐项功能追踪见 [FULL_DEVELOPMENT_PLAN](FULL_DEVELOPMENT_PLAN.md)。

```powershell
# 首次环境准备：依赖、CPU 语音模型、自有课程签名
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1 -Device 127.0.0.1:16416

# Web + API + 持久作业 worker + 流式语音
powershell -ExecutionPolicy Bypass -File scripts/start-fullstack.ps1 -SkipBuild
# http://127.0.0.1:8787/ ; API docs: /docs ; ASR: 8790

# 指定用户要求的 MuMu 安卓设备-1
powershell -ExecutionPolicy Bypass -File scripts/run-android.ps1 -Device 127.0.0.1:16416

# 全量检查及正式产物
powershell -ExecutionPolicy Bypass -File scripts/check.ps1
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Target all
backend/.venv/Scripts/python.exe scripts/package.py --include-builds
backend/.venv/Scripts/python.exe scripts/package-models.py
```

Web 使用同源 HttpOnly Cookie。Android 安装包默认连接本机回环 API，演示时需由脚本建立 `adb reverse` 的 8787 和 8790 端口映射；部署到远端时以 `-AndroidApiBaseUrl https://...` 重新构建。正式 APK/AAB 使用 `.local/signing` 下的独立课程签名；私钥与密码不进入源码包，务必单独备份。

源码压缩包不包含 API 密钥、会话、本机数据库、邮件内容、录音、私钥、虚拟环境或模型缓存。模型为单独的 CPU 量化资源包（int8 encoder/joiner + float decoder），附固定来源、SHA-256、模型与运行库各自的 Apache 2.0 许可和归属说明，不包含测试录音。模型包解压到 `backend`，得到 `backend/models/<模型名>`；也可运行模型下载脚本复现。

## 测试隔离与数据保全

自动化测试使用内存仓储、临时 SQLite 或独立测试账号。浏览器联调使用 `.local/qa-v2/workspace.sqlite3`（8788 API / 8791 ASR），与现有业务库分开。原 `backend/sera.sqlite3` 已通过 SQLite 在线备份保存在 `.local/backups/pre-v2-20261031.sqlite3`，旧访客数据不会自动归属新账号；只能从账户页预览并显式导入。

测试截图与临时浏览器脚本保存在工作区外的 QA 目录。脚本中的浏览器登录状态、测试密码和验证凭证不进入交付包。

## 已执行验证与产物

| 检查 | 记录 |
| --- | --- |
| Flutter / Dart | Flutter 3.47.2 stable / Dart 3.13.2；版本锁见 pubspec.lock |
| 静态分析 | 最终 `flutter analyze --no-pub` 无问题 |
| Flutter 单元 / Widget | 最终完整一轮 **157 passed / 1 skipped**；包含 UTC、全天日期、首次设置/失败重试、双标签初始化竞争、账号传播时序、规划恢复及弹窗生命周期回归 |
| 55 页布局 | 320 / 360 / 390 / 430 px 共 220 组布局与滚动检查通过；10 个核心页面 320 px / 150% 字体检查通过 |
| 浏览器平台脚本 | Node **32/32**；离线 manifest Python **3/3**，重启证据解析 Python **2/2** |
| Python 后端 | **53/53**，包含 2 项真实本地模型集成、4 项模型配置/完整性回归、实际 SMTP socket、事务/幂等/会话/排期/ICS/备份恢复 |
| 实际浏览器 | Chrome 已实际 AI 生成、编辑确认、专注/完成/回顾、实时 PCM/WS partial/final、取消与拒绝权限恢复；UTC 保存刷新通过。最终 d75a6c… 在 Chrome/Edge 的断网保存、离线刷新、停 Worker 后离线新开及 A/B 双标签跟随通过；关应用页 Push 在最终构建实际送达 |
| MuMu 平台 | 设备-1 Android 12 / API32，1080×1920 / density480（360 logical px）；真实日历 CRUD/防重/外部修改保护/删除重试、PCM/WAV、通知调度通过；真实重启提醒及 17 秒完整业务集成通过 |
| Web / APK / AAB | 串行发布构建通过；APK **75,822,396 字节**、AAB **73,221,565 字节**；RSA3072 独立课程签名。APK v2 签名验证、AAB JAR 签名和 bundletool 结构验证通过；AAB 生成 4 个设备分包，在 MuMu1 安装并启动成功；最终恢复通用 Release APK，设备实际 SHA256 与交付文件一致 |
| 新目录复现 | 源码/构建与独立模型包实际解压到新 TEMP；新库 8792/8793 的 API、worker、ASR、Web、Cookie 会话与业务读写通过，备份到另一目录恢复后会话与任务保留；复用现有 Python 3.11 venv，未声称干净 OS / Docker 验收 |
| 交付扫描 | 配置的实际 AI 密钥精确匹配扫描、私密文件名、完整 PEM 私钥及嵌套 APK/AAB 检查通过；未发现密钥、私钥、会话或私人数据库。构建输出中的 Python 工具/bytecode 由清单生成器清理，打包器再次排除；对应回归已通过 |

可选的付费真实 AI 自动测试默认跳过，不计为供应商联调通过。真实模型推理测试与纯 mock 测试分开记录。所有结果以实际终端日志、服务数据和设备观察为依据，不以静态页面可打开替代平台能力验收。

发布检查使用官方 [bundletool 1.18.3](https://github.com/google/bundletool/releases/tag/1.18.3)；JAR SHA256 `a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29` 与 GitHub 官方 asset digest 一致。按 [Android 的本地 App Bundle 测试流程](https://developer.android.com/tools/bundletool)生成签名分包、安装到明确指定的设备，而非仅检查 AAB ZIP 可打开。课程证书为自签名证书，未配置公网证书链/时间戳；未声称 Play Store 发布。

最终构建的文件大小、完整 SHA256、ABI、签名证书摘要和设备安装核对在 [build-artifacts.json](qa/build-artifacts.json)。源码包的 SHA256 存放在压缩包旁的 `.zip.sha256`；独立模型包旁也有校验文件。`build/web` 包含 `sera-cache-manifest.json`，正式发布需要保持这一整套静态文件一致；脚本会在 Flutter Web 构建后生成清单。

工程上级目录的最终交付文件：

| 文件 | 内容 |
| --- | --- |
| `SERA-Flutter-Fullstack-v2.zip` | 完整 Flutter、平台、后端、部署、测试、文档，以及正式 APK/AAB/Web 构建；不含密钥、私人运行数据或模型权重 |
| `SERA-ASR-CPU-Models-v2.zip` | 独立 CPU 量化模型（含 float decoder）、校验与许可；解压到 `backend`，无需把权重装入客户端 |
| `SERA-Web-v2.zip` | 可部署的 Web 静态构建，平铺 `index.html` 与资源目录；运行时需要同源 API，使用完整启动脚本预览 |
| `SERA-QA-Screenshots-v2.zip` | 57 张实际截图及各轮无凭据验收 JSON；不同构建与修复前后状态由记录区分，包含最终 MuMu1 正式版截图 |

上述四个归档旁均有 `.zip.sha256`。主机当前预览地址为 `http://127.0.0.1:8787/`；MuMu1 已建立 8787/8790 的 `adb reverse`。设备重启或重新连接后，运行 `scripts/run-android.ps1` 或按 DEMO 中的命令恢复映射。安装包默认用于这套本机演示，远端部署请按 README 配置 HTTPS API 与 WSS 后重新构建。

在 Flutter 3.47.2 中，从 integration_test 调试构建转为发布构建时，`--no-pub` 会跳过插件清单再生成，可能让发布编译错误引用开发测试插件。本轮已用锁文件离线准备依赖，再执行正常 `flutter build apk/appbundle --release` 生成正确清单；提供的 `scripts/build.ps1` 保留正常发布准备流程，无需手工修改生成的 Java 文件。

## MuMu 设备-1 的日历环境修复

该实例原本缺少 Calendar Provider，普通用户安装原版 Provider 又受到系统隐藏 API 限制。因此从 Android 官方 API32 系统镜像提取已校验的原始 CalendarProvider，安装到设备-1 的私有系统差分盘。

- 官方镜像 `x86_64-32_r02.zip`：667,541,890 字节；SHA-1 `238452e27d6854d153b6ed119fa783189598eac4`。
- Provider APK：包名 `com.android.providers.calendar`，v32/API32；SHA-256 `66bf40ecba45fb2f330c1145c06ab0dbc6dbfc388114af6e6c06c7858cb95588`，apksigner v3 验证通过。
- 原 APK 的七项特权权限已在本实例系统 allowlist 中，无需修改 allowlist 或 `hidden_api_policy`。
- 安装前备份实例配置和干净差分盘；共享 base 的 SHA-256 安装前后一致，其他实例未修改。
- 临时 root 开关已恢复关闭，重启后 `su` 不可用；保留本实例私有系统差分盘以保存日历组件。

这些是模拟器环境修复记录；正常 Android 设备已有日历 Provider 时无需此操作，也不要求应用或用户设备开启 root。

## 运行与验收的明确边界

Docker Compose 的基础与开发配置解析通过，官方 Caddy 归档按 SHA-512 校验并 `caddy validate` 通过。当前主机 Docker Engine 返回 npipe 500；API、worker 和 ASR 的本机进程可运行，但尚不能把容器实际启动或公网 HTTPS 部署记为完成。

实际设备为 Android API32；API24 最低兼容与 Android13+ 通知运行时权限分支已有代码和测试，尚未在对应系统版本设备运行。系统真实重启后的提醒恢复和浏览器关闭全部应用页面后的实际 Push 均已观察到；这不代替实际点击系统通知后的应用导航、API33+ 权限弹窗及不同厂商后台限制验收。

可追溯记录位于 `docs/qa/`：`flutter-regression.json`、`mumu1-platform.json`、`mumu1-reminder-reboot.json`、`mumu1-business.json`、`web-ai-voice.json`、`web-offline.json`、`web-offline-accounts.json`、`web-push.json`、`aab-device-validation.json`、`build-artifacts.json`、`clean-directory-rehearsal.json` 和 `delivery-scan.json`。每份记录分别列出所测构建、合成测试数据、真实操作与明确边界。

ASR 已修正为官方 int8 encoder/joiner + float decoder，并重跑后端、同组六条语料和实时节拍；新增模型哈希与拒绝旧组合回归。六条合成语料严格 CER 为 25.83%，三条纯中文句为 0，中英混合仍需校对，不作为真人准确率。固定音频推理结果见 [LOCAL_ASR](LOCAL_ASR.md)及[前后原始记录](qa/asr-fixed-corpus.json)。官方样本加速解码的首段计算耗时不等于端到端实时延迟，也不能推导语料准确率；手机真实录音、固定样本模拟麦克风与后端模型测试必须分别标注。
