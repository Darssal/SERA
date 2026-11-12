# PNVS 短信验证码接入

本模块调用阿里云号码认证 PNVS 的 `SendSmsVerifyCode` 和 `CheckSmsVerifyCode`。它不使用普通短信 SMS API，不生成本地验证码，也不提供开发万能码。没有配置时，能力接口明确返回短信尚未启用，邮箱登录继续可用。

## 当前完成与未验证

- 已实现官方 Python SDK 2.0.0 适配、SQLite 持久化挑战、限流、一次性消费、并发和重放防护。
- 隔离测试只使用临时数据库与注入的 fake provider / fake SDK transport；不调用真实阿里云服务。
- 尚无用户提供的 RAM 配置和授权测试号码，因此尚未验证服务开通、真实发送、运营商送达或实际收码。接口返回 `submitted` 只代表供应商接受发码请求，不代表手机已收到。

## 用户在阿里云完成的准备

1. 用自己的阿里云账号完成个人实名认证，并在号码认证 PNVS 控制台开通“短信认证”。不需要安装运营商客户端 SDK。
2. 创建专用 RAM 凭据，并按最小权限授予 `dypns:SendSmsVerifyCode`、`dypns:CheckSmsVerifyCode`，资源为 `*`。也可使用带安全令牌的临时 STS 凭据。
3. 从 PNVS 控制台“短信认证参数配置”选择系统赠送签名和对应系统模板。签名不能与普通短信 SMS 模板混用。
4. 根据个人预算自行决定按量付费或充值/购买。当前官方主计费页显示月量不超过 1000 时短信认证 API 为 0.06 元/次，1000 次资源包为 54 元。普通 SMS 的资源包不可抵扣 PNVS 短信认证。

开发代理不会代办实名、充值、购买或猜测测试手机号。真实联调仅向用户明确授权的号码少量发送。

## 私有配置

将 `backend/sms-auth.env.example` 中的配置复制到 `sera_flutter/.local/sms-auth.env`。该目录已被工程忽略且排除交付，文件应仅允许当前 Windows 用户和 SYSTEM 读取。不要把真实值写入源码、聊天、日志、Web 构建参数、Android 资源或截图。

主要配置键：

| 键 | 含义 |
| --- | --- |
| `SERA_SMS_AUTH_ENABLED` | 默认 `false`，完整配置后手动设为 `true` |
| `SERA_SMS_ACCESS_KEY_ID` / `SERA_SMS_ACCESS_KEY_SECRET` | 专用 RAM 凭据，仅后端使用 |
| `SERA_SMS_SECURITY_TOKEN` | 可选 STS 临时安全令牌 |
| `SERA_SMS_SIGN_NAME` | 控制台显示的系统赠送签名 |
| `SERA_SMS_SCHEME_NAME` | 挑战方案命名空间，默认 `SERA`，最多 20 字符；实际供应商方案名按挑战唯一派生 |
| `SERA_SMS_TEMPLATE_LOGIN` | 登录/注册模板，默认 `100001` |
| `SERA_SMS_TEMPLATE_BIND` | 绑定新手机号模板，默认 `100004` |
| `SERA_SMS_TEMPLATE_SENSITIVE` | 验证已绑定手机号模板，默认 `100005` |
| `SERA_SMS_ALLOWED_TEST_PHONES` | 联调时填入明确授权号码；逗号分隔。留空代表不增加测试白名单限制 |

仅支持中国大陆手机号；内部统一为 `+86` 加 11 位手机号。SDK 使用 `CountryCode=86` 和不带国家码的 `PhoneNumber`。

环境文件必须在创建 FastAPI app / `SmsAuthService.from_env()` 前显式加载。`from_env` 本身不读取磁盘、不扫描私人资料，也不接受客户端覆盖凭据。启动脚本由 UI 集成所有者负责，需加入上述配置键与下述限额键的白名单；不能把整份环境文件打印到控制台。主服务只由集成方重启。

## 供应商调用与失败恢复

发码使用系统占位参数 `{"code":"##code##","min":"5"}`，有效期 300 秒，6 位纯数字，`ReturnVerifyCode=false`、`DuplicatePolicy=1`、`AutoRetry=0`。SDK 使用 HTTPS、证书验证、连接/读取超时各 8 秒；客户端运行时自动重试关闭，最多 1 次请求。

每次挑战用 `s` 加 `SHA256(命名空间 + ":" + 随机 OutId)` 的前 19 个十六进制字符派生一个 20 字符 `SchemeName`；发码和验码使用完全相同的派生值。官方 `SchemeName` 参数允许最多 20 字符的名称。`OutId` 的官方描述是外部流水号透传，不能仅凭回显推断其参与验证码查找；独立挑战方案保证迟到的旧发码不能覆盖新挑战，旧码也不能跨挑战或用途核验。真实账号下的动态方案行为仍须在受控联调中验证。

