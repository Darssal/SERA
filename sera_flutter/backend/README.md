# SERA 后端

FastAPI/Uvicorn + SQLite WAL，提供真实账号与会话隔离、邮箱验证与密码重置、工作区对象同步、持久 AI 作业、Web Push worker、ICS 预览、本地 sherpa-onnx 实时语音与 SiliconFlow 上传备用识别。

从 sera_flutter 目录按 [API 文档](../docs/API.md) 安装 backend/requirements.txt 并启动 API、worker、ASR。默认只监听回环地址；密钥仅保存在服务端环境或指定密钥文件。

- API 与显式 OpenAPI: http://127.0.0.1:8787/docs
- [部署与备份](../deploy/README.md)
- [真实本地语音模型与性能](../docs/LOCAL_ASR.md)

测试必须使用临时数据库；不要把真实 DB、mail 目录、模型归档、.venv 或密钥放入源码交付包。

## 邮件验证与账号恢复

邮件模式默认为 `local`：邮件真实写入数据库同目录 `mail/`，不会发送到外部收件箱。登录账号后，发送邮箱验证，再打开账号页开发验证邮件；`GET /api/v1/auth/development-mailbox?purpose=verify-email` 只返回本人有效验证链接。确认成功后通过 `GET /api/v1/auth/me` 刷新 `emailVerified`。重发后旧链接失效，链接 30 分钟过期且只能使用一次。

找回密码始终返回通用申请受理状态。应用不提供匿名重置邮件预览；本地开发者可在受保护的 `mail/` 目录查看本人重置邮件，或使用 Compose 的 Mailpit 开发收件箱完成真实链接流程。重置后旧密码、该账号全部旧会话和推送订阅失效，原账号工作区保留，新密码登录后可继续读取。有效会话下粘贴其他账号链接会拒绝且不消费 token。

正式邮件配置入口为 [部署模板](../deploy/.env.example) 和 [部署说明](../deploy/README.md)。API 进程需要获得配置的 `SERA_MAIL_MODE=smtp`、`SERA_PUBLIC_ORIGIN`、`SMTP_HOST`、`SMTP_PORT`、`SMTP_FROM`、`SMTP_TLS`，需认证时同时配置 `SMTP_USERNAME/SMTP_PASSWORD`。不要将配置值粘贴到聊天、命令输出或版本库。`SMTP_TLS=starttls/ssl` 校验证书与主机名；`none` 只允许回环测试收件服务。`/health/ready` 的 mail 项只说明配置有效，外部收件箱实际送达必须另行确认。

从 `backend` 目录运行本轮账号回归：

```powershell
.venv/Scripts/python.exe -m unittest -v test_development_mailbox test_account_recovery test_operations
.venv/Scripts/python.exe -m unittest discover -v
```

`test_operations` 使用随机回环端口和临时账号，真实通过 SMTP 协议接收验证/重置邮件，再确认链接、撤销旧会话并用新密码登录；不会访问外部 SMTP 或向第三方发送测试邮件。它验证本机 SMTP 链路，不代替生产邮件服务器或收件箱送达验收。
