"""Small, read-only public-web tools. No API key or model credentials are used.

The tool caller must keep one PublicWebSession for one understanding operation.
Only exact search-result URLs (and their checked same-host/www redirects) can be
read. Returned snippets/page text are untrusted source material, not instructions.
No cookies, browser sessions, credentials, arbitrary request headers or POSTs are
accepted. Public HTTPS only; DNS is checked and the connection is pinned to a
checked address while retaining the original TLS SNI/certificate hostname. The
fixed search-engine hosts may use the explicitly trusted proxy's remote DNS;
model/user input changes only the query, never those hosts, paths or redirects.

SERA_PUBLIC_WEB_PROXY is an optional *server-side* setting. Only the project's
fixed http://127.0.0.1:10808 development proxy is supported; ambient HTTP_PROXY,
HTTPS_PROXY and certificate environment variables are never trusted.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from contextvars import ContextVar
from copy import deepcopy
from datetime import datetime, timezone
from hashlib import sha256
from html.parser import HTMLParser
import ipaddress
import json
import math
import os
import re
import socket
import ssl
import threading
import time
from typing import Callable
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit
import xml.etree.ElementTree as ET

import httpx
import certifi


MAX_BODY_BYTES = 384 * 1024
MAX_PAGE_CHARS = 24000
MAX_RESULTS = 6
SEARCH_TTL_SECONDS = 120
PAGE_TTL_SECONDS = 180
URL_TTL_SECONDS = 300
REQUEST_TIMEOUT_SECONDS = 6.0
OPERATION_TIMEOUT_SECONDS = 18.0
MAX_REDIRECTS = 3
_USER_AGENT = 'Mozilla/5.0 (compatible; SeraPublicWeb/1.0)'
_SEARCH_HOST_PATHS = {'html.duckduckgo.com': {'/html', '/html/'},
                      'duckduckgo.com': {'/html', '/html/'},
                      'www.duckduckgo.com': {'/html', '/html/'},
                      'www.bing.com': {'/search'}, 'cn.bing.com': {'/search'},
                      'www.so.com': {'/s'}, 'so.com': {'/s'}}
_CURRENT: ContextVar[PublicWebSession | None] = ContextVar('sera_public_web_session', default=None)
_DNS_POOL = ThreadPoolExecutor(max_workers=4, thread_name_prefix='sera-public-dns')
_DNS_SLOTS = threading.BoundedSemaphore(4)
_VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
_HIDDEN = {'script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe', 'object', 'nav', 'header', 'footer', 'form', 'aside'}
_BLOCK = {'address', 'article', 'blockquote', 'br', 'dd', 'div', 'dl', 'dt', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'li', 'main', 'ol', 'p', 'pre', 'section', 'table', 'tr', 'ul'}


class PublicWebError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _fail(code: str, message: str) -> None:
    raise PublicWebError(code, message)


def _public_ip(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        _fail('unsafe_url', '目标地址不是有效的公网地址。')
    if not address.is_global or address.is_multicast:
        _fail('unsafe_url', '只允许访问公网地址。')
    if address.version == 6:
        # Reject mapped/NAT64/transition addresses, including embedded private IPv4.
        if address not in ipaddress.ip_network('2000::/3') or address.sixtofour or address.teredo:
            _fail('unsafe_url', '不允许访问 IPv6 转换或特殊地址。')
    return str(address)


def _normal_url(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 2048:
        _fail('unsafe_url', '网页地址为空或过长。')
    if re.search(r'[\x00-\x20\x7f\\]', value):
        _fail('unsafe_url', '网页地址含有不支持的字符。')
    try:
        parts = urlsplit(value)
        host = parts.hostname
        if parts.scheme.lower() != 'https' or not host or parts.username is not None or parts.password is not None:
            _fail('unsafe_url', '只允许没有用户凭据的 HTTPS 网页。')
        if parts.port not in (None, 443) or '%' in host:
            _fail('unsafe_url', '不允许非标准端口或带区域标识的地址。')
        host = host.rstrip('.').encode('idna').decode('ascii').lower()
    except (ValueError, UnicodeError):
        _fail('unsafe_url', '网页地址格式无效。')
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        host = _public_ip(host)
    else:
        labels = host.split('.')
        if (len(labels) < 2 or len(host) > 253 or
                any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels) or
                host == 'localhost' or
                host.endswith(('.localhost', '.local', '.internal', '.lan', '.home', '.test', '.invalid', '.example', '.onion')) or
                re.fullmatch(r'(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+))*', host)):
            _fail('unsafe_url', '不允许本地、特殊或有歧义的主机名。')
    authority = f'[{host}]' if ':' in host else host
    return urlunsplit(('https', authority, parts.path or '/', parts.query, ''))


def _resolve(host: str, timeout: float) -> list[str]:
    try:
        return [_public_ip(host)]
    except PublicWebError:
        # A literal address that failed the check cannot be reinterpreted by DNS.
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise
    if not _DNS_SLOTS.acquire(blocking=False):
        _fail('web_unavailable', '公网域名解析暂时繁忙。')
    future = _DNS_POOL.submit(socket.getaddrinfo, host, 443, 0, socket.SOCK_STREAM)
    future.add_done_callback(lambda _: _DNS_SLOTS.release())
    try:
        answers = future.result(timeout=max(.01, min(3.0, timeout)))
        addresses = list(dict.fromkeys(_public_ip(item[4][0]) for item in answers))
    except FutureTimeout:
        _fail('web_timeout', '公网域名解析超时。')
    except OSError:
        _fail('web_unavailable', '无法解析目标公网域名。')
    if not addresses:
        _fail('web_unavailable', '目标域名没有可用的公网地址。')
    return addresses


def _configured_proxy() -> str | None:
    configured = os.environ.get('SERA_PUBLIC_WEB_PROXY', '').strip()
    if not configured:
        return None
    if configured.rstrip('/') != 'http://127.0.0.1:10808':
        _fail('invalid_web_configuration', '公网代理配置不在服务端允许范围内。')
    return 'http://127.0.0.1:10808'


class _HostnameTLSContext(ssl.SSLContext):
    """Keep hostname verification when an HTTP CONNECT tunnel targets a pinned IP.

    httpcore 1.x's proxy tunnel ignores its request sni_hostname extension. The
    transport still connects/CONNECTs to the checked IP, but this context always
    uses the original domain for BOTH SNI and required certificate verification.
    """
    def __new__(cls, hostname: str):
        return super().__new__(cls, ssl.PROTOCOL_TLS_CLIENT)

    def __init__(self, hostname: str):
        self._expected_hostname = hostname
        # The same bundled CA store used by httpx, without SSL_CERT_FILE/DIR.
        self.load_verify_locations(cafile=certifi.where())
        self.minimum_version = ssl.TLSVersion.TLSv1_2
        self.verify_mode = ssl.CERT_REQUIRED
        self.check_hostname = True

    def wrap_socket(self, *args, server_hostname=None, **kwargs):
        return super().wrap_socket(*args, server_hostname=self._expected_hostname, **kwargs)

    def wrap_bio(self, *args, server_hostname=None, **kwargs):
        return super().wrap_bio(*args, server_hostname=self._expected_hostname, **kwargs)


def _resolve_doh(host: str, timeout: float, proxy: str) -> tuple[list[str], int]:
    """Resolve through verified DNS-over-HTTPS when the local DNS is polluted.

    Fixed provider/bootstrap, never a model-selected URL; connect to Google's
    public resolver IP and verify the dns.google certificate. CONNECT still uses
    the IP, so neither the proxy nor local DNS gets to re-resolve the destination.
    """
    try:
        return [_public_ip(host)], 60
    except PublicWebError:
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise
    target = 'https://8.8.8.8/resolve?' + urlencode({'name': host, 'type': 'A'})
    transport = httpx.HTTPTransport(verify=_HostnameTLSContext('dns.google'), proxy=proxy, retries=0, trust_env=False)
    try:
        with httpx.Client(transport=transport, timeout=min(REQUEST_TIMEOUT_SECONDS, timeout), trust_env=False,
                          follow_redirects=False) as client:
            with client.stream('GET', target, headers={'Host': 'dns.google', 'Accept': 'application/dns-json',
                               'Accept-Encoding': 'identity'}) as response:
                if (response.status_code != 200 or
                        response.headers.get('content-type', '').split(';', 1)[0] not in {'application/json', 'application/dns-json'} or
                        response.headers.get('content-encoding', 'identity').lower() not in {'', 'identity'}):
                    _fail('web_unavailable', '可信公网域名解析当前不可用。')
                body = bytearray()
                for chunk in response.iter_raw(chunk_size=4096):
                    body.extend(chunk[:16385 - len(body)])
                    if len(body) > 16384:
                        _fail('web_unavailable', '公网域名解析响应超出限制。')
                data = json.loads(body)
    except PublicWebError:
        raise
    except httpx.TimeoutException:
        _fail('web_timeout', '可信公网域名解析超时。')
    except (httpx.HTTPError, OSError, ValueError):
        _fail('web_unavailable', '无法安全解析目标公网域名。')
    if not isinstance(data, dict) or data.get('Status') != 0 or data.get('TC'):
        _fail('web_unavailable', '可信公网域名解析未返回有效地址。')
    questions = data.get('Question')
    if not isinstance(questions, list) or len(questions) != 1 or questions[0] != {'name': host + '.', 'type': 1}:
        _fail('web_unavailable', '公网域名解析响应与请求不匹配。')
    answers = data.get('Answer')
    if not isinstance(answers, list) or len(answers) > 32:
        _fail('web_unavailable', '目标域名没有可用的公网地址。')
    addresses, ttl = [], 60
    for answer in answers:
        if not isinstance(answer, dict):
            _fail('web_unavailable', '公网域名解析响应格式无效。')
        if answer.get('type') == 1:
            try:
                address = _public_ip(answer.get('data', ''))
            except (ValueError, TypeError):
                _fail('unsafe_url', '目标 DNS 响应含有无效地址。')
            if ':' in address:
                _fail('unsafe_url', '目标 DNS 响应地址类型无效。')
            addresses.append(address)
            if isinstance(answer.get('TTL'), int):
                ttl = min(ttl, max(1, answer['TTL']))
    if not addresses:
        _fail('web_unavailable', '目标域名没有可用的公网 IPv4 地址。')
    return list(dict.fromkeys(addresses)), ttl


class _ReadableHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, bool]] = []
        self.parts: list[str] = []
        self.title_parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        hidden = bool(self.stack and self.stack[-1][1]) or tag in _HIDDEN or 'hidden' in attrs
        hidden = hidden or attrs.get('aria-hidden', '').lower() == 'true'
        hidden = hidden or bool(re.search(r'(?:display\s*:\s*none|visibility\s*:\s*hidden)', attrs.get('style', ''), re.I))
        if tag in _BLOCK and not hidden:
            self.parts.append('\n')
        if tag not in _VOID:
            self.stack.append((tag, hidden))

    def handle_endtag(self, tag):
        hidden = bool(self.stack and self.stack[-1][1])
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break
        if tag in _BLOCK and not hidden:
            self.parts.append('\n')
        elif tag in {'td', 'th'} and not hidden:
            self.parts.append(' | ')

    def handle_data(self, data):
        if any(tag == 'title' for tag, _ in self.stack):
            self.title_parts.append(data)
        elif not (self.stack and self.stack[-1][1]) and not any(tag == 'head' for tag, _ in self.stack):
            self.parts.append(data)

    @property
    def title(self):
        return ' '.join(''.join(self.title_parts).split())[:240]

    @property
    def text(self):
        lines = [' '.join(line.split()) for line in ''.join(self.parts).splitlines()]
        return '\n'.join(line for line in lines if line)[:MAX_PAGE_CHARS]


def _plain_html(value: str) -> str:
    parser = _ReadableHTML()
    parser.feed(value)
    parser.close()
    return parser.text


class _DuckResults(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.div_depth = 0
        self.result_depth = 0
        self.current = None
        self.capture = None
        self.capture_tag = None
        self.items = []
        self.no_results = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = attrs.get('class', '').split()
        if 'no-results' in classes or 'no-results__message' in classes:
            self.no_results = True
        if tag == 'div':
            self.div_depth += 1
            if 'result' in classes and self.current is None:
                self.result_depth = self.div_depth
                self.current = {'title': '', 'url': '', 'snippet': ''}
        if self.current is not None:
            if tag == 'a' and 'result__a' in classes:
                self.current['url'] = attrs.get('href', '')
                self.capture, self.capture_tag = 'title', tag
            elif 'result__snippet' in classes:
                self.capture, self.capture_tag = 'snippet', tag

    def handle_endtag(self, tag):
        if tag == self.capture_tag:
            self.capture = self.capture_tag = None
        if tag == 'div':
            if self.current is not None and self.div_depth == self.result_depth:
                self.items.append(self.current)
                self.current = None
                self.capture = self.capture_tag = None
            self.div_depth = max(0, self.div_depth - 1)

    def handle_data(self, data):
        if self.current is not None and self.capture:
            self.current[self.capture] += data


class _SoResults(HTMLParser):
    """360's organic results expose the real destination in data-mdurl.

    Never execute scripts, parse generated answers, or follow opaque tracking
    links. This parser contains no subject/date/domain-specific extraction.
    """
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.li_depth = 0
        self.result_depth = 0
        self.title_region = False
        self.capture = None
        self.capture_tag = None
        self.current = None
        self.items = []
        self.no_results = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = attrs.get('class', '').split()
        if any(value in classes for value in ('res-none', 'no-result', 'no-results')):
            self.no_results = True
        if tag == 'li':
            self.li_depth += 1
            if 'res-list' in classes and attrs.get('data-result-type', 'normal') == 'normal' and self.current is None:
                self.result_depth = self.li_depth
                self.current = {'title': '', 'url': '', 'snippet': ''}
        if self.current is not None:
            if tag == 'h3' and 'res-title' in classes:
                self.title_region = True
            if tag == 'a' and self.title_region:
                target = attrs.get('data-mdurl') or attrs.get('href', '')
                # The destination must actually appear in the result HTML.
                parsed = urlsplit(target)
                if parsed.hostname not in {'www.so.com', 'so.com'}:
                    self.current['url'] = target
                self.capture, self.capture_tag = 'title', 'a'
            elif 'res-desc' in classes:
                self.capture, self.capture_tag = 'snippet', tag

    def handle_endtag(self, tag):
        if tag == self.capture_tag:
            self.capture = self.capture_tag = None
        if tag == 'h3':
            self.title_region = False
        if tag == 'li':
            if self.current is not None and self.li_depth == self.result_depth:
                self.items.append(self.current)
                self.current = None
                self.title_region = False
                self.capture = self.capture_tag = None
            self.li_depth = max(0, self.li_depth - 1)

    def handle_data(self, data):
        if self.current is not None and self.capture:
            self.current[self.capture] += data


def _result_url(value: str) -> str:
    if not value:
        _fail('unsafe_url', '搜索结果没有公开的目标链接。')
    value = urljoin('https://html.duckduckgo.com/html/', value)
    parts = urlsplit(value)
    if parts.hostname in {'duckduckgo.com', 'www.duckduckgo.com', 'html.duckduckgo.com'} and parts.path.startswith('/l/'):
        value = parse_qs(parts.query).get('uddg', [''])[0]
    return _normal_url(value)


class PublicWebSession:
    """One user operation's short-lived URL capability set and bounded cache.

    The caller, never a model tool argument, constructs this session. Do not reuse
    it across users/jobs. The private injection points are for offline tests.
    """
    def __init__(self, *, timeout: float = 8, deadline: float | None = None,
                 _transport=None, _resolver: Callable | None = None,
                 _clock: Callable[[], float] = time.monotonic):
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not 0 < timeout <= 10:
            _fail('invalid_web_configuration', '公网请求超时配置必须在 0–10 秒范围内。')
        if deadline is not None and (isinstance(deadline, bool) or not isinstance(deadline, (int, float)) or not math.isfinite(deadline)):
            _fail('invalid_web_configuration', '公网工具截止时间配置无效。')
        self._transport = _transport
        self._resolver = _resolver
        self._clock = _clock
        self._timeout = float(timeout)
        self._deadline = deadline if deadline is not None else self._clock() + 45.0
        self._proxy = _configured_proxy()
        self._dns_cache: dict[str, tuple[float, list[str]]] = {}
        self._urls: dict[str, float] = {}
        self._cache: dict[tuple[str, str], tuple[float, object]] = {}
        self._search_count = self._read_count = 0
        self._closed = False
        self._token = None
        self.events: list[dict] = []
        self.last_search_provider: str | None = None

    def __enter__(self):
        self._ensure_open()
        if self._token is not None:
            _fail('web_session_required', '公网工具会话不能重复进入。')
        self._token = _CURRENT.set(self)
        return self

    def __exit__(self, *_):
        if self._token is not None:
            _CURRENT.reset(self._token)
            self._token = None
        self.close()

    def close(self):
        self._closed = True
        self._urls.clear()
        self._cache.clear()
        self._dns_cache.clear()

    @property
    def allowed_urls(self) -> frozenset[str]:
        self._expire()
        return frozenset(self._urls)

    def _ensure_open(self):
        if self._closed:
            _fail('web_session_required', '公网工具会话已结束。')
        if self._clock() >= self._deadline:
            _fail('web_timeout', '本次理解的公网工具时间已用尽。')

    def _expire(self):
        now = self._clock()
        self._urls = {url: expiry for url, expiry in self._urls.items() if expiry > now}
        self._cache = {key: entry for key, entry in self._cache.items() if entry[0] > now}

    def _fetch(self, url: str, *, search: bool, redirect_hosts: set[str] | None = None,
               deadline: float | None = None) -> tuple[str, str, bytes]:
        deadline = min(self._deadline, deadline if deadline is not None else self._clock() + OPERATION_TIMEOUT_SECONDS)
        current = _normal_url(url)
        initial_host = urlsplit(current).hostname
        for hop in range(MAX_REDIRECTS + 1):
            remaining = deadline - self._clock()
            if remaining <= 0:
                _fail('web_timeout', '公网请求超时。')
            host = urlsplit(current).hostname
            if search and urlsplit(current).path not in _SEARCH_HOST_PATHS.get(host, set()):
                _fail('unsafe_url', '搜索只允许服务端固定搜索引擎的固定路径。')
            fixed_search_proxy = bool(search and self._proxy)
            if fixed_search_proxy:
                # The server fixes both host and path; the query cannot change
                # the CONNECT destination. Keep the trusted proxy's domain route.
                target = httpx.URL(current)
            else:
                if self._resolver is not None:
                    addresses = self._resolver(host, remaining)
                elif self._proxy:
                    cached_dns = self._dns_cache.get(host)
                    if cached_dns is not None and cached_dns[0] > self._clock():
                        addresses = cached_dns[1]
                    else:
                        addresses, ttl = _resolve_doh(host, min(self._timeout, remaining), self._proxy)
                        self._dns_cache[host] = (self._clock() + ttl, addresses)
                else:
                    addresses = _resolve(host, remaining)
                # Recheck every answer and pin the actual connection. Arbitrary
                # page destinations never use the proxy's unchecked remote DNS.
                if not addresses:
                    _fail('web_unavailable', '目标没有可用的公网地址。')
                addresses = [_public_ip(address) for address in addresses]
                target = httpx.URL(current).copy_with(host=addresses[0])
            remaining = deadline - self._clock()
            if remaining <= 0:
                _fail('web_timeout', '公网请求超时。')
            headers = {'User-Agent': _USER_AGENT, 'Host': host, 'Accept-Encoding': 'identity',
                       'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,application/rss+xml;q=0.8,application/xml;q=0.7'}
            transport = self._transport
            if transport is None:
                transport = httpx.HTTPTransport(verify=_HostnameTLSContext(host), proxy=self._proxy, retries=0, trust_env=False)
            try:
                timeout = httpx.Timeout(min(self._timeout, remaining), connect=min(4.0, self._timeout, remaining))
                with httpx.Client(transport=transport, timeout=timeout, follow_redirects=False, trust_env=False) as client:
                    with client.stream('GET', target, headers=headers, extensions={'sni_hostname': host}) as response:
                        self.events.append({'url': current, 'status': response.status_code,
                                            'retrievedAt': datetime.now(timezone.utc).isoformat(),
                                            'connectionPolicy': 'fixed-search-host-through-trusted-proxy' if fixed_search_proxy else 'checked-public-ip'})
                        if response.status_code in {301, 302, 303, 307, 308}:
                            if hop == MAX_REDIRECTS:
                                _fail('unsafe_redirect', '网页跳转次数过多。')
                            location = response.headers.get('location')
                            if not location:
                                _fail('unsafe_redirect', '网页跳转缺少目标地址。')
                            redirected = _normal_url(urljoin(current, location))
                            next_host = urlsplit(redirected).hostname
                            aliases = {initial_host, initial_host.removeprefix('www.'), 'www.' + initial_host.removeprefix('www.')}
                            allowed = next_host in (redirect_hosts if search else aliases)
                            if not allowed and not (not search and redirected in self._urls):
                                _fail('unsafe_redirect', '网页跳转到了本次搜索未授权的站点。')
                            current = redirected
                            continue
                        if response.status_code != 200:
                            _fail('web_unavailable', '公网来源暂时无法访问。')
                        content_type = response.headers.get('content-type', '').split(';', 1)[0].strip().lower()
                        permitted = {'text/html', 'application/xhtml+xml', 'text/plain'}
                        if search:
                            permitted |= {'text/xml', 'application/xml', 'application/rss+xml'}
                        if content_type not in permitted or 'attachment' in response.headers.get('content-disposition', '').lower():
                            _fail('unsupported_content', '只读取网页文本，不下载附件或二进制文件。')
                        if response.headers.get('content-encoding', 'identity').lower() not in {'', 'identity'}:
                            _fail('unsupported_content', '来源没有提供可安全截断的未压缩文本。')
                        body = bytearray()
                        # Do not buffer until 8 KiB: a slow source could drip
                        # bytes while postponing the deadline check indefinitely.
                        for chunk in response.iter_raw():
                            if self._clock() >= deadline:
                                _fail('web_timeout', '公网请求超时。')
                            remaining_bytes = MAX_BODY_BYTES - len(body)
                            body.extend(chunk[:remaining_bytes])
                            if len(body) >= MAX_BODY_BYTES:
                                break
                        raw = bytes(body)
                        if b'\x00' in raw[:4096] or raw.startswith((b'%PDF', b'PK\x03\x04', b'\x89PNG', b'GIF8')):
                            _fail('unsupported_content', '来源内容不是可读网页文本。')
                        self.events[-1].update({'bodyBytes': len(raw), 'bodySha256': sha256(raw).hexdigest(),
                                                'truncated': len(raw) == MAX_BODY_BYTES})
                        return current, response.headers.get('content-type', ''), raw
            except PublicWebError:
                raise
            except httpx.TimeoutException:
                _fail('web_timeout', '公网请求超时。')
            except (httpx.HTTPError, OSError):
                _fail('web_unavailable', '无法安全连接到公网来源。')
        _fail('unsafe_redirect', '网页跳转次数过多。')

    @staticmethod
    def _decode(raw: bytes, content_type: str) -> str:
        charset = re.search(r'charset\s*=\s*["\']?([a-zA-Z0-9._-]+)', content_type, re.I)
        if charset is None:
            charset = re.search(br'<meta[^>]+charset\s*=\s*["\']?([a-zA-Z0-9._-]+)', raw[:4096], re.I)
        encoding = charset.group(1) if charset else 'utf-8'
        if isinstance(encoding, bytes):
            encoding = encoding.decode('ascii')
        if encoding.lower() in {'gb2312', 'gbk', 'x-gbk'}:
            encoding = 'gb18030'
        try:
            return raw.decode(encoding, errors='replace')
        except LookupError:
            return raw.decode('utf-8', errors='replace')

    def _search_public_web(self, query: str) -> list[dict[str, str]]:
        self._ensure_open()
        if not isinstance(query, str) or not 2 <= len(query.strip()) <= 400 or re.search(r'[\x00-\x1f\x7f]', query):
            _fail('invalid_search_query', '搜索词需要 2–400 个可读字符。')
        query = query.strip()
        self._expire()
        key = ('search', query)
        if key in self._cache:
            return deepcopy(self._cache[key][1])
        if self._search_count >= 4:
            _fail('web_limit_reached', '本次理解已达到搜索次数上限。')
        self._search_count += 1
        deadline = min(self._deadline, self._clock() + OPERATION_TIMEOUT_SECONDS)
        last_error = None
        for provider in ('360', 'duckduckgo', 'bing_rss'):
            try:
                if provider == '360':
                    search_url = 'https://www.so.com/s?' + urlencode({'q': query})
                    _, content_type, raw = self._fetch(search_url, search=True, redirect_hosts={'www.so.com', 'so.com'}, deadline=deadline)
                    text = self._decode(raw, content_type)
                    parser = _SoResults()
                    parser.feed(text)
                    parser.close()
                    if not parser.items and not parser.no_results:
                        _fail('search_unavailable', '搜索服务未返回可读取的公开搜索结果。')
                    candidates = parser.items
                elif provider == 'duckduckgo':
                    search_url = 'https://html.duckduckgo.com/html/?' + urlencode({'q': query})
                    _, content_type, raw = self._fetch(search_url, search=True, redirect_hosts={'html.duckduckgo.com', 'duckduckgo.com', 'www.duckduckgo.com'}, deadline=deadline)
                    text = self._decode(raw, content_type)
                    if any(marker in text.lower() for marker in ('anomaly.js', 'bots use duckduckgo', 'captcha')):
                        _fail('search_unavailable', '搜索服务要求交互验证，未绕过验证。')
                    parser = _DuckResults()
                    parser.feed(text)
                    parser.close()
                    if not parser.items and not parser.no_results:
                        _fail('search_unavailable', '搜索服务未返回可读取的搜索结果。')
                    candidates = parser.items
                else:
                    search_url = 'https://www.bing.com/search?' + urlencode({'q': query, 'format': 'rss'})
                    _, _, raw = self._fetch(search_url, search=True, redirect_hosts={'www.bing.com', 'cn.bing.com'}, deadline=deadline)
                    if re.search(br'<!\s*(?:DOCTYPE|ENTITY)', raw, re.I):
                        _fail('unsupported_content', '不接受带文档实体的搜索响应。')
                    tree = ET.fromstring(raw)
                    candidates = [{'title': item.findtext('title') or '', 'url': item.findtext('link') or '',
                                   'snippet': _plain_html(item.findtext('description') or '')}
                                  for item in tree.findall('./channel/item')[:20]]
                    if tree.tag != 'rss':
                        _fail('search_unavailable', '搜索服务未返回 RSS 结果。')
                results, seen = [], set()
                for candidate in candidates:
                    try:
                        url = _result_url(candidate['url'])
                    except (PublicWebError, ValueError):
                        continue
                    title = ' '.join(candidate['title'].split())[:240]
                    if not title or url in seen:
                        continue
                    seen.add(url)
                    results.append({'title': title, 'url': url, 'snippet': ' '.join(candidate['snippet'].split())[:1000]})
                    if len(results) >= MAX_RESULTS:
                        break
                now = self._clock()
                for result in results:
                    self._urls[result['url']] = now + URL_TTL_SECONDS
                self._cache[key] = (now + SEARCH_TTL_SECONDS, deepcopy(results))
                self.last_search_provider = provider
                return results
            except (PublicWebError, ET.ParseError) as error:
                last_error = error
        if isinstance(last_error, PublicWebError):
            raise last_error
        _fail('search_unavailable', '公共搜索当前不可用，未获取到可靠搜索结果。')

    def _read_public_page(self, url: str) -> dict[str, str]:
        self._ensure_open()
        url = _normal_url(url)
        self._expire()
        if url not in self._urls:
            _fail('url_not_in_search', '只能读取本次搜索实际返回且尚未过期的网页链接。')
        key = ('page', url)
        if key in self._cache:
            return deepcopy(self._cache[key][1])
        if self._read_count >= 6:
            _fail('web_limit_reached', '本次理解已达到网页读取次数上限。')
        self._read_count += 1
        final_url, content_type, raw = self._fetch(url, search=False)
        decoded = self._decode(raw, content_type)
        if content_type.lower().startswith('text/plain'):
            title, text = '', decoded.strip()[:MAX_PAGE_CHARS]
        else:
            parser = _ReadableHTML()
            parser.feed(decoded)
            parser.close()
            title, text = parser.title, parser.text
        if not text:
            _fail('unsupported_content', '网页没有可读取的正文，可能需要浏览器执行脚本。')
        result = {'title': title, 'url': final_url, 'text': text,
                  'retrievedAt': datetime.now(timezone.utc).isoformat()}
        expiry = min(self._clock() + PAGE_TTL_SECONDS, self._urls[url])
        self._urls[final_url] = self._urls[url]
        self._cache[key] = (expiry, deepcopy(result))
        return result

    def search_public_web(self, query: str) -> dict:
        """Stable model-tool observation; failures never masquerade as results."""
        try:
            return {'ok': True, 'results': self._search_public_web(query)}
        except PublicWebError as error:
            return {'ok': False, 'error': {'code': error.code, 'message': str(error)}}

    def read_public_page(self, url: str) -> dict:
        try:
            return {'ok': True, **self._read_public_page(url)}
        except PublicWebError as error:
            return {'ok': False, 'error': {'code': error.code, 'message': str(error)}}


def _session(session: PublicWebSession | None) -> PublicWebSession:
    selected = session if session is not None else _CURRENT.get()
    if not isinstance(selected, PublicWebSession):
        _fail('web_session_required', '搜索和读取必须绑定同一个理解请求的公网工具会话。')
    return selected


def search_public_web(query: str, *, session: PublicWebSession | None = None) -> dict:
    try:
        return _session(session).search_public_web(query)
    except PublicWebError as error:
        return {'ok': False, 'error': {'code': error.code, 'message': str(error)}}


def read_public_page(url: str, *, session: PublicWebSession | None = None) -> dict:
    try:
        return _session(session).read_public_page(url)
    except PublicWebError as error:
        return {'ok': False, 'error': {'code': error.code, 'message': str(error)}}
