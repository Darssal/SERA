"""Offline public-web parsing, URL capabilities and outbound-network boundary checks."""
import os
import json
import ssl
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, quote, urlsplit

import httpx

import public_web as web


PUBLIC_IP = '93.184.216.34'
PAGE = 'https://news.example.org/article'
HTML = '<html><head><title>权威公告</title><script>secret script</script></head><body><nav>导航</nav><article><h1>考试时间</h1><p>2026 年 12 月 12 日。</p><table><tr><td>四级</td><td>9:00–11:20</td></tr></table><div hidden>hidden-secret</div><p style="display:none">hidden-css</p><p aria-hidden="true">hidden-aria</p></article><footer>页脚</footer></body></html>'


def results_html(url=PAGE, title='权威公告', snippet='真实来源的搜索摘要'):
    wrapped = '//duckduckgo.com/l/?uddg=' + quote(url, safe='') + '&amp;rut=hash'
    return f'<html><div class="result results_links web-result"><h2><a class="result__a" href="{wrapped}">{title}</a></h2><div><a class="result__snippet"><b>{snippet}</b></a></div></div></html>'


def response(request, *, status=200, body=HTML, content_type='text/html; charset=utf-8', headers=None):
    merged = {'content-type': content_type, **(headers or {})}
    return httpx.Response(status, stream=httpx.ByteStream(body.encode('utf-8') if isinstance(body, str) else body),
                          headers=merged, request=request)


class Clock:
    def __init__(self):
        self.value = 100.0

    def __call__(self):
        return self.value


class PublicWebTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {'SERA_PUBLIC_WEB_PROXY': ''})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.requests = []
        self.clock = Clock()

    def session(self, handler=None, resolver=None):
        def default_handler(request):
            if request.headers['host'] == 'www.so.com':
                return response(request, status=503)
            if request.headers['host'] == 'html.duckduckgo.com':
                return response(request, body=results_html())
            return response(request)
        selected_handler = handler or default_handler

        def handle(request):
            self.requests.append(request)
            return selected_handler(request)
        session = web.PublicWebSession(_transport=httpx.MockTransport(handle),
                                       _resolver=resolver or (lambda host, timeout: [PUBLIC_IP]),
                                       _clock=self.clock, deadline=self.clock() + 10000)
        self.addCleanup(session.close)
        return session

    def assert_code(self, code, callback):
        with self.assertRaises(web.PublicWebError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_general_query_reaches_provider_and_results_authorize_exact_page(self):
        session = self.session()
        found = session._search_public_web('如何学习 Python asyncio？')
        self.assertEqual(found, [{'title': '权威公告', 'url': PAGE, 'snippet': '真实来源的搜索摘要'}])
        self.assertEqual(parse_qs(self.requests[0].url.query.decode())['q'], ['如何学习 Python asyncio？'])
        self.assertEqual(session.last_search_provider, 'duckduckgo')
        self.assertEqual(session.allowed_urls, frozenset({PAGE}))
        self.assertEqual(set(found[0]), {'title', 'url', 'snippet'})

    def test_real_connection_uses_checked_ip_but_original_host_and_tls_sni(self):
        session = self.session()
        session._search_public_web('普通搜索')
        request = self.requests[0]
        self.assertEqual(request.url.host, PUBLIC_IP)
        self.assertEqual(request.headers['host'], 'www.so.com')
        self.assertEqual(request.extensions['sni_hostname'], 'www.so.com')
        self.assertEqual(request.headers['accept-encoding'], 'identity')
        self.assertNotIn('cookie', request.headers)
        self.assertNotIn('authorization', request.headers)

    def test_read_requires_same_operation_search_and_cannot_use_host_as_wildcard(self):
        first, second = self.session(), self.session()
        first._search_public_web('搜索公告')
        self.assert_code('url_not_in_search', lambda: second._read_public_page(PAGE))
        self.assert_code('url_not_in_search', lambda: first._read_public_page(PAGE + '/other'))
        self.assert_code('url_not_in_search', lambda: first._read_public_page('https://news.example.org/'))
        self.assertEqual(len(self.requests), 2)

    def test_no_ambient_global_session_leaks_between_callers(self):
        self.assertEqual(web.search_public_web('搜索公告')['error']['code'], 'web_session_required')
        with self.session() as session:
            self.assertEqual(web.search_public_web('搜索公告')['results'], session._search_public_web('搜索公告'))
            self.assertEqual(web.read_public_page(PAGE)['title'], '权威公告')
        self.assertEqual(web.read_public_page(PAGE)['error']['code'], 'web_session_required')
        self.assert_code('web_session_required', lambda: session._search_public_web('再次搜索'))

    def test_readable_html_strips_active_hidden_and_navigation_content(self):
        session = self.session()
        session._search_public_web('搜索公告')
        page = session._read_public_page(PAGE)
        self.assertEqual(set(page), {'title', 'url', 'text', 'retrievedAt'})
        self.assertEqual(page['title'], '权威公告')
        self.assertEqual(page['url'], PAGE)
        self.assertIn('2026 年 12 月 12 日', page['text'])
        self.assertIn('四级 | 9:00–11:20', page['text'])
        for forbidden in ('secret script', 'hidden-secret', 'hidden-css', 'hidden-aria', '导航', '页脚'):
            self.assertNotIn(forbidden, page['text'])
        self.assertTrue(page['retrievedAt'].endswith('+00:00'))
        self.assertEqual(session.events[-1]['bodyBytes'], len(HTML.encode()))
        self.assertEqual(len(session.events[-1]['bodySha256']), 64)

    def test_literal_private_metadata_loopback_and_ambiguous_urls_fail_before_network(self):
        session = self.session()
        unsafe = ['http://example.org/', 'https://localhost/', 'https://localhost./',
                  'https://api.localhost/', 'https://secret.internal/', 'https://169.254.169.254/latest/meta-data/',
                  'https://127.0.0.1/', 'https://10.0.0.1/', 'https://172.16.0.1/', 'https://192.168.0.1/',
                  'https://100.64.0.1/', 'https://0.0.0.0/', 'https://224.0.0.1/',
                  'https://[::1]/', 'https://[::ffff:127.0.0.1]/', 'https://[64:ff9b::7f00:1]/',
                  'https://[2002:7f00:1::]/', 'https://[fe80::1%25eth0]/',
                  'https://2130706433/', 'https://0177.0.0.1/', 'https://0x7f000001/',
                  'https://user:pass@example.org/', 'https://example.org:8787/',
                  'https://example.org\\@127.0.0.1/', 'https://example.org/\r\nHeader:value']
        for url in unsafe:
            with self.subTest(url=url):
                self.assert_code('unsafe_url', lambda: session._read_public_page(url))
        self.assertEqual(self.requests, [])

    def test_dns_mixed_public_private_answers_are_all_rejected_without_connection(self):
        for addresses in (['127.0.0.1'], [PUBLIC_IP, '10.0.0.1'], ['169.254.169.254'], ['224.1.2.3']):
            with self.subTest(addresses=addresses):
                session = self.session(resolver=lambda host, timeout: addresses)
                self.assert_code('unsafe_url', lambda: session._fetch(PAGE, search=False))
        self.assertEqual(self.requests, [])

    def test_system_dns_does_not_accept_a_private_answer_among_public_addresses(self):
        records = [(2, 1, 6, '', (PUBLIC_IP, 443)), (2, 1, 6, '', ('192.168.1.1', 443))]
        with patch('public_web.socket.getaddrinfo', return_value=records):
            self.assert_code('unsafe_url', lambda: web._resolve('public-looking.example.org', 1))

    def test_dns_change_between_search_and_read_is_checked_again(self):
        public = True
        def resolve(host, timeout):
            return [PUBLIC_IP] if public else ['10.0.0.8']
        session = self.session(resolver=resolve)
        session._search_public_web('搜索公告')
        public = False
        self.assert_code('unsafe_url', lambda: session._read_public_page(PAGE))
        self.assertEqual(len(self.requests), 2)

    def test_same_host_redirect_rechecks_dns_and_rejects_private_second_hop(self):
        count = 0
        def resolver(host, timeout):
            nonlocal count
            count += 1
            return [PUBLIC_IP] if count == 1 else ['127.0.0.1']
        session = self.session(handler=lambda request: response(request, status=302, headers={'location': '/secret'}), resolver=resolver)
        self.assert_code('unsafe_url', lambda: session._fetch(PAGE, search=False))
        self.assertEqual(len(self.requests), 1)

    def test_private_cross_site_and_https_downgrade_redirects_never_followed(self):
        for target in ('https://169.254.169.254/', 'https://evil.example.org/', 'http://news.example.org/'):
            with self.subTest(target=target):
                session = self.session(handler=lambda request: response(request, status=302, headers={'location': target}))
                with self.assertRaises(web.PublicWebError):
                    session._fetch(PAGE, search=False)
        self.assertEqual(len(self.requests), 3)

    def test_safe_www_redirect_is_read_and_final_url_retains_capability(self):
        def handle(request):
            if request.headers['host'] == 'www.so.com':
                return response(request, status=503)
            if request.headers['host'] == 'html.duckduckgo.com':
                return response(request, body=results_html())
            if request.headers['host'] == 'news.example.org':
                return response(request, status=301, headers={'location': 'https://www.news.example.org/final'})
            return response(request)
        session = self.session(handler=handle)
        session._search_public_web('搜索公告')
        page = session._read_public_page(PAGE)
        self.assertEqual(page['url'], 'https://www.news.example.org/final')
        self.assertIn(page['url'], session.allowed_urls)

    def test_unbounded_redirect_loop_stops_after_four_requests(self):
        session = self.session(handler=lambda request: response(request, status=302, headers={'location': '/loop'}))
        self.assert_code('unsafe_redirect', lambda: session._fetch(PAGE, search=False))
        self.assertEqual(len(self.requests), web.MAX_REDIRECTS + 1)

    def test_binary_attachment_and_compressed_responses_are_not_downloaded(self):
        variants = [('application/pdf', {}, b'%PDF-1.4'), ('image/png', {}, b'\x89PNG'),
                    ('text/html', {'content-disposition': 'attachment; filename=download.html'}, b'download'),
                    ('text/html', {'content-encoding': 'gzip'}, b'compressed'),
                    ('text/html', {}, b'%PDF-1.4 disguised'), ('text/plain', {}, b'\0binary')]
        for mime, headers, body in variants:
            with self.subTest(mime=mime, headers=headers):
                session = self.session(handler=lambda request: response(request, body=body, content_type=mime, headers=headers))
                self.assert_code('unsupported_content', lambda: session._fetch(PAGE, search=False))

    def test_large_response_is_stream_bounded_and_plain_text_is_character_bounded(self):
        data = b'a' * (web.MAX_BODY_BYTES + 10000)
        session = self.session(handler=lambda request: response(request, body=data, content_type='text/plain'))
        final_url, mime, body = session._fetch(PAGE, search=False)
        self.assertEqual(len(body), web.MAX_BODY_BYTES)
        self.assertTrue(session.events[-1]['truncated'])
        session._urls[PAGE] = self.clock() + 30
        page = session._read_public_page(PAGE)
        self.assertEqual(len(page['text']), web.MAX_PAGE_CHARS)

    def test_gb2312_header_and_meta_are_decoded_with_gb18030(self):
        body = '<meta charset="gb2312"><p>考试公告</p>'.encode('gb18030')
        self.assertIn('考试公告', web.PublicWebSession._decode(body, 'text/html'))
        self.assertIn('考试公告', web.PublicWebSession._decode(body, 'text/html; charset=gb2312'))

    def test_network_errors_become_safe_explicit_unavailability_not_fake_content(self):
        def handler(request):
            raise httpx.ConnectTimeout('sensitive internal diagnostic')
        session = self.session(handler=handler)
        self.assert_code('web_timeout', lambda: session._search_public_web('搜索公告'))
        self.assertEqual(session.allowed_urls, frozenset())
        self.assertEqual(len(self.requests), 3)

    def test_duck_challenge_falls_back_to_real_bing_rss_with_checked_redirect(self):
        rss = f'<rss><channel><item><title>一般科学资料</title><link>{PAGE}</link><description>&lt;p&gt;公开摘要&lt;/p&gt;</description></item></channel></rss>'
        def handler(request):
            host = request.headers['host']
            if host in {'www.so.com', 'html.duckduckgo.com'}:
                return response(request, body='<html>captcha</html>')
            if host == 'www.bing.com':
                return response(request, status=302, headers={'location': 'https://cn.bing.com/search?format=rss&amp;q=science'})
            return response(request, body=rss, content_type='text/xml')
        session = self.session(handler=handler)
        found = session._search_public_web('一般科学资料')
        self.assertEqual(found, [{'title': '一般科学资料', 'url': PAGE, 'snippet': '公开摘要'}])
        self.assertEqual(session.last_search_provider, 'bing_rss')
        self.assertEqual([request.headers['host'] for request in self.requests], ['www.so.com', 'html.duckduckgo.com', 'www.bing.com', 'cn.bing.com'])

    def test_xml_entity_expansion_and_html_shell_are_unavailable(self):
        def handler(request):
            if request.headers['host'] in {'www.so.com', 'html.duckduckgo.com'}:
                return response(request, body='<html><script>location.replace()</script></html>')
            return response(request, body='<!DOCTYPE rss [<!ENTITY lol "expanded">]><rss><channel/></rss>', content_type='text/xml')
        session = self.session(handler=handler)
        self.assert_code('unsupported_content', lambda: session._search_public_web('搜索公告'))
        self.assertEqual(session.allowed_urls, frozenset())

    def test_empty_results_are_empty_not_a_fabricated_answer(self):
        session = self.session(handler=lambda request: response(request, body='<html><div class="no-results">No results</div></html>'))
        self.assertEqual(session._search_public_web('不存在的公开搜索词'), [])
        self.assertEqual(len(self.requests), 1)

    def test_private_and_duplicate_result_links_are_filtered(self):
        body = (results_html('https://127.0.0.1/secret') + results_html() + results_html())
        session = self.session(handler=lambda request: response(request, body=body))
        self.assertEqual(len(session._search_public_web('搜索公告')), 1)
        self.assertEqual(session.allowed_urls, frozenset({PAGE}))

    def test_success_cache_has_ttl_and_returns_copies_without_cross_session_leak(self):
        session = self.session()
        found = session._search_public_web('搜索公告')
        found[0]['url'] = 'https://evil.example.org/'
        self.assertEqual(session._search_public_web('搜索公告')[0]['url'], PAGE)
        first = session._read_public_page(PAGE)
        first['text'] = 'mutated'
        self.assertNotEqual(session._read_public_page(PAGE)['text'], 'mutated')
        self.assertEqual(len(self.requests), 3)
        self.clock.value += web.PAGE_TTL_SECONDS + 1
        session._read_public_page(PAGE)
        self.assertEqual(len(self.requests), 4)
        self.clock.value += web.URL_TTL_SECONDS
        self.assert_code('url_not_in_search', lambda: session._read_public_page(PAGE))
        session._search_public_web('搜索公告')
        self.assertEqual(len(self.requests), 6)

    def test_bounded_query_read_search_counts(self):
        session = self.session()
        for value in ('', 'x' * 401, 'hello\nworld', None):
            self.assert_code('invalid_search_query', lambda: session._search_public_web(value))
        for i in range(4):
            session._search_public_web(f'公开搜索{i}')
        self.assert_code('web_limit_reached', lambda: session._search_public_web('第五个搜索'))
        for i in range(6):
            url = PAGE + f'?item={i}'
            session._urls[url] = self.clock() + 60
            session._read_public_page(url)
        session._urls[PAGE + '?item=7'] = self.clock() + 60
        self.assert_code('web_limit_reached', lambda: session._read_public_page(PAGE + '?item=7'))

    def test_explicit_fixed_proxy_only_and_ambient_proxy_does_not_opt_in(self):
        with patch.dict(os.environ, {'HTTP_PROXY': 'http://evil.example.org:8080', 'HTTPS_PROXY': 'http://evil.example.org:8080'}):
            self.assertIsNone(self.session()._proxy)
        with patch.dict(os.environ, {'SERA_PUBLIC_WEB_PROXY': 'http://127.0.0.1:10808'}):
            self.assertEqual(self.session()._proxy, 'http://127.0.0.1:10808')
        for bad in ('http://127.0.0.1:8787', 'https://evil.example.org', 'http://user:pass@127.0.0.1:10808'):
            with patch.dict(os.environ, {'SERA_PUBLIC_WEB_PROXY': bad}):
                self.assert_code('invalid_web_configuration', lambda: self.session())

    def test_deadline_prevents_slow_chunk_accumulation_beyond_operation_timeout(self):
        class SlowBody(httpx.SyncByteStream):
            def __iter__(inner):
                yield b'<p>start</p>'
                self.clock.value += web.OPERATION_TIMEOUT_SECONDS + 1
                yield b'<p>end</p>'
        def handler(request):
            return httpx.Response(200, stream=SlowBody(), headers={'content-type': 'text/html'}, request=request)
        session = self.session(handler=handler)
        self.assert_code('web_timeout', lambda: session._fetch(PAGE, search=False))

    def test_public_envelopes_are_stable_on_success_and_safe_failure(self):
        session = self.session()
        found = session.search_public_web('搜索公告')
        self.assertTrue(found['ok'])
        self.assertEqual(found['results'][0]['url'], PAGE)
        page = session.read_public_page(PAGE)
        self.assertTrue(page['ok'])
        self.assertEqual(page['title'], '权威公告')
        denied = session.read_public_page('https://evil.example.org/')
        self.assertEqual(denied['error']['code'], 'url_not_in_search')
        self.assertFalse(denied['ok'])
        self.assertNotIn('text', denied)
        session.close()
        self.assertEqual(session.search_public_web('搜索公告')['error']['code'], 'web_session_required')

    def test_session_deadline_is_cumulative_and_not_reset_by_new_calls(self):
        session = self.session()
        session._deadline = self.clock() + 2
        self.assertTrue(session.search_public_web('搜索公告')['ok'])
        self.clock.value += 3
        denied = session.read_public_page(PAGE)
        self.assertEqual(denied['error']['code'], 'web_timeout')
        self.assertFalse(denied['ok'])
        self.assertEqual(len(self.requests), 2)

    def test_proxy_tls_uses_original_hostname_and_required_trusted_certificates(self):
        context = web._HostnameTLSContext('public.example.org')
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        self.assertGreaterEqual(context.minimum_version, ssl.TLSVersion.TLSv1_2)
        with patch.object(ssl.SSLContext, 'wrap_socket', return_value='verified') as wrap:
            self.assertEqual(context.wrap_socket(object(), server_hostname=PUBLIC_IP), 'verified')
        self.assertEqual(wrap.call_args.kwargs['server_hostname'], 'public.example.org')

    def test_proxy_doh_uses_fixed_public_ip_verified_hostname_and_rejects_private_answers(self):
        queries = []
        data = {'Status': 0, 'TC': False, 'Question': [{'name': 'public.example.org.', 'type': 1}],
                'Answer': [{'name': 'public.example.org.', 'type': 1, 'TTL': 120, 'data': PUBLIC_IP}]}
        def handler(request):
            queries.append(request)
            return response(request, body=json.dumps(data), content_type='application/json')
        transport = httpx.MockTransport(handler)
        with patch('public_web.httpx.HTTPTransport', return_value=transport) as factory:
            addresses, ttl = web._resolve_doh('public.example.org', 2, 'http://127.0.0.1:10808')
            self.assertEqual(addresses, [PUBLIC_IP])
            self.assertEqual(ttl, 60)
            self.assertEqual(queries[0].url.host, '8.8.8.8')
            self.assertEqual(queries[0].headers['host'], 'dns.google')
            self.assertEqual(factory.call_args.kwargs['verify']._expected_hostname, 'dns.google')
            self.assertFalse(factory.call_args.kwargs['trust_env'])
            data['Answer'].append({'name': 'public.example.org.', 'type': 1, 'TTL': 120, 'data': '169.254.169.254'})
            self.assert_code('unsafe_url', lambda: web._resolve_doh('public.example.org', 2, 'http://127.0.0.1:10808'))

    def test_doh_mismatched_question_and_oversized_body_are_rejected(self):
        for body in (json.dumps({'Status': 0, 'Question': [{'name': 'other.example.org.', 'type': 1}], 'Answer': []}), 'x' * 20000):
            transport = httpx.MockTransport(lambda request: response(request, body=body, content_type='application/json'))
            with patch('public_web.httpx.HTTPTransport', return_value=transport):
                self.assert_code('web_unavailable', lambda: web._resolve_doh('public.example.org', 2, 'http://127.0.0.1:10808'))

    def test_only_fixed_search_hosts_use_trusted_proxy_remote_dns(self):
        def must_not_resolve(host, timeout):
            raise AssertionError('Fixed search hosts should preserve the trusted proxy domain route.')
        with patch.dict(os.environ, {'SERA_PUBLIC_WEB_PROXY': 'http://127.0.0.1:10808'}):
            session = self.session(resolver=must_not_resolve)
            self.assertTrue(session.search_public_web('通用公共资料')['ok'])
            self.assertEqual(self.requests[0].url.host, 'www.so.com')
            self.assertEqual(session.events[0]['connectionPolicy'], 'fixed-search-host-through-trusted-proxy')
        self.assertEqual(len(self.requests), 2)

    def test_fixed_search_exception_cannot_target_other_hosts_or_engine_redirect_paths(self):
        session = self.session()
        for target in (PAGE, 'https://html.duckduckgo.com/l/?uddg=https://127.0.0.1/',
                       'https://www.bing.com/other', 'https://127.0.0.1/search'):
            self.assert_code('unsafe_url', lambda: session._fetch(target, search=True, redirect_hosts={'news.example.org'}))
        self.assertEqual(self.requests, [])

    def test_arbitrary_read_with_proxy_still_requires_checked_public_ip(self):
        with patch.dict(os.environ, {'SERA_PUBLIC_WEB_PROXY': 'http://127.0.0.1:10808'}):
            session = self.session()
            session._urls[PAGE] = self.clock() + 30
            page = session.read_public_page(PAGE)
            self.assertTrue(page['ok'])
            self.assertEqual(self.requests[0].url.host, PUBLIC_IP)
            self.assertEqual(self.requests[0].headers['host'], 'news.example.org')
            self.assertEqual(session.events[0]['connectionPolicy'], 'checked-public-ip')

    def test_360_organic_results_use_actual_direct_destination_and_keep_generic_text(self):
        body = ('<ul class="result"><li class="res-list" data-result-type="normal"><h3 class="res-title">'
                '<a href="https://www.so.com/link?opaque=tracking" data-mdurl="https://docs.python.org/3/library/asyncio.html">'
                'Python <em>asyncio</em> documentation</a></h3><p class="res-desc"><span>Official</span> async I/O manual</p></li>'
                '<li class="res-list" data-result-type="ad"><h3 class="res-title"><a data-mdurl="https://ads.example.org/">ad</a></h3></li>'
                '<li class="res-list"><h3 class="res-title"><a href="https://www.so.com/link?opaque=unknown">opaque only</a></h3></li></ul>')
        session = self.session(handler=lambda request: response(request, body=body))
        found = session.search_public_web('Python asyncio 官方文档')
        self.assertEqual(found, {'ok': True, 'results': [{'title': 'Python asyncio documentation',
                          'url': 'https://docs.python.org/3/library/asyncio.html', 'snippet': 'Official async I/O manual'}]})
        self.assertEqual(session.last_search_provider, '360')
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(parse_qs(self.requests[0].url.query.decode())['q'], ['Python asyncio 官方文档'])

    def test_360_private_direct_destination_is_not_authorized(self):
        body = ('<li class="res-list"><h3 class="res-title"><a data-mdurl="https://169.254.169.254/">'
                'private</a></h3><p class="res-desc">untrusted result</p></li>')
        session = self.session(handler=lambda request: response(request, body=body))
        self.assertEqual(session.search_public_web('任意公开搜索'), {'ok': True, 'results': []})
        self.assertEqual(session.allowed_urls, frozenset())


if __name__ == '__main__':
    unittest.main()
