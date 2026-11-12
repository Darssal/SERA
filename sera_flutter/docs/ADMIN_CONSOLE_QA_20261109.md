# Web 管理后台验收 · 2.2.0+32

2026-11-09，Windows 本机、Flutter 3.47.2 / Dart 3.13.2、Python 3.11、SQLite，浏览器为 Codex In-app Browser。预览入口为 [管理后台](http://127.0.0.1:8787/#/admin)，本轮部署复用现有 8787 API/Web、后台 worker 与 8790 ASR，没有增加常驻测试服务。

## 自动化与构建

| 检查 | 本轮实际结果 | 执行日志 |
| --- | --- | --- |
| Flutter 静态分析，lib / test / integration_test | 无问题 | `.local/admin-analyze-delivery-20261109.log` |
| 完整 Flutter 回归 | 1013 通过，1 项原有可选 HTTP 测试跳过，0 失败 | `.local/admin-flutter-delivery-20261109.log` |
| 现有后端回归 | 467 通过，0 失败 | `.local/admin-backend-full-20261109.log` |
| 新增管理员 API 与 SQLite 集成 | 27 通过，0 失败；最终重跑 23.651 秒 | `.local/admin-backend-delivery-20261109.log` |
| 配置、账号建立与交付检查 | 25 通过 | `.local/admin-scripts-delivery-20261109.log` |
| Service Worker、真实构建缓存升级、AudioWorklet | Node 41 通过 | `.local/admin-platform-delivery-20261109.log` |
| 离线资源清单 | Python 3 通过 | `.local/admin-manifest-delivery-20261109.log` |
| 发布 Web | 构建并生成完整离线清单成功 | `.local/admin-web-build-delivery-20261109.log` |
| Android release APK / AAB | 均构建成功，版本 2.2.0 / 32；APK v2 签名、AAB manifest / bundle / JAR 签名验证通过 | `.local/admin-{apk,aab}-build-delivery-20261109.log` 及 `.local/admin-console-20261109/admin-*.log` |

新增 Flutter 行为共 36 项：客户端与状态 23、界面 10、根路由与窗口容器 3，均已包含在 1013 项中，不重复计数。10 项界面覆盖 390px / 1536px 和 1.7 倍字体、不同权限入口、查询分页、取消不写入、失败保留原因与操作 ID、账号切换关闭弹窗、草稿继续编辑与明确放弃。

新增后端检查使用临时数据库、虚构账号与惰性供应商，实际测试删除级联、角色与四权限、即时撤权、Cookie/CSRF、脱敏检索、游标、幂等、账号停用和恢复、旧会话失效、原工作区保留、审计失败回滚、旧身份迁移、外键和 9 个接口的 OpenAPI / DTO。它们不是对现有用户内容进行删除或停用演示。统一 `scripts/check.ps1` 已包含新增管理员和脚本测试。

## 真实浏览器检查

七个分区均实际打开：概览、内容管理、官方发布、管理员与申请、用户、操作记录、运行状态。官方账号登录后读取实际数据库，观察到 18 条帖子、3 条使用反馈、19 条评论、7 个账号和 0 条待审核申请；没有为概览编造管理员、待办或增长数据。

- 桌面 1536×1024 下独立侧栏、完整表格、图片摘要、真实作者与计数；查询“晚霞刚好”只返回对应 1 条，清除后恢复 18 条；反馈分类返回 3 条，评论返回 19 条。
- 打开帖子详情核对完整文字、两张图片和计数；打开内容移除确认后取消，原记录保留。
- 用户页只显示脱敏身份，官方账号无停用操作；普通演示账号的停用确认说明会话失效和数据保留，检查后取消。
- 四权限弹窗可见，未提交任何授权。新增和审批、权限增减、角色越权的真实写入由上述隔离测试验证；在线预览当前没有管理员或待审核申请，界面显示真实空态。
- 官方发布复用图片与发布表单；文字输入后侧栏离开提示正确，继续编辑保留正文；浏览器历史后退也能取消并恢复发布地址；明确放弃后重新打开为空。活动类型展示开始时间与地点。在线检查未发布临时文字或上传检查图片。
- 运行状态实际读取数据库和 worker 心跳。AI、验证邮件、ASR 显示“已配置”，未调用付费模型、发送邮件／测试通知或伪造供应商健康结果。
- 390px 实查抽屉和表格横向拖动；最终 320px 实查内容页，无布局异常。桌面返回社区恢复 430px 手机容器，原四栏职责不变；社区管理内的后台入口实际可用。
- 退出后仍停留在后台门禁；登录地址携带原后台 returnTo，登录成功准确返回。最终构建连续三轮退出／登录均返回原页；切换社区与后台标签、恢复输入并查询仍正常。

首轮浏览器曾出现一次 Flutter 焦点遍历的空值异常，堆栈落在已脱离渲染树对象的 `getTransformTo`。账号切换队列现在先取消旧控件焦点、停放到根焦点范围并提交待处理更新，再释放旧路由。修复后全量回归重跑通过；上述三轮登录及标签切换没有新 error / warn。此结论限本机实际执行环境，不代替所有操作系统窗口焦点或真实读屏测试。

浏览器机器记录为 `.local/admin-console-20261109/browser-qa.json`，最终截图目录为 `C:/Users/rytram/.codex/visualizations/2026/11/09/sera-admin/`：

| 证据 | 文件 |
| --- | --- |
| 概览 | `overview-final-desktop-1536.png` |
| 内容管理 | `content-final-desktop-1536.png` |
| 权限弹窗 | `permissions-final-desktop.png` |
| 窄屏内容 | `content-final-narrow-320.png` |
| 390px 抽屉／横向表格 | `drawer-narrow-390.png` / `content-narrow-horizontal-390.png` |
| 登录门禁与准确返回 | `signed-out-gate-desktop.png` / `login-return-team-desktop.png` |
| 草稿、详情、状态与返回应用 | 同目录对应 `publish-*`、`post-detail-*`、`status-*`、`app-return-*` |

## 发布、数据与回退

Web 发布目录 `.local/web-admin-console-20261109`；现有 8787 服务目录 `.local/web-simplicity-release-20261108` 为同 SHA 的原子切换副本。

- 清单 74 文件，42,154,676 字节；版本 `4b6f87ea1412a6118b5006ed46837364d21df10a0033fbcc10c3dd8383088e71`。
- `main.dart.js` SHA-256：`631ce7fee1e5a01df4ccac523bf19b365599dd2af56a455ffca240cfd8957bf3`。
- 相对 2.1.4 的真实资源升级测试复用 71 文件、36,147,866 字节，只需下载 3 文件、6,006,810 字节；未变字体和渲染资源复用。数字来自 Node 内存缓存测试，不代表浏览器启动耗时或 Android profile。
- 发布前通过 SQLite backup 创建私有备份 `.local/admin-console-20261109/before-admin.sqlite3`，没有替换现有数据库。新增后台附表不修改 workspace schema 2。
- 浏览器验收前后，13 张用户、社区与工作区表的行数和内容摘要相同，外键检查通过；没有新增审计记录、停用账号、授权或删除内容。登录测试仅正常刷新会话。
- 2.1.4 Web 回退副本为 `.local/web-before-admin-console-214`；两轮中间预览另存 `.local/web-admin-console-initial-preview` 和 `.local/web-admin-console-before-focus-fix`。最终发布及数据核对记录在同一私有验收目录。

交付位于 `.local/releases/sera-2.2.0+32/`：完整源码 ZIP、Web ZIP、签名 APK、AAB、签名版本回执、凭据扫描和 SHA-256 清单。模型和私有数据库、SMTP／短信／AI 凭据、会话、签名私钥不打入源码或客户端包。

本轮没有安装或运行 MuMu 安卓设备-1，Android 结果为编译与包验证，不能当作日历、录音、系统通知或设备运行验收；真实邮箱送达、短信、付费 AI 和公网 HTTPS 不属于本次后台浏览器实查。已有相关能力和历史证据继续保留。本轮未新开常驻测试环境，临时 Gradle daemon 已停止，浏览器测试视口已恢复。
