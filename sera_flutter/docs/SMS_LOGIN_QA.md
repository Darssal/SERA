# 手机号登录与身份管理验收

本轮范围为 PNVS 短信验证码登录，保留邮箱密码登录。未配置时必须显示未启用；只有隔离测试使用 mock provider，不将模拟成功当作真实短信送达。

## 接口与身份流

| 操作 | 接口 | 验证与结果 |
| --- | --- | --- |
| 检查能力 | GET /api/v1/auth/phone/capabilities | enabled/message，不返回任何云凭据 |
| 获取验证码 | POST /api/v1/auth/phone/challenge | phone、purpose，bind_phone 另带 currentPassword；返回 challengeId/到期/重发时间/真实提交状态 |
| 登录或同意后注册 | POST /api/v1/auth/phone/login | challengeId/code/acceptRegistration；新号未同意不验码不建号，已有号登录原账号 |
| 绑定手机号 | POST /api/v1/auth/phone/bind | 当前密码+目标手机验证码；手机号已属于其他账号即拒绝 |
| 最近身份验证 | POST /api/v1/auth/phone/verify-sensitive | 已绑定当前手机号的验证码；返回 5 分钟、一次性、同账号同会话证明 |
| 请求绑定邮箱 | POST /api/v1/auth/email/bind/request | 当前身份验证+目标邮箱；发送绑定邮件，尚不附加邮箱 |
| 确认绑定邮箱 | POST /api/v1/auth/email/bind/confirm | 同一发起会话+目标邮箱邮件 token；唯一性再次校验并附加已验证邮箱 |
| 设置密码 | POST /api/v1/auth/password/set | 最近身份验证+10至128位新密码；撤销其他会话，保留当前工作区 |
| 注销 | DELETE /api/v1/account | 原有密码或最近手机证明；级联删除账号数据，短期额度防滥用记录按保留策略处理 |
| 导出 | GET /api/v1/account/export | 现有会话，仅当前账号；不导出哈希/验证码/证明 |

手机新账号的 email/salt/password_hash 为 NULL，前端显示“尚未绑定/尚未设置”。用户名由服务端随机生成，并可在账号页看到。设置密码后可使用用户名，或随后绑定并验证的邮箱，走原有密码登录。当前不支持直接替换已绑定手机号/邮箱；不能通过“绑定”合并两个账号。

## 集成方串行命令

下列命令由唯一 Flutter/设备 runner 执行；短信专项只做独立后端测试和自己文件的 Dart 格式化。

```powershell
& 'D:/development/flutter/bin/flutter.bat' analyze
& 'D:/development/flutter/bin/flutter.bat' test test/phone_auth_repository_test.dart test/phone_auth_screen_test.dart test/auth_repository_test.dart test/account_recovery_test.dart test/account_voice_ui_test.dart
& 'D:/development/flutter/bin/flutter.bat' test
# backend 目录，临时数据库、无云服务调用
& '.venv/Scripts/python.exe' -m unittest discover -s . -p 'test_*.py' -v
& '.venv/Scripts/python.exe' -m pip check
```

app.dart 的四个路由和启动环境白名单接入见 `.local/coordination/20261031-feedback/login-integration.md`。最终 Web/APK/AAB 只在全部 ready 冻结后统一构建。MuMu 仅设备1 `127.0.0.1:16416`；不卸载正式包、不清用户数据。

## 回归矩阵

| 场景 | 需观察结果 |
| --- | --- |
| 未开通/缺凭据 | 手机页明确未启用、发码不能成功，邮箱登录/注册/找回继续可用 |
| 新号 | 输入大陆手机号→发码→手填验证码；不勾选同意时不建号，勾选后独立账号，进入初次设置 |
| 旧邮箱账号 | 邮箱密码登录→账户页当前密码+目标手机验证码→绑定；随后短信登录仍是相同userId/任务/工作区 |
| 冲突 | 手机A已属于账号A，账号B绑定被拒绝；两边工作区、会话、导出不合并 |
| 重发/错误/到期 | 倒计时持久受控；旧挑战和旧码不能登录；错误次数耗尽后须新挑战；不无限调用供应商 |
| 超时/供应商拒绝 | 保留手机号与验证码；unknown只表示发送状态未确认，可能到码仍可输入；不自动重发 |
| 无密码账号 | 能导出；注销、邮箱绑定、设置密码须重新验证当前手机，不要求不存在的密码 |
| 完善邮箱 | 邮件明确显示 local/SMTP 的实际状态；未确认前email为空；原会话粘贴链接确认，刷新已验证 |
| 会话切换 | 旧请求、旧挑战/证明、跨账号链接均不可改变新账号；敏感证明跨另一会话拒绝 |
| 退出或离页 | 手机页退出后迟到响应不采用为本地会话；敏感proof只在内存，页面/会话变化清空 |
| Web | HttpOnly Cookie、CSRF、跨标签旧请求、注销迟到响应、离页期间登录Cookie时序需浏览器验证 |
| Android | Bearer继续用安全存储；键盘与窄屏按钮可达、返回时输入恢复、账号切换后无旧账号数据 |
| 注销后 | 所有会话失效、工作区/队列/订阅/证明级联清除，其他账号仍可读取；额度不能通过重建绕过 |

## 真实短信联调边界

用户须在自己的阿里云账户完成个人实名、PNVS短信认证开通和RAM配置。私有配置只放 `.local/sms-auth.env`，不写聊天/日志/构建产物；授权测试号码进入测试白名单。集成方加载配置后，由用户本人收码并手填，少量测试真实 send/check、服务端挑战场景名、重发失效和错误恢复。没有授权号码时不从私人资料推断、不发送。

正式迁移前必须用 SQLite backup API 备份真实数据库；迁移为事务性版本2，不能在已经产生手机号身份后直接降级旧 schema。备份和回退约束详见 identity-integration.md。当前隔离测试不能证明真实SIM送达、云端开通、不同系统版本或公网TLS部署已通过。
