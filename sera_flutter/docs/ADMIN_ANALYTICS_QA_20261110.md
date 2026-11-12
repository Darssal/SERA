# 2.2.1 运营统计实际验收

版本 **2.2.1+33**，香港日期 **2026-11-10**。本轮完成 Web 管理后台官方概览的统计与交互，未新增主导航、统计埋点、数据表、迁移或直接依赖。任务于 11 月 9 日开始，私有执行目录和部分日志继续使用 `20261109`。完整定义见 [统计口径](ADMIN_ANALYTICS.md)，后台其余功能沿用 [2.2.0 验收](ADMIN_CONSOLE_QA_20261109.md)。

## 实际执行

在项目 `sera_flutter` 目录，Windows、已有 Flutter/Dart 与 Python 虚拟环境执行：

| 验证 | 实际结果 | 原始记录 |
| --- | --- | --- |
| `flutter analyze --no-pub` | 无问题 | `.local/admin-analytics-20261109/flutter-analyze.log` |
| `flutter test --no-pub --reporter expanded` | **1063 通过，1 项原有可选 HTTP 测试跳过** | `flutter-full.log` |
| 统计 UI 专项 | **10 通过**，包含 320／390／1536px、1.7 倍字体、点击／键盘／Semantics 选日 | `flutter-ui-repair.log` |
| 现有后端 `test_*.py` | **467 通过，0 失败** | `backend-regression.log` |
| 新增统计 HTTP／SQLite | **18 通过，0 失败** | `.local/analytics-backend-20261109.log` |
| 原后台兼容 HTTP／SQLite | **27 通过，0 失败** | `.local/analytics-admin-regression-20261109.log` |
| 配置与交付脚本 | **25 通过** | `scripts-test.log` |
| Node Web 平台与真实构建缓存升级 | **41 通过** | `node-test.log`、`cache-upgrade.json` |
| 离线资源清单 | **3 通过** | `offline-manifest-test.log` |
| `flutter build web --release --no-pub --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin` | 成功 | `web-build.log` |

除明确给出 `.local/` 完整相对路径的两份后端日志，其余原始记录均位于 `.local/admin-analytics-20261109/`。该目录包含私人数据库备份，不进入交付包。

全量 Flutter 的可选跳过项需要 `API_INTEGRATION_URL` 指向隔离参考 API；并未把它记为实际 HTTP 联调成功。本轮另以真实 8787 接口完成只读统计对账。Web 构建仍有既有 CupertinoIcons 字体声明提示，构建成功；本轮未新增相关图标或依赖。

首次测试发现的图形 Semantics 相邻值缺失、320px 大字体日期刻度溢出均已修复，并增加实际无障碍增减断言。坏数据参数化测试的数字映射夹具已改为真实 JSON 解码形态，使小数确实进入生产整数校验；没有放宽 DTO 校验或忽略异常。修复后通过上表全量回归。

## 真实数据库独立对账

`check-live-analytics.py` 仅使用现有官方账号的临时 Bearer 登录、读取统计并退出；不使用浏览器会话，也不发布或修改内容。独立读取现有 SQLite 记录，用 Python 香港日期和集合重算，不调用生产聚合函数。

2026-11-10 00:11 香港时间的结果：

| 期间 | 新增账号 | 发帖或评论人数 | 发布内容 | 新增评论 |
| --- | ---: | ---: | ---: | ---: |
| 近 7 天 | 5（前期 2） | 5（前期 0） | 18（前期 0） | 19（前期 0） |
| 近 30 天 | 7（前期 0） | 5（前期 0） | 18（前期 0） | 19（前期 0） |
| 近 90 天 | 7（前期 0） | 5（前期 0） | 18（前期 0） | 19（前期 0） |

三组摘要、前期同刻、7／30／90 条逐日结果、独立贡献者、互斥分类、当前累计及正数前五排行全部对账。当前分类为日常 14、反馈 3、活动 1；当前累计 0 赞、0 报名，排行互动来自真实保存的评论。包括保留的模拟帖子和演示账号，不代表真实生产运营规模。结果存于 `live-reconciliation.json`；此时刚过午夜，11 月 10 日的 0 值属于真实结果，不把 11 月 9 日的峰值当作今天。

