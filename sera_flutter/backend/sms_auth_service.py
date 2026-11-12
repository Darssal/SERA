"""Alibaba Cloud PNVS SMS authentication, independent of account mutations.

Only the official provider creates/checks codes. Tests may inject a provider;
there is no development code, local delivery mode, or successful fallback.
"""
from dataclasses import dataclass, field
import hashlib
import json
import os
import re

from sms_auth_store import (SmsAuthError, SmsAuthStore, SmsPolicy, masked_phone,
                            normalize_phone, timestamp)


class SmsProviderError(SmsAuthError):
    def __init__(self, message='短信服务暂时不可用，请稍后重试或使用邮箱登录。', *, uncertain=False,
                 status=503, code='sms_provider_unavailable'):
        super().__init__(message, status, code)
        self.uncertain = uncertain


@dataclass(frozen=True)
class PnvsConfig:
    access_key_id: str = field(repr=False)
    access_key_secret: str = field(repr=False)
    sign_name: str
    scheme_name: str = 'SERA'
    login_template: str = '100001'
    bind_template: str = '100004'
    sensitive_template: str = '100005'
    security_token: str | None = field(default=None, repr=False)
    allowed_test_phones: tuple = field(default=(), repr=False)
    timeout_ms: int = 8000


class AliyunPnvsProvider:
    """Synchronous SDK adapter; call from FastAPI's synchronous threadpool routes."""
    configured = True

    def __init__(self, config, *, client=None):
        # Import lazily: an installation without PNVS configuration can keep
        # using email login even before optional provider dependencies install.
        from alibabacloud_dypnsapi20170525.client import Client
        from alibabacloud_dypnsapi20170525 import models
        from alibabacloud_tea_openapi.models import Config
        from alibabacloud_tea_util.models import RuntimeOptions
        self.config, self.models, self.runtime_class = config, models, RuntimeOptions
        sdk_config = Config(access_key_id=config.access_key_id,
                            access_key_secret=config.access_key_secret,
                            security_token=config.security_token,
                            endpoint='dypnsapi.aliyuncs.com', protocol='HTTPS')
        self.client = client or Client(sdk_config)

    def _runtime(self):
        return self.runtime_class(autoretry=False, max_attempts=1,
                                  connect_timeout=self.config.timeout_ms,
                                  read_timeout=self.config.timeout_ms,
                                  ignore_ssl=False)

    def _scheme_name(self, out_id):
        # OutId is documented as passthrough and may only be echoed, rather
        # than selecting a particular code. PNVS looks up phone + SchemeName.
        # Isolate every local challenge so an older delayed send can neither
        # overwrite a new code nor authenticate under the new challenge.
        namespace = self.config.scheme_name + ':' + out_id
        return 's' + hashlib.sha256(namespace.encode()).hexdigest()[:19]

    @staticmethod
    def _response(response, out_id):
        # Do not stringify the response: it may include provider-returned codes,
        # diagnostic request bodies, credentials, or phone numbers.
        body = getattr(response, 'body', None)
        if not body or getattr(body, 'code', None) != 'OK' or getattr(body, 'success', None) is not True:
            provider_code = getattr(body, 'code', None)
            if provider_code == 'OFFER_NOT_ORDER_STATUS':
                raise SmsProviderError('短信认证服务的开通或订单状态未就绪，请在阿里云号码认证控制台核对该凭据所属账号。',
                                       code='sms_service_order_unavailable')
            if provider_code in ('FREQUENCY_FAIL', 'BUSINESS_LIMIT_CONTROL'):
                raise SmsProviderError('短信请求已达到服务限制，请稍后重试或使用邮箱登录。', status=429, code='sms_provider_rate_limited')
            raise SmsProviderError()
        model = getattr(body, 'model', None)
        # Require exact provider correlation. A missing/mismatching OutId must
        # never turn a successful unrelated check into account authentication.
        if not model or getattr(model, 'out_id', None) != out_id:
            raise SmsProviderError('短信服务返回结果异常，请稍后重试。', uncertain=True)
        return model

    @staticmethod
    def _sdk_failure(error, *, sending):
        # Some SDK versions raise for a non-2xx API rejection before returning
        # a response model. Inspect only an allowlist of machine codes, never
        # stringify/log the exception (it may include request credentials).
        code = getattr(error, 'code', None)
        if code == 'OFFER_NOT_ORDER_STATUS':
            return SmsProviderError('短信认证服务的开通或订单状态未就绪，请在阿里云号码认证控制台核对该凭据所属账号。',
                                    code='sms_service_order_unavailable')
        if code in ('FREQUENCY_FAIL', 'BUSINESS_LIMIT_CONTROL'):
            return SmsProviderError('短信请求已达到服务限制，请稍后重试或使用邮箱登录。', status=429, code='sms_provider_rate_limited')
        if code in ('FUNCTION_NOT_OPENED', 'MOBILE_NUMBER_ILLEGAL', 'INVALID_PARAMETERS',
                    'MissingParameter', 'InvalidAccessKeyId.NotFound', 'InvalidAccessKeyId',
                    'SignatureDoesNotMatch', 'Forbidden.NoPermission', 'AccessDenied'):
            return SmsProviderError()
        if sending:
            return SmsProviderError('短信发送状态暂时无法确认。如已收到验证码请继续输入；倒计时结束后可重试。',
                                    uncertain=True, code='sms_delivery_unknown')
        return SmsProviderError('验证码暂时无法核验，请保留输入并稍后重试。', code='sms_verification_unavailable')

    def send(self, *, phone, purpose, out_id, valid_seconds, cooldown_seconds):
        if self.config.allowed_test_phones and phone not in self.config.allowed_test_phones:
            raise SmsProviderError('当前短信服务仅开放已授权的测试号码。', status=403, code='sms_phone_not_allowed')
        template = {'login': self.config.login_template, 'bind_phone': self.config.bind_template,
                    'sensitive': self.config.sensitive_template}[purpose]
        request = self.models.SendSmsVerifyCodeRequest(
            phone_number=phone[3:], country_code='86', sign_name=self.config.sign_name,
            scheme_name=self._scheme_name(out_id), template_code=template,
            template_param=json.dumps({'code': '##code##', 'min': str((valid_seconds + 59) // 60)}, separators=(',', ':')),
            out_id=out_id, valid_time=valid_seconds, interval=cooldown_seconds,
            code_length=6, code_type=1, duplicate_policy=1,
            return_verify_code=False, auto_retry=0)
        try:
            response = self.client.send_sms_verify_code_with_options(request, self._runtime())
        except Exception as error:
            # No SDK retry. The network could have timed out AFTER acceptance.
            # Keep the challenge so the user can type a code that still arrives.
            raise self._sdk_failure(error, sending=True) from None
        self._response(response, out_id)

    def verify(self, *, phone, out_id, code):
        request = self.models.CheckSmsVerifyCodeRequest(
            phone_number=phone[3:], country_code='86', scheme_name=self._scheme_name(out_id),
            out_id=out_id, verify_code=code, case_auth_policy=2)
        try:
            response = self.client.check_sms_verify_code_with_options(request, self._runtime())
        except Exception as error:
            raise self._sdk_failure(error, sending=False) from None
        model = self._response(response, out_id)
        result = getattr(model, 'verify_result', None)
        if result not in ('PASS', 'UNKNOWN'):
            raise SmsProviderError('短信服务返回结果异常，请稍后重试。')
        return result == 'PASS'


class SmsAuthService:
    def __init__(self, store, provider=None, *, disabled_message=None):
        self.store, self.provider = store, provider
        self.disabled_message = disabled_message or '短信登录暂未启用，请使用邮箱登录。'

    @classmethod
    def from_env(cls, path, env=None):
        env = os.environ if env is None else env
        enabled = str(env.get('SERA_SMS_AUTH_ENABLED', 'false')).lower() in ('1', 'true', 'yes')
        try:
            quotas = {name: int(env.get(key, default)) for name, key, default in (
                ('phone_hour_limit', 'SERA_SMS_PHONE_HOUR_LIMIT', 5),
                ('phone_day_limit', 'SERA_SMS_PHONE_DAY_LIMIT', 10),
                ('ip_minute_limit', 'SERA_SMS_IP_MINUTE_LIMIT', 5),
                ('ip_hour_limit', 'SERA_SMS_IP_HOUR_LIMIT', 20),
                ('global_hour_limit', 'SERA_SMS_GLOBAL_HOUR_LIMIT', 50),
                ('global_day_limit', 'SERA_SMS_GLOBAL_DAY_LIMIT', 100))}
            policy = SmsPolicy(**quotas)
        except (TypeError, ValueError):
            return cls(SmsAuthStore(path), disabled_message='短信服务限额配置无效，暂不可用，请使用邮箱登录。')
        store = SmsAuthStore(path, policy=policy)
        if not enabled:
            return cls(store)
        key = env.get('SERA_SMS_ACCESS_KEY_ID', '')
        secret = env.get('SERA_SMS_ACCESS_KEY_SECRET', '')
        sign = env.get('SERA_SMS_SIGN_NAME', '')
        scheme = env.get('SERA_SMS_SCHEME_NAME', 'SERA')
        if (not key or not secret or not sign or not isinstance(scheme, str) or not 1 <= len(scheme) <= 20):
            return cls(store, disabled_message='短信服务尚未完成配置，请使用邮箱登录。')
        try:
            allowed = tuple(normalize_phone(phone) for phone in env.get('SERA_SMS_ALLOWED_TEST_PHONES', '').split(',') if phone.strip())
            config = PnvsConfig(key, secret, sign, scheme_name=scheme,
                login_template=env.get('SERA_SMS_TEMPLATE_LOGIN', '100001'),
                bind_template=env.get('SERA_SMS_TEMPLATE_BIND', '100004'),
                sensitive_template=env.get('SERA_SMS_TEMPLATE_SENSITIVE', '100005'),
                security_token=env.get('SERA_SMS_SECURITY_TOKEN') or None, allowed_test_phones=allowed)
            # Only PNVS system templates for the corresponding purpose.
            if not all(re.fullmatch(r'[0-9]{6}', value) for value in
                       (config.login_template, config.bind_template, config.sensitive_template)):
                raise ValueError('Invalid PNVS template')
            provider = AliyunPnvsProvider(config)
        except (ImportError, TypeError, ValueError, SmsAuthError):
            return cls(store, disabled_message='短信服务配置或依赖不可用，请使用邮箱登录。')
        return cls(store, provider)

    @property
    def configured(self):
        return self.provider is not None and bool(getattr(self.provider, 'configured', True))

    def capabilities(self):
        return {'enabled': self.configured, 'message': '支持中国大陆手机号，验证码有效期为 5 分钟。' if self.configured else self.disabled_message,
                'codeLength': 6, 'cooldownSeconds': self.store.policy.cooldown_seconds}

    def _require_enabled(self):
        if not self.configured:
            raise SmsAuthError(self.disabled_message, 503, 'sms_auth_disabled')

    def send(self, phone, *, purpose='login', source_ip, owner_uid=None, session_token=None):
        self._require_enabled()
        challenge = self.store.reserve_send(phone, purpose=purpose, source_ip=source_ip,
                                            owner_uid=owner_uid, session_token=session_token)
        delivery_status, message = 'submitted', '验证码已提交发送，请查看手机短信。'
        try:
            self.provider.send(phone=challenge['phone'], purpose=purpose, out_id=challenge['out_id'],
                               valid_seconds=self.store.policy.valid_seconds,
                               cooldown_seconds=self.store.policy.cooldown_seconds)
        except SmsProviderError as error:
            self.store.complete_send(challenge['id'], 'unknown' if error.uncertain else 'failed')
            if not error.uncertain:
                raise
            delivery_status, message = 'unknown', str(error)
        except Exception:
            self.store.complete_send(challenge['id'], 'unknown')
            delivery_status = 'unknown'
            message = '短信发送状态暂时无法确认。如已收到验证码请继续输入；倒计时结束后可重试。'
        else:
            self.store.complete_send(challenge['id'], 'submitted')
        return {'challengeId': challenge['id'], 'maskedPhone': masked_phone(challenge['phone']),
                'expiresAt': timestamp(challenge['expires_at']), 'resendAt': timestamp(challenge['resend_at']),
                'retryAfterSeconds': max(0, challenge['resend_at'] - int(self.store.clock())),
                'deliveryStatus': delivery_status, 'message': message}

    def challenge_phone(self, challenge_id, *, purpose='login', owner_uid=None, session_token=None):
        self._require_enabled()
        return self.store.challenge_phone(challenge_id, purpose=purpose, owner_uid=owner_uid, session_token=session_token)

    def verify(self, challenge_id, code, *, purpose='login', owner_uid=None, session_token=None):
        self._require_enabled()
        if not isinstance(code, str) or not re.fullmatch(r'[0-9]{6}', code):
            raise SmsAuthError('请输入 6 位数字验证码。', code='invalid_sms_code_format')
        challenge = self.store.begin_verification(challenge_id, purpose=purpose, owner_uid=owner_uid, session_token=session_token)
        try:
            passed = self.provider.verify(phone=challenge['phone'], out_id=challenge['out_id'], code=code)
        except SmsProviderError:
            self.store.complete_verification(challenge, provider_error=True)
            raise
        except Exception:
            self.store.complete_verification(challenge, provider_error=True)
            raise SmsProviderError('验证码暂时无法核验，请保留输入并稍后重试。', code='sms_verification_unavailable') from None
        return self.store.complete_verification(challenge, passed=passed is True)