验码同时传入 `PhoneNumber`、本挑战派生的 `SchemeName`、本地挑战对应的随机 `OutId` 与用户输入验证码。只有供应商返回 `Code=OK`、`Success=true`、精确匹配的 `OutId` 和 `Model.VerifyResult=PASS` 才能获得内部验证证明；仅接口请求成功不代表验证码正确。

发送前先事务性持久化挑战、冷却和额度预留。超时可能发生在供应商已接受请求之后，此时响应为 `deliveryStatus=unknown`，保留 `challengeId`、输入、有效期和重发倒计时。收到验证码后仍可验码；客户端不能自动重发。明确的未开通、权限、参数或频率拒绝返回不可用/限流错误，不宣称发送成功。

验证码、RAM 密钥、SDK 原始错误、原始供应商响应均不写数据库或日志。供应商返回的 `VerifyCode` 字段不会被读取或转交。

## 持久化与安全边界

- `sms_auth_challenges` 与账号使用同一 SQLite 文件。发送、失败、超时均计入限额，重启或换工作进程不重置。
- 默认号码冷却 60 秒；每手机号每小时 5 次、24 小时 10 次；每来源 IP 每分钟 5 次、每小时 20 次；服务总量每小时 50 次、24 小时 100 次。使用 `SERA_SMS_PHONE_HOUR_LIMIT`、`SERA_SMS_PHONE_DAY_LIMIT`、`SERA_SMS_IP_MINUTE_LIMIT`、`SERA_SMS_IP_HOUR_LIMIT`、`SERA_SMS_GLOBAL_HOUR_LIMIT`、`SERA_SMS_GLOBAL_DAY_LIMIT` 可调整，非法配置会禁用短信。
- 来源只信任服务端看到的实际连接地址；任意客户端 `X-Forwarded-For` 不可信。部署反向代理时，必须由部署方仅为真实可信代理配置转发地址信任。若所有流量共用代理 IP，会共同受 IP 限额约束。
- 每挑战最多 5 次验证码检查；尝试次数先提交，错误抛出不会回滚。发送与验证期间都不持有 SQLite 写事务。
- 一次只允许一个供应商验码请求。工作进程在请求期间退出时，挑战保持处理中，不能用超时租约自动重新获取并行验码；用户在冷却后重新发码恢复。
- 重发使同手机号所有旧用途挑战失效。迟到的验码成功必须通过随机请求栅栏和挑战状态检查，不能恢复旧挑战。
- `bind_phone`、`sensitive` 必须同时绑定当前账号 ID 和当前会话哈希。预留付费发送前，在同一写事务内重新查询账号与未过期会话；账号或会话被删除/撤销时拒绝预留且不调用供应商。`sensitive` 只能发到当前绑定手机号，`bind_phone` 要求账号尚未绑定手机号。登录挑战不能转为绑定/敏感操作证明。
- 成功验码只返回服务端内部 `VerifiedSmsClaim`，不序列化到客户端。账号事务必须用 `consume_claim(db, claim)` 同事务消费；有效证明最长保留 60 秒，账户创建、绑定失败则整体回滚。
- 新手机号注册的同意检查、已有账号身份检查、手机号唯一约束与账号隔离由账号层负责；路由应在调用真实验码前完成这些预检查。不得静默合并账号。
- 注销账号时，账号事务调用 `delete_account_data(db, uid)` 撤销挑战并移除账号/会话关联。必要的号码及来源哈希滥用防护记录保留至最多 48 小时，下一次发码预留时清理；避免注销重建绕过短信费用限额。

## 隔离测试

从 `sera_flutter/backend` 运行：

```powershell
& '.venv/Scripts/python.exe' -m unittest test_sms_auth -v
& '.venv/Scripts/python.exe' -m pip check
```

真实联调前需先由集成方统一验证邮箱、手机新账号、跨账号绑定冲突、旧挑战重放、账号注销和 Web Cookie/CSRF / Android Bearer 回归，再在已配置的测试白名单内人工收码。不得把上述隔离 mock 测试标为真实短信送达证据。

## 官方依据（2026-10-31 核对）

- [个人开发者接入指南](https://help.aliyun.com/zh/pnvs/use-cases/sms-verify-for-individual-developers)
- [SendSmsVerifyCode 参数](https://help.aliyun.com/en/pnvs/developer-reference/api-dypnsapi-2017-05-25-sendsmsverifycode)
- [CheckSmsVerifyCode 参数和 PASS 判定](https://help.aliyun.com/en/pnvs/developer-reference/api-dypnsapi-2017-05-25-checksmsverifycode)
- [预置签名与模板](https://help.aliyun.com/en/pnvs/user-guide/sms-authentication-service)
- [当前官方主计费页](https://help.aliyun.com/zh/pnvs/product-overview/product-pricing/)
- [官方 SDK 2.0.0 变更记录](https://github.com/aliyun/alibabacloud-python-sdk/blob/master/dypnsapi-20170525/ChangeLog.md)