主数据库已在线备份。只读验收前后 **13 张用户／工作区／社区表逐行摘要一致，外键有效**；没有新增管理审计操作或停用账号。记录为 `preserved-data.json`、`data-preservation.json`。临时登录、会话日志及后台心跳属于运行状态，不把它们称为全数据库字节不变。

## 实际浏览器

使用 Codex 内置浏览器，真实地址 [官方运营概览](http://127.0.0.1:8787/#/admin/overview)，现有官方 Cookie 登录。检查了：

- 1536×1024 桌面两列布局、四项数值、香港期间和前期截止时刻。
- 7／30／90 切换、刷新，7 天账号为 5、30／90 天为 7，与真实接口一致。
- 点击 11 月 9 日趋势点；内容 18、评论 19、注册 5。左右键、Home／End 实际改变日期，两图显示同步数值。
- 排行“查看”打开正确帖子、图片及 2 条评论；关闭返回概览，未执行内容移除。
- 逐日表格、统计口径的展开和收起；表格 11 月 9 日为 5／5／18／19。
- 320×900、390×900 的筛选换行、单列图形、首尾刻度、分类与排行；未发现横向页面溢出。
- 从本轮新构建加载开始，控制台新增 **error／warn 为 0**。窗口覆盖已恢复，用户原社区标签页保留，后台标签页作为交付保留。

记录为 `browser-qa.json`，实际截图位于 `C:/Users/rytram/.codex/visualizations/2026/11/10/sera-admin-analytics/`：

- `before-desktop-1536.png`：原概览。
- `overview-final-desktop-1536.png`、`overview-seven-day-1536.png`：新概览与选日。
- `ranking-detail-1536.png`：真实排行详情。
- `overview-details-desktop-1536.png`：逐日数据及统计口径。
- `overview-top-320.png`、`overview-charts-320.png`、`overview-top-390.png`、`overview-distribution-390.png`：窄屏实际截图。

Widget 语义操作和浏览器键盘操作已执行；没有启动 NVDA 等屏幕阅读器，不能将 Semantics 用例代替真人读屏验收。Android 本轮未构建、安装或进行 MuMu 实测，上一有效安装包 **2.2.0+32**保留。

## 发布、缓存与复现

本机 8787 服务沿用原数据库及私有配置，仅重新加载服务端。Web 从完整候选目录原子切换，74 个资源共 **42,185,894 字节**均通过大小和 SHA-256 校验。`main.dart.js` SHA-256：

```text
ed973cc857add3804eed3801a47a49063b7d5675a460ace9e5d2af2a6034222a
```

离线版本为 `fb2cd6b5c95712649ce0a49b72521b0c9d8e9d1784a4c345e485985e0a9fcbde`。使用前后两个真实构建字节在 Node VM 模拟 CacheStorage／IndexedDB 进行升级：复用 **72 个资源、36,160,346 字节**；下载 **2 个资源、6,025,548 字节**。缓存结果不是浏览器网络抓包、启动耗时或 Android 性能结论。

交付目录 `.local/releases/sera-2.2.1+33/` 保存源码包、Web 包与 SHA-256 清单。两个 ZIP 的完整性检查、源码所需文件和版本检查、Web 资源与实际服务文件逐项对比均通过；源码 508 项、Web 89 项归档条目。两个包均通过私有凭据扫描，核对实际 AI、SMTP、SMS、官方及四个演示账号的本机凭据，未输出凭据值，扫描发现为 0。结果见交付目录的 `artifact-verification.json`、`delivery-scan.json` 和 `SHA256SUMS.txt`。

私有配置、会话、数据库、录音不进入包。旧服务目录完整保留于 `.local/web-before-admin-analytics-220`，新候选为 `.local/web-admin-analytics-20261109`。无额外测试服务常驻。

常规复现命令：

```powershell
./scripts/check.ps1
./scripts/build.ps1 -Target web
./scripts/start-fullstack.ps1 -SkipBuild -EnvFile @('.local/community-private/official.env')
```

端口已由本机当前服务使用时继续复用该服务；换部署环境时按 [后台账号配置](ADMIN_CONSOLE.md) 配置官方身份及必要环境，不复制本机私人凭据。
