# 单主机部署、开发邮件与模型初始化

部署单位为 API、持久作业/推送 worker、本地流式 ASR、Caddy，数据保存在 SQLite WAL 的共享 named volume。开发 profile 额外启动 Mailpit。生产和开发均不会从前端读取或暴露 SiliconFlow 密钥。

## Compose

要求 Docker Engine + Compose v2.24 以上；先在 sera_flutter 根目录构建网页：

```powershell
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin
python web/generate_offline_manifest.py build/web
Set-Location deploy
Copy-Item .env.example .env
# 用本机编辑器配置 .env 的服务端密钥，不提交此文件。
docker compose config --quiet
docker compose up --build -d
```

默认只将 Caddy 映射到回环 `http://127.0.0.1:8080`，API 回环8787用于原生模拟器，ASR 只在私网通过 Caddy `/asr/ws` 提供。Caddy 原生处理 WebSocket 升级，并传递可信代理协议；API 内 Secure Cookie 能识别反向代理 HTTPS。保持 API 映射为回环，不将配置为信任私网代理的服务裸露到公网。

`model-init` 使用同一应用镜像运行下载脚本：首次下载固定官方模型归档（458187351字节），校验 SHA256 后只提取官方量化组合（int8 encoder/joiner + float decoder）、词表及官方测试音频并生成文件清单。`sera-models` 卷持久化，ASR 等待初始化成功，以只读方式挂载并在加载时重新验证；失败不会伪装语音服务就绪。再次运行复用已校验归档，损坏归档会重新下载。可单独重跑：

```powershell
docker compose run --rm model-init
docker compose restart asr
```

开发邮件通过 Mailpit：

```powershell
docker compose --profile dev -f compose.yaml -f compose.dev.yaml config --quiet
docker compose --profile dev -f compose.yaml -f compose.dev.yaml up --build -d
```

开发覆盖将 API 邮件模式设为 mailpit，投递私网固定 `mailpit:1025`；只将收件箱 UI 映射回环 `http://127.0.0.1:8025`，不向互联网发布 SMTP/UI。可在收件箱点击真实邮箱验证/重置链接完成流程。默认基础配置使用文件 mail sink；正式邮件设置 `SERA_MAIL_MODE=smtp` 并配置支持 TLS 的 SMTP。实际外部邮件送达需要自己的邮箱服务验收。

正式域名在 `.env` 配置（示例值需替换，不会自动发布）：

```dotenv
SERA_SITE_ADDRESS=sera.example.com
SERA_PUBLIC_ORIGIN=https://sera.example.com
SERA_ASR_WS_URL=wss://sera.example.com/asr/ws
SERA_BIND=0.0.0.0
SERA_HTTP_PORT=80
SERA_HTTPS_PORT=443
SERA_MAIL_MODE=smtp
```

同时准备 DNS、开放80/443、真实SMTP、VAPID_SUBJECT联系邮箱、持久存储备份，确认 Caddy 获得证书。Caddy 证书状态在独立 `caddy-data` 卷，不能把它当作临时容器文件丢弃。不要在生产启用 dev profile。

健康检查与诊断：

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health/live
Invoke-RestMethod http://127.0.0.1:8080/health/ready
docker compose logs --tail 100 api worker asr
docker compose ps
```

live 仅说明 API 存活；ready 检查数据库、150秒内 worker 心跳、独立 ASR 已加载模型、邮件配置和 AI 配置。邮件配置检查不能代替真正的送达测试。API 容器 health 使用 live，避免在 ASR 初始化依赖中形成死锁；整套应用验收使用 ready。

Web离线启动依赖完整资源清单。直接调用`flutter build web`后必须再运行`python web/generate_offline_manifest.py build/web`；常用`scripts/build.ps1`和`start-fullstack.ps1`已包含这一步，镜像构建也会生成清单。Service Worker按内容hash校验完整资源包，整包成功后才切换缓存，不将缺少主程序的部分缓存标记为可离线启动。

## 原生进程替代

Docker Engine 不可用时，按 [API 文档](../docs/API.md) 在本机依次启动 API、worker、ASR，保持相同 `--db`。Python虚拟环境和模型已可直接运行；Windows WebM 备用识别设置 FFPROBE_PATH 指向已安装 ffprobe。后端绑定127.0.0.1，Android模拟器使用10.0.2.2。

## 备份与恢复

不要在 SQLite WAL 写入时只复制主 .sqlite3 文件。使用 SQLite 在线 backup API，或停止 api/worker/asr 后一起备份数据卷。数据卷包括数据库、session-secret、VAPID私钥、开发邮件；这些都是敏感运行数据。session-secret丢失会使Cookie CSRF/语音票据失效，VAPID私钥丢失则需要浏览器重订阅。模型卷可通过校验下载重新生成，不必与账号数据同周期备份。

已提供可运行的在线备份/隔离恢复脚本（从 sera_flutter 根目录执行）：

```powershell
backend/.venv/Scripts/python.exe deploy/backup.py backup --db backend/sera.sqlite3 --output .local/backups/sera-backup.zip
backend/.venv/Scripts/python.exe deploy/backup.py restore --archive .local/backups/sera-backup.zip --destination .local/restore-check
backend/.venv/Scripts/python.exe backend/server.py --db .local/restore-check/workspace.sqlite3 --port 8789
```

归档包含一致性DB快照、会话签名secret和VAPID私钥，附每文件SHA256；不会包含SiliconFlow密钥或开发邮件。恢复前校验清单/哈希和SQLite integrity_check，拒绝覆盖非空目录或既有备份。不要将归档放在静态Web目录。确认账号/工作区/操作收据、作业与推送记录后再安排正式恢复。源码和交付压缩包不包含真实DB、.env、密钥、邮箱token、.venv、模型归档。账号删除只清当前账号，备份中的历史数据按部署者设定的保留期处理。

本机验收已通过基础/开发两套 `docker compose config --quiet`，且官方Caddy v2.11.2 Windows归档按官方SHA512校验后执行 `caddy validate` 返回 Valid configuration。当前宿主 Docker Engine 的 npipe info 返回500，容器启动/公网TLS因此尚未实跑；API、worker、ASR已通过本机原生进程和真实模型集成测试。不得把Compose配置校验当作容器运行或公网发布成功。

配置依据：[Caddy反向代理](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)、[Compose启动依赖](https://docs.docker.com/compose/how-tos/startup-order/)、[Mailpit Docker](https://mailpit.axllent.org/docs/install/docker/)。
