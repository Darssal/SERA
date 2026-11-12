"""SMTP delivery with an explicit local development mail sink."""
from email.message import EmailMessage
import json
import os
from pathlib import Path
import secrets
import smtplib
import ssl
from urllib.parse import parse_qs, urlsplit
from auth_store import AuthError


class MailService:
    def __init__(self, directory, mode=None):
        self.directory = Path(directory)
        self.mode = mode or os.environ.get('SERA_MAIL_MODE', 'local')

    @staticmethod
    def public_origin():
        # Never derive security-action links from an untrusted Host header.
        origin = os.environ.get('SERA_PUBLIC_ORIGIN', 'http://127.0.0.1:8787').rstrip('/')
        try:
            parsed = urlsplit(origin)
            if (parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or
                    parsed.path or parsed.query or parsed.fragment or parsed.netloc.endswith(':') or
                    any(character.isspace() for character in origin) or
                    (parsed.scheme == 'http' and parsed.hostname not in ('localhost', '127.0.0.1', '::1'))):
                raise ValueError()
            parsed.port  # Reject invalid or out-of-range ports before sending links.
        except (ValueError, IndexError):
            raise AuthError('SERA_PUBLIC_ORIGIN 必须为有效 HTTPS 站点或本机 HTTP 地址。', 503, 'mail_configuration_error') from None
        return origin

    def action_link(self, kind, token):
        if kind not in ('verify', 'reset', 'bind'):
            raise AuthError('Invalid mail action')
        route = '/#/verify-email' if kind == 'verify' else '/#/phone-email' if kind == 'bind' else '/#/reset-password'
        return self.public_origin() + route + '?token=' + token

    def delivery_metadata(self):
        local = self.mode == 'local'
        mailpit = self.mode == 'mailpit'
        return {'delivery': self.mode, 'deliveryMode': self.mode, 'developmentPreview': local,
                'deliveryStatus': 'development_only' if local else 'mailpit_accepted' if mailpit else 'smtp_accepted',
                'message': ('当前使用本地开发邮箱，邮件未投递到外部收件箱，请打开开发验证邮件。' if local else
                            '邮件已交给 Mailpit 开发收件箱，未投递到外部收件箱。' if mailpit else
                            '邮件已交给 SMTP 服务，请检查收件箱和垃圾邮件；实际送达仍由邮件服务决定。')}

    def reset_request_metadata(self):
        # This response describes the request, never account existence or delivery.
        detail = ('当前为本地开发邮件模式，邮件仅保存在服务端本机，不会投递到外部收件箱；'
                  '请由本机开发者查看重置邮件，应用不会公开重置链接。' if self.mode == 'local' else
                  '当前为 Mailpit 开发收件箱模式，邮件不会投递到外部收件箱。' if self.mode == 'mailpit' else
                  '如邮箱已注册且未超出请求限制，系统会尝试发送重置邮件，请检查收件箱和垃圾邮件。')
        return {'accepted': True, 'delivery': self.mode, 'deliveryMode': self.mode,
                'developmentPreview': False, 'deliveryStatus': 'request_accepted',
                'message': '重置申请已受理；仅为符合条件的已注册邮箱处理邮件。' + detail}

    def smtp_configuration(self):
        if self.mode not in ('smtp', 'mailpit'):
            raise AuthError('不支持的邮件模式。', 503, 'mail_configuration_error')
        try:
            host = 'mailpit' if self.mode == 'mailpit' else os.environ['SMTP_HOST']
            tls = 'none' if self.mode == 'mailpit' else os.environ.get('SMTP_TLS', 'starttls')
            sender = os.environ.get('SMTP_FROM') or ('sera@localhost' if self.mode == 'mailpit' else '')
            if (not host or any(character.isspace() for character in host) or
                    not sender or '\r' in sender or '\n' in sender or '@' not in sender):
                raise ValueError()
            if tls not in ('none', 'starttls', 'ssl'):
                raise AuthError('SMTP_TLS 必须为 starttls、ssl 或本机 none。', 503, 'mail_configuration_error')
            if tls == 'none' and self.mode != 'mailpit' and host not in ('localhost', '127.0.0.1', '::1'):
                raise AuthError('非本机 SMTP 必须启用 TLS。', 503, 'mail_configuration_error')
            port = 1025 if self.mode == 'mailpit' else int(os.environ.get('SMTP_PORT', '587'))
            if not 1 <= port <= 65535:
                raise ValueError()
            if self.mode != 'mailpit' and os.environ.get('SMTP_USERNAME') and not os.environ.get('SMTP_PASSWORD'):
                raise ValueError()
            return host, port, tls, sender
        except (KeyError, ValueError):
            raise AuthError('邮件配置无效，请检查 SMTP 主机、端口、发件人与认证配置。', 503, 'mail_configuration_error') from None

    def check_configuration(self):
        self.public_origin()
        if self.mode != 'local': self.smtp_configuration()

    def development_verification(self, accounts, user):
        if self.mode != 'local':
            raise AuthError('当前邮件模式不提供开发邮件预览。', 403, 'development_mailbox_disabled')
        result = {'deliveryMode': 'local', 'mail': None,
                  'message': '当前使用本地开发邮箱，邮件不会发送到外部收件箱。'}
        if user['emailVerified']:
            result['message'] = '当前账号邮箱已验证。'
            return result
        candidates = []
        if self.directory.is_dir():
            for path in self.directory.glob('*.json'):
                try:
                    if path.is_symlink() or path.stat().st_size > 64 * 1024:
                        continue
                    value = json.loads(path.read_text(encoding='utf-8'))
                    if (not isinstance(value, dict) or value.get('kind') != 'verify' or
                            not isinstance(value.get('to'), str) or value['to'].casefold() != user['email'].casefold()):
                        continue
                    link = value.get('link')
                    if not isinstance(link, str):
                        continue
                    fragment = urlsplit(link).fragment
                    route, separator, query = fragment.partition('?')
                    values = parse_qs(query, strict_parsing=True)
                    tokens = values.get('token', [])
                    if route != '/verify-email' or not separator or len(tokens) != 1:
                        continue
                    expiry = accounts.active_verification_action(user['id'], tokens[0])
                    if expiry:
                        candidates.append({'subject': 'SERA 邮箱验证',
                            'verificationUrl': self.action_link('verify', tokens[0]), 'expiresAt': expiry})
                except (OSError, ValueError, TypeError):
                    continue
        if candidates:
            result['mail'] = max(candidates, key=lambda item: item['expiresAt'])
        else:
            result['message'] = '没有当前账号有效的开发验证邮件，请先重新发送。'
        return result

    def send_action(self, recipient, kind, token):
        link = self.action_link(kind, token)
        subject = 'SERA 邮箱验证' if kind == 'verify' else 'SERA 绑定邮箱验证' if kind == 'bind' else 'SERA 密码重置'
        body = f'{subject}\n\n请在有效期内打开：{link}\n\n如果不是你本人操作，请忽略。'
        if self.mode == 'local':
            try:
                self.directory.mkdir(parents=True, exist_ok=True)
                path = self.directory / (secrets.token_hex(12) + '.json')
                path.write_text(json.dumps({'to': recipient, 'subject': subject, 'kind': kind,
                                            'link': link, 'text': body}, ensure_ascii=False), encoding='utf-8')
            except OSError:
                raise AuthError('本地开发邮件保存失败，请检查邮件目录权限。', 503, 'mail_delivery_failed') from None
            return
        host, port, tls, sender = self.smtp_configuration()
        message = EmailMessage()
        message['Subject'], message['From'], message['To'] = subject, sender, recipient
        message.set_content(body)
        try:
            factory = smtplib.SMTP_SSL if tls == 'ssl' else smtplib.SMTP
            options = {'context': ssl.create_default_context()} if tls == 'ssl' else {}
            with factory(host, port, timeout=15, **options) as client:
                if tls == 'starttls': client.starttls(context=ssl.create_default_context())
                if self.mode != 'mailpit' and os.environ.get('SMTP_USERNAME'):
                    client.login(os.environ['SMTP_USERNAME'], os.environ['SMTP_PASSWORD'])
                client.send_message(message)
        except (smtplib.SMTPException, OSError, KeyError, ValueError):
            raise AuthError('邮件服务发送失败，请检查 SMTP 配置后重试。', 503, 'mail_delivery_failed') from None
