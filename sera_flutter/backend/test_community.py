"""Community integration tests: temporary SQLite, inert providers, no live data."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image, PngImagePlugin

from app import create_app
from auth_store import AuthError, AuthStore
from community_store import CommunityStore, MEDIA_MAX_BYTES
from test_server import empty_workspace


_PREFIX = '/api/v1/community'
_PASSWORD = 'IsolatedCommunityPassword123'


def _permissions(**enabled):
    return {'publishOfficial': False, 'publishActivity': False,
            'moderatePosts': False, 'moderateComments': False, **enabled}


class CommunityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'community.sqlite3'
        accounts = AuthStore(self.path)
        self.a, self.b, self.official = [accounts.register({
            'username': name, 'email': name + '@example.test', 'password': _PASSWORD,
        }) for name in ('reader-a', 'reader-b', 'official-account')]
        environment = patch.dict(os.environ, {
            'SERA_COMMUNITY_OFFICIAL_USER_IDS': self.official['user']['id'],
            'SERA_MAIL_MODE': 'local', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test',
        })
        environment.start()
        self.addCleanup(environment.stop)
        inert = SimpleNamespace(configured=False, model='isolated-no-network')
        self.app = create_app(db_path=self.path, ai_service=inert, transcriber=inert,
                              sms_service=SimpleNamespace(capabilities=lambda: {'enabled': False}))
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.addCleanup(lambda: self.client.__exit__(None, None, None))
        self.store = self.app.state.community
        self.sequence = 0

    @staticmethod
    def headers(session):
        return {'Authorization': 'Bearer ' + session['token']} if session else {}

    def next_request(self):
        self.sequence += 1
        return f'isolated-{self.sequence}'

    def post_body(self, **changes):
        return {'requestId': self.next_request(), 'title': '', 'content': '今天完成了一点进展。',
                'kind': 'post', 'official': False, **changes}

    def publish(self, session=None, **changes):
        response = self.client.post(_PREFIX + '/posts', headers=self.headers(session or self.a),
                                    json=self.post_body(**changes))
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()['post']

    def comment(self, post_id, session=None, **changes):
        response = self.client.post(f'{_PREFIX}/posts/{post_id}/comments', headers=self.headers(session or self.a),
                                    json={'requestId': self.next_request(), 'content': '记录真实进展。', **changes})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def detail(self, post_id, session=None, **params):
        response = self.client.get(f'{_PREFIX}/posts/{post_id}', headers=self.headers(session), params=params)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def membership(self, post_id, session, name, value):
        field = 'liked' if name == 'like' else 'joined'
        response = self.client.put(f'{_PREFIX}/posts/{post_id}/{name}', headers=self.headers(session), json={field: value})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['post']

    def assert_error(self, response, status, code=None):
        self.assertEqual(response.status_code, status, response.text)
        self.assertTrue(response.json().get('error'), response.text)
        if code:
            self.assertEqual(response.json()['code'], code)

    @staticmethod
    def image_bytes(*, format='PNG', mode='RGB', size=(64, 40), color=None, **options):
        with Image.new(mode, size, color or ((20, 80, 140, 100) if mode == 'RGBA' else (20, 80, 140))) as image:
            output = BytesIO()
            image.save(output, format, **options)
            return output.getvalue()

    def upload(self, session=None, *, raw=None, mime='image/png', request_id=None):
        response = self.client.post(_PREFIX + '/media', content=raw if raw is not None else self.image_bytes(),
            headers={**self.headers(session or self.a), 'Content-Type': mime,
                     'Idempotency-Key': request_id or self.next_request()})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()['media']

    def test_media_upload_is_private_until_post_publish_and_keeps_order_across_reads_and_interactions(self):
        media = [self.upload(raw=self.image_bytes(size=(50 + index, 40))) for index in range(3)]
        for image in media:
            private = self.client.get(image['url'], headers=self.headers(self.a))
            self.assertEqual(private.status_code, 200)
            self.assertEqual(private.headers['content-type'], image['mimeType'])
            self.assertEqual(private.headers['cache-control'], 'private, no-store')
            self.assertEqual(private.headers['x-content-type-options'], 'nosniff')
            self.assertEqual(len(private.content), image['bytes'])
            self.assert_error(self.client.get(image['url']), 404, 'community_media_not_found')
            self.assert_error(self.client.get(image['url'], headers=self.headers(self.b)), 404, 'community_media_not_found')
        ordered = list(reversed(media))
        post = self.publish(category='feedback', mediaIds=[image['id'] for image in ordered], requestId='with-images')
        self.assertEqual(post['media'], ordered)
        self.assertEqual(self.detail(post['id'])['post']['media'], ordered)
        self.assertEqual(self.client.get(_PREFIX + '/posts', params={'filter': 'feedback'}).json()['posts'][0]['media'], ordered)
        self.assertEqual(self.membership(post['id'], self.b, 'like', True)['media'], ordered)
        self.assertEqual(self.comment(post['id'], self.b)['post']['media'], ordered)
        reopened = CommunityStore(AuthStore(self.path))
        self.assertEqual(reopened.detail(post['id'])['post']['media'], ordered)
        for image in media:
            self.assertEqual(self.client.get(image['url']).status_code, 200)
        self.assertEqual(self.publish()['media'], [])

    def test_media_is_oriented_resized_metadata_free_and_alpha_is_preserved(self):
        exif = Image.Exif()
        exif[274] = 6
        exif[315] = 'private author'
        raw = self.image_bytes(format='JPEG', size=(2000, 1000), exif=exif, comment=b'private comment')
        jpeg = self.upload(raw=raw, mime='image/jpeg')
        self.assertEqual((jpeg['width'], jpeg['height'], jpeg['mimeType']), (800, 1600, 'image/jpeg'))
        with Image.open(BytesIO(self.client.get(jpeg['url'], headers=self.headers(self.a)).content)) as decoded:
            self.assertEqual(decoded.size, (800, 1600))
            self.assertEqual(decoded.mode, 'RGB')
            self.assertEqual(dict(decoded.getexif()), {})
            self.assertNotIn('comment', decoded.info)
            self.assertNotIn('icc_profile', decoded.info)
        pnginfo = PngImagePlugin.PngInfo()
        pnginfo.add_text('Author', 'private author')
        alpha = self.upload(raw=self.image_bytes(mode='RGBA', pnginfo=pnginfo))
        self.assertEqual(alpha['mimeType'], 'image/png')
        with Image.open(BytesIO(self.client.get(alpha['url'], headers=self.headers(self.a)).content)) as decoded:
            self.assertEqual(decoded.mode, 'RGBA')
            self.assertEqual(decoded.getpixel((0, 0))[3], 100)
            self.assertNotIn('Author', decoded.info)
            self.assertEqual(dict(decoded.getexif()), {})
        webp = self.upload(raw=self.image_bytes(format='WEBP'), mime='image/webp')
        self.assertEqual((webp['width'], webp['height'], webp['mimeType']), (64, 40, 'image/jpeg'))

    def test_media_rejects_forged_types_unsupported_data_truncation_size_and_pixel_bombs(self):
        png = self.image_bytes()
        invalid = [
            (png, 'image/jpeg', 415, 'community_media_type'),
            (b'<svg xmlns="http://www.w3.org/2000/svg"/>', 'image/png', 400, 'invalid_community_media'),
            (self.image_bytes(format='GIF'), 'image/png', 400, 'invalid_community_media'),
            (png, 'application/octet-stream', 415, 'community_media_type'),
            (png[:30], 'image/png', 400, 'invalid_community_media'),
            (b'x' * (MEDIA_MAX_BYTES + 1), 'image/png', 413, 'community_media_too_large'),
        ]
        for raw, mime, status, code in invalid:
            response = self.client.post(_PREFIX + '/media', content=raw, headers={
                **self.headers(self.a), 'Content-Type': mime, 'Idempotency-Key': self.next_request(),
            })
            self.assert_error(response, status, code)
        # Change only the generated PNG header and checksum, so the pixel guard
        # is exercised before any enormous allocation or truncated data decode.
        import struct
        import zlib
        for width, height in ((4001, 4000), (100_000, 100_000)):
            bomb = bytearray(png)
            bomb[16:24] = struct.pack('>II', width, height)
            bomb[29:33] = struct.pack('>I', zlib.crc32(bomb[12:29]))
            response = self.client.post(_PREFIX + '/media', content=bytes(bomb), headers={
                **self.headers(self.a), 'Content-Type': 'image/png', 'Idempotency-Key': self.next_request(),
            })
            self.assert_error(response, 413, 'community_media_pixels')
        for raw, mime in ((png, 'image/png'), (b'', 'image/png')):
            response = self.client.post(_PREFIX + '/media', content=raw,
                                        headers={**self.headers(self.a), 'Content-Type': mime})
            self.assert_error(response, 400, 'invalid_community_request')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests').fetchone()[0], 0)

    def test_media_upload_requires_auth_and_cookie_upload_keeps_csrf_guards(self):
        raw = self.image_bytes()
        headers = {'Content-Type': 'image/png', 'Idempotency-Key': 'image-auth'}
        self.assert_error(self.client.post(_PREFIX + '/media', content=raw, headers=headers), 401, 'authentication_required')
        self.assert_error(self.client.post(_PREFIX + '/media', content=raw, headers={
            **headers, 'Authorization': 'Bearer expired-token',
        }), 401, 'session_expired')
        self.client.cookies.set('sera_session', self.a['token'])
        self.assert_error(self.client.post(_PREFIX + '/media', content=raw, headers=headers), 403, 'csrf_required')
        self.client.cookies.clear()

    def test_upload_and_post_retries_share_account_scoped_idempotency_without_duplicate_media(self):
        raw = self.image_bytes()
        first = self.upload(raw=raw, request_id='image-once')
        self.assertEqual(self.upload(raw=raw, request_id='image-once'), first)
        other = self.upload(self.b, raw=raw, request_id='image-once')
        self.assertNotEqual(first['id'], other['id'])
        changed = self.client.post(_PREFIX + '/media', content=self.image_bytes(size=(20, 20)), headers={
            **self.headers(self.a), 'Content-Type': 'image/png', 'Idempotency-Key': 'image-once',
        })
        self.assert_error(changed, 409, 'idempotency_conflict')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                          json=self.post_body(requestId='image-once')), 409, 'idempotency_conflict')
        post = self.publish(requestId='image-post', mediaIds=[first['id']])
        self.assertEqual(self.publish(requestId='image-post', mediaIds=[first['id']])['id'], post['id'])
        self.assertEqual(self.upload(raw=raw, request_id='image-once')['id'], first['id'])
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                          json=self.post_body(requestId='image-post', mediaIds=[])), 409, 'idempotency_conflict')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts WHERE author_id=?', (self.a['user']['id'],)).fetchone()[0], 1)

    def test_media_attachment_validates_ownership_count_duplicates_and_atomic_claim(self):
        own = self.upload()
        foreign = self.upload(self.b)
        invalid = [(None, 400), ('image', 400), ([own['id']] * 2, 400),
                   (['one', 'two', 'three', 'four'], 400), ([7], 400),
                   ([own['id'], foreign['id']], 403), (['missing-image'], 410)]
        for media_ids, status in invalid:
            response = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                                        json=self.post_body(mediaIds=media_ids))
            self.assert_error(response, status)
        with self.app.state.accounts.connection() as db:
            self.assertIsNone(db.execute('SELECT post_id FROM community_media WHERE id=?', (own['id'],)).fetchone()[0])
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts').fetchone()[0], 2)
            db.execute('''CREATE TRIGGER isolated_media_publish_failure BEFORE INSERT ON community_requests
                WHEN NEW.operation='post' BEGIN SELECT RAISE(ABORT,'isolated publish failure'); END''')
        body = self.post_body(requestId='atomic-image-post', mediaIds=[own['id']])
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.create_post(self.a['user']['id'], self.a['token'], body)
        with self.app.state.accounts.connection() as db:
            self.assertIsNone(db.execute('SELECT post_id FROM community_media WHERE id=?', (own['id'],)).fetchone()[0])
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts').fetchone()[0], 2)
            db.execute('DROP TRIGGER isolated_media_publish_failure')
        post = self.store.create_post(self.a['user']['id'], self.a['token'], body)['post']
        self.assertEqual(post['media'], [own])
        reused = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(mediaIds=[own['id']]))
        self.assert_error(reused, 409, 'community_media_attached')
        activity_image = self.upload(self.official)
        activity = self.publish(self.official, kind='activity', official=True, title='图文活动',
                                startsAt='2026-11-10T10:00:00Z', mediaIds=[activity_image['id']])
        self.assertEqual(activity['media'], [activity_image])

    def test_expired_pending_media_is_unreadable_and_cleaned_on_upload_without_deleting_published_images(self):
        expired = self.upload(request_id='expiring-image')
        published = self.upload()
        self.publish(mediaIds=[published['id']])
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE community_media SET created_at=?', (time.time_ns() // 1000 - 25 * 60 * 60 * 1_000_000,))
        self.assert_error(self.client.get(expired['url'], headers=self.headers(self.a)), 404, 'community_media_not_found')
        self.assertEqual(self.client.get(published['url']).status_code, 200)
        response = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(mediaIds=[expired['id']]))
        self.assert_error(response, 410, 'community_media_expired')
        self.assertEqual(response.json()['details']['mediaIds'], [expired['id']])
        retry = self.client.post(_PREFIX + '/media', content=self.image_bytes(), headers={
            **self.headers(self.a), 'Content-Type': 'image/png', 'Idempotency-Key': 'expiring-image',
        })
        self.assert_error(retry, 410, 'community_media_expired')
        recent = self.upload(self.b)
        with self.app.state.accounts.connection() as db:
            self.assertEqual({row['id'] for row in db.execute('SELECT id FROM community_media')}, {published['id'], recent['id']})
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_delete_and_account_removal_reclaim_images_and_do_not_resurrect_on_retry(self):
        own = self.upload(request_id='delete-image')
        post = self.publish(mediaIds=[own['id']], requestId='delete-image-post')
        self.assertEqual(self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.a)).status_code, 200)
        self.assert_error(self.client.get(own['url']), 404, 'community_media_not_found')
        retry = self.client.post(_PREFIX + '/media', content=self.image_bytes(), headers={
            **self.headers(self.a), 'Content-Type': 'image/png', 'Idempotency-Key': 'delete-image',
        })
        self.assert_error(retry, 410, 'community_media_expired')
        pending = self.upload()
        attached = self.upload()
        self.publish(mediaIds=[attached['id']])
        other = self.upload(self.b)
        self.app.state.accounts.delete_account(self.a['token'], _PASSWORD)
        for image in (pending, attached):
            self.assert_error(self.client.get(image['url']), 404, 'community_media_not_found')
        self.assertEqual(self.client.get(other['url'], headers=self.headers(self.b)).status_code, 200)
        with self.app.state.accounts.connection() as db:
            self.assertEqual([row['id'] for row in db.execute('SELECT id FROM community_media')], [other['id']])
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_parallel_upload_and_publish_retries_create_one_image_and_one_post(self):
        uid, token, raw = self.a['user']['id'], self.a['token'], self.image_bytes()
        with ThreadPoolExecutor(max_workers=6) as workers:
            uploads = list(workers.map(lambda _: self.store.upload_media(uid, token, 'parallel-image', raw, 'image/png'), range(6)))
        self.assertEqual(len({item['media']['id'] for item in uploads}), 1)
        body = self.post_body(requestId='parallel-image-post', mediaIds=[uploads[0]['media']['id']])
        with ThreadPoolExecutor(max_workers=6) as workers:
            posts = list(workers.map(lambda _: self.store.create_post(uid, token, body), range(6)))
        self.assertEqual(len({item['post']['id'] for item in posts}), 1)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts WHERE author_id=?', (uid,)).fetchone()[0], 1)

    def test_upload_storage_failure_rolls_back_blob_and_request_and_can_retry(self):
        with self.app.state.accounts.connection() as db:
            db.execute('''CREATE TRIGGER isolated_upload_failure BEFORE INSERT ON community_requests
                WHEN NEW.operation='media' BEGIN SELECT RAISE(ABORT,'isolated upload failure'); END''')
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.upload_media(self.a['user']['id'], self.a['token'], 'retry-image', self.image_bytes(), 'image/png')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests').fetchone()[0], 0)
            db.execute('DROP TRIGGER isolated_upload_failure')
        image = self.upload(request_id='retry-image')
        self.assertEqual(self.client.get(image['url'], headers=self.headers(self.a)).status_code, 200)

    def test_logout_during_image_decode_cannot_save_late_upload_to_a_revoked_session(self):
        from community_store import _image_bytes
        def decode_then_logout(raw, mime_type):
            result = _image_bytes(raw, mime_type)
            self.app.state.accounts.logout(self.a['token'])
            return result
        with patch('community_store._image_bytes', side_effect=decode_then_logout):
            response = self.client.post(_PREFIX + '/media', content=self.image_bytes(), headers={
                **self.headers(self.a), 'Content-Type': 'image/png', 'Idempotency-Key': 'late-image',
            })
        self.assert_error(response, 401, 'session_expired')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests').fetchone()[0], 0)

    def test_v3_post_retry_without_media_returns_original_but_cannot_attach_new_images(self):
        body = self.post_body(requestId='v3-feedback', category='feedback')
        post = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=body).json()['post']
        legacy_payload = {key: value for key, value in body.items() if key != 'requestId'}
        legacy_payload.update(startsAt=None, place='')
        digest = hashlib.sha256(json.dumps(legacy_payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        with self.app.state.accounts.connection() as db:
            db.execute("UPDATE community_requests SET payload_hash=? WHERE request_id='v3-feedback'", (digest,))
        for extra in ({}, {'mediaIds': []}):
            retry = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={**body, **extra})
            self.assertEqual(retry.status_code, 201, retry.text)
            self.assertEqual(retry.json()['post']['id'], post['id'])
            self.assertEqual(retry.json()['post']['media'], [])
        media = self.upload()
        changed = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={**body, 'mediaIds': [media['id']]})
        self.assert_error(changed, 409, 'idempotency_conflict')
        self.assert_error(self.client.get(media['url']), 404, 'community_media_not_found')

    def test_expired_image_details_allow_reuploading_only_failed_images_and_keep_publish_request(self):
        expired = self.upload()
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE community_media SET created_at=? WHERE id=?',
                       (time.time_ns() // 1000 - 25 * 60 * 60 * 1_000_000, expired['id']))
        kept = self.upload()  # An upload opportunity removes only the expired blob.
        body = self.post_body(requestId='retry-some-images', mediaIds=[expired['id'], kept['id'], 'missing-image'])
        response = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=body)
        self.assert_error(response, 410, 'community_media_expired')
        self.assertEqual(response.json()['details']['mediaIds'], [expired['id'], 'missing-image'])
        self.assertEqual(self.client.get(kept['url'], headers=self.headers(self.a)).status_code, 200)
        replacements = [self.upload(), self.upload()]
        retry = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={
            **body, 'mediaIds': [replacements[0]['id'], kept['id'], replacements[1]['id']],
        })
        self.assertEqual(retry.status_code, 201, retry.text)
        self.assertEqual(retry.json()['post']['media'], [replacements[0], kept, replacements[1]])

    def test_guest_reads_seeded_official_content_without_fabricated_activity_and_seed_is_once_only(self):
        response = self.client.get(_PREFIX + '/posts')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        result = response.json()
        self.assertEqual(result['viewer'], {
            'signedIn': False, 'canPublishOfficial': False, 'isOfficial': False,
            'isAdmin': False, 'canManageAdmins': False, 'permissions': _permissions(),
        })
        self.assertIsNone(result['nextCursor'])
        self.assertEqual(len(result['posts']), 2)
        initial_ids = {post['id'] for post in result['posts']}
        for post in result['posts']:
            self.assertTrue(post['isOfficial'])
            self.assertTrue(post['authorIsOfficial'])
            self.assertEqual(post['category'], 'daily')
            self.assertEqual(post['authorName'], 'SERA 官方')
            self.assertIsNone(post['authorId'])
            self.assertFalse(post['canDelete'])
            self.assertEqual((post['likeCount'], post['commentCount'], post['participantCount']), (0, 0, 0))
            self.assertFalse(post['liked'])
            self.assertFalse(post['joined'])
        activity = next(post for post in result['posts'] if post['kind'] == 'activity')
        self.assertIn('课设演示', activity['title'])
        self.assertTrue(activity['startsAt'].endswith('Z'))
        detail = self.detail(activity['id'])
        self.assertEqual(detail['comments'], [])
        self.assertIsNone(detail['commentsNextCursor'])
        reopened = CommunityStore(AuthStore(self.path), official_user_ids=[self.official['user']['id']])
        self.assertEqual({post['id'] for post in reopened.list_posts()['posts']}, initial_ids)
        deleted = self.client.delete(f'{_PREFIX}/posts/{activity["id"]}', headers=self.headers(self.official))
        self.assertEqual(deleted.json(), {'deleted': True})
        reopened = CommunityStore(AuthStore(self.path), official_user_ids=[self.official['user']['id']])
        self.assertEqual(len(reopened.list_posts()['posts']), 1)

    def test_guest_mutations_require_a_session_and_expired_tokens_read_as_guest(self):
        post_id = self.publish()['id']
        calls = [
            ('POST', '/posts', self.post_body()),
            ('POST', f'/posts/{post_id}/comments', {'requestId': 'guest-comment', 'content': '不应写入'}),
            ('PUT', f'/posts/{post_id}/like', {'liked': True}),
            ('PUT', f'/posts/{post_id}/join', {'joined': True}),
            ('DELETE', f'/posts/{post_id}', None),
            ('DELETE', '/comments/nonexistent', None),
        ]
        for method, path, body in calls:
            with self.subTest(method=method, path=path):
                response = self.client.request(method, _PREFIX + path, json=body)
                self.assert_error(response, 401, 'authentication_required')
        bad = self.client.get(_PREFIX + '/posts', headers={'Authorization': 'Bearer expired-token'})
        self.assertEqual(bad.status_code, 200, bad.text)
        self.assertFalse(bad.json()['viewer']['signedIn'])
        self.assertTrue(all(not post['canDelete'] and not post['liked'] and not post['joined'] for post in bad.json()['posts']))
        self.assertEqual(self.detail(post_id)['post']['likeCount'], 0)

    def _assert_stale_session_reads_public_content_but_cannot_write(self, *, cookie):
        public_image = self.upload()
        pending_image = self.upload()
        post = self.publish(mediaIds=[public_image['id']])
        comment = self.comment(post['id'])['comment']
        self.membership(post['id'], self.a, 'like', True)
        if cookie:
            login = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
                json={'identifier': 'reader-a', 'password': _PASSWORD})
            self.assertEqual(login.status_code, 200, login.text)
            token = self.client.cookies.get('sera_session')
            read_headers = {}
            write_headers = {'X-CSRF-Token': login.json()['csrfToken']}
        else:
            token = self.a['token']
            read_headers = self.headers(self.a)
            write_headers = read_headers
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE sessions SET expires_at=0 WHERE token_hash=?', (hashlib.sha256(token.encode()).hexdigest(),))
        # /auth/me keeps reporting expiry. Only public community endpoints opt
        # into guest semantics, without clearing another tab's cookie.
        self.assert_error(self.client.get('/api/v1/auth/me', headers=read_headers), 401, 'session_expired')
        for path in ('/posts', '/posts/' + post['id']):
            response = self.client.get(_PREFIX + path, headers=read_headers)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertFalse(response.json()['viewer']['signedIn'])
            self.assertFalse(response.json()['viewer']['canManageAdmins'])
            self.assertNotIn('set-cookie', response.headers)
            posts = response.json().get('posts', [response.json().get('post')])
            self.assertTrue(all(not item['liked'] and not item['joined'] and not item['canDelete'] for item in posts))
            self.assertTrue(all(not item['canDelete'] for item in response.json().get('comments', [])))
        public = self.client.get(public_image['url'], headers=read_headers)
        self.assertEqual(public.status_code, 200, public.text)
        self.assertEqual(public.headers['content-type'], public_image['mimeType'])
        self.assertNotIn('set-cookie', public.headers)
        self.assert_error(self.client.get(pending_image['url'], headers=read_headers), 404, 'community_media_not_found')
        self.assert_error(self.client.get(_PREFIX + '/management', headers=read_headers), 401, 'session_expired')
        calls = [
            ('POST', '/posts', self.post_body()),
            ('POST', f'/posts/{post["id"]}/comments', {'requestId': 'stale-comment', 'content': '不应写入'}),
            ('PUT', f'/posts/{post["id"]}/like', {'liked': False}),
            ('PUT', f'/posts/{post["id"]}/join', {'joined': True}),
            ('DELETE', f'/posts/{post["id"]}', None),
            ('DELETE', f'/comments/{comment["id"]}', None),
            ('POST', '/admin-applications', {'requestId': 'stale-apply', 'reason': '不应写入'}),
            ('POST', '/admins', {'identifier': 'reader-b', 'permissions': _permissions()}),
            ('PUT', f'/admins/{self.b["user"]["id"]}', {'permissions': _permissions()}),
            ('DELETE', f'/admins/{self.b["user"]["id"]}', None),
            ('PUT', '/admin-applications/missing-application', {'status': 'rejected'}),
        ]
        for method, path, body in calls:
            response = self.client.request(method, _PREFIX + path, headers=write_headers, json=body)
            self.assert_error(response, 401, 'session_expired')
            self.assertNotIn('set-cookie', response.headers)
        upload = self.client.post(_PREFIX + '/media', content=self.image_bytes(), headers={
            **write_headers, 'Content-Type': 'image/png', 'Idempotency-Key': 'stale-upload',
        })
        self.assert_error(upload, 401, 'session_expired')
        if cookie:
            self.assertEqual(self.client.cookies.get('sera_session'), token)
        unchanged = self.store.detail(post['id'])
        self.assertEqual((unchanged['post']['likeCount'], unchanged['post']['commentCount']), (1, 1))
        self.assertEqual(unchanged['comments'][0]['id'], comment['id'])
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_media').fetchone()[0], 2)

    def test_expired_bearer_reads_public_feed_detail_media_as_guest_and_all_writes_stay_unauthorized(self):
        self._assert_stale_session_reads_public_content_but_cannot_write(cookie=False)

    def test_stale_cookie_reads_public_feed_detail_media_without_erasing_cookie_and_all_writes_stay_unauthorized(self):
        self._assert_stale_session_reads_public_content_but_cannot_write(cookie=True)

    def test_optional_community_auth_does_not_hide_permission_or_service_failures(self):
        for status in (403, 503):
            with patch.object(self.app.state, 'require', side_effect=AuthError('隔离测试鉴权错误', status, 'isolated_auth_failure')):
                response = self.client.get(_PREFIX + '/posts', headers=self.headers(self.a))
                self.assert_error(response, status, 'isolated_auth_failure')

    def test_official_capability_is_server_owned_and_personal_posts_are_not_official_by_name(self):
        for changes in (
            {'official': True},
            {'official': True, 'kind': 'activity', 'title': '伪造活动', 'startsAt': '2026-11-10T10:00:00Z'},
            {'official': False, 'kind': 'activity', 'title': '伪造活动', 'startsAt': '2026-11-10T10:00:00Z'},
        ):
            response = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(**changes))
            self.assert_error(response, 403, 'community_official_required')
        forged = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                                  json=self.post_body(authorId=self.official['user']['id']))
        self.assert_error(forged, 400)
        activity = self.publish(self.official, official=True, kind='activity', title='周末专注活动',
                                startsAt='2026-11-10T10:00:00+08:00', place='线上')
        self.assertEqual(activity['startsAt'], '2026-11-10T02:00:00Z')
        self.assertTrue(activity['isOfficial'])
        self.assertEqual(activity['authorName'], 'SERA 官方')
        self.assertEqual(activity['authorId'], self.official['user']['id'])
        self.assertTrue(self.detail(activity['id'], self.official)['viewer']['canPublishOfficial'])
        self.assertFalse(self.detail(activity['id'], self.a)['viewer']['canPublishOfficial'])
        self.assertFalse(self.publish(self.official)['isOfficial'])
        comment = self.comment(activity['id'], self.official)['comment']
        self.assertTrue(comment['isOfficial'])
        self.assertEqual(comment['authorName'], 'SERA 官方')

    def test_publishing_is_persistent_account_scoped_idempotent_and_does_not_mutate_workspaces(self):
        for session in (self.a, self.b):
            response = self.client.put('/api/v1/workspace', headers=self.headers(session),
                                       json={'workspace': empty_workspace(), 'expectedRevision': 0})
            self.assertEqual(response.status_code, 200, response.text)
        before = {session['user']['id']: self.app.state.sync.load(session['user']['id']) for session in (self.a, self.b)}
        body = self.post_body(requestId='same-key', title='', content='没有标题也能分享日常。')
        first = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=body)
        retry = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=body)
        self.assertEqual(first.status_code, 201, first.text)
        self.assertEqual(retry.json()['post']['id'], first.json()['post']['id'])
        changed = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={**body, 'content': '不同内容'})
        self.assert_error(changed, 409, 'idempotency_conflict')
        other = self.client.post(_PREFIX + '/posts', headers=self.headers(self.b), json=body)
        self.assertEqual(other.status_code, 201, other.text)
        self.assertNotEqual(other.json()['post']['id'], first.json()['post']['id'])
        self.assertEqual(other.json()['post']['authorId'], self.b['user']['id'])
        reopened = CommunityStore(AuthStore(self.path))
        self.assertEqual(reopened.detail(first.json()['post']['id'])['post']['content'], body['content'])
        self.assertEqual({uid: self.app.state.sync.load(uid) for uid in before}, before)

    def test_feedback_uses_real_posts_and_interactions_without_changing_official_or_all_filters(self):
        daily = self.publish()
        personal_feedback = self.publish(category='feedback', content='语音输入后希望更容易核对日期。')
        official_feedback = self.publish(self.official, official=True, category='feedback', content='欢迎分享使用体验。')
        activity = self.publish(self.official, official=True, kind='activity', title='体验交流',
                                startsAt='2026-11-10T10:00:00Z')
        self.assertEqual(daily['category'], 'daily')
        self.assertEqual(activity['category'], 'daily')
        feedback = self.client.get(_PREFIX + '/posts', params={'filter': 'feedback'}).json()['posts']
        self.assertEqual([post['id'] for post in feedback], [official_feedback['id'], personal_feedback['id']])
        self.assertTrue(all(post['kind'] == 'post' and post['category'] == 'feedback' for post in feedback))
        all_posts = self.client.get(_PREFIX + '/posts').json()['posts']
        official_posts = self.client.get(_PREFIX + '/posts', params={'filter': 'official'}).json()['posts']
        self.assertEqual(len(all_posts), 6)
        self.assertEqual({post['id'] for post in official_posts},
                         {post['id'] for post in all_posts if post['isOfficial']})
        liked = self.membership(personal_feedback['id'], self.b, 'like', True)
        self.assertEqual((liked['category'], liked['likeCount']), ('feedback', 1))
        comment = self.comment(personal_feedback['id'], self.b, content='我也遇到了相同的情况。')
        self.assertEqual((comment['post']['category'], comment['post']['commentCount']), ('feedback', 1))
        reopened = CommunityStore(AuthStore(self.path))
        detail = reopened.detail(personal_feedback['id'], self.b['user']['id'])
        self.assertTrue(detail['post']['liked'])
        self.assertEqual(detail['post']['category'], 'feedback')
        self.assertEqual(detail['comments'][0]['id'], comment['comment']['id'])
        self.assert_error(self.client.put(f'{_PREFIX}/posts/{personal_feedback["id"]}/join',
                          headers=self.headers(self.a), json={'joined': True}), 400, 'community_activity_required')
        self.assertEqual(self.client.delete(f'{_PREFIX}/posts/{personal_feedback["id"]}',
                         headers=self.headers(self.a)).json(), {'deleted': True})
        remaining = self.client.get(_PREFIX + '/posts', params={'filter': 'feedback'}).json()['posts']
        self.assertEqual([post['id'] for post in remaining], [official_feedback['id']])

    def test_category_validation_never_partially_creates_a_post_or_claims_a_request(self):
        for category in (None, '', 'support', 'Feedback', True, 0, [], {}):
            response = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                                        json=self.post_body(category=category))
            self.assert_error(response, 400, 'invalid_community_request')
        activity = self.post_body(kind='activity', official=True, title='体验交流',
                                  startsAt='2026-11-10T10:00:00Z', category='feedback')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.official), json=activity), 400)
        feedback_with_time = self.post_body(category='feedback', startsAt='2026-11-10T10:00:00Z')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=feedback_with_time), 400)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests').fetchone()[0], 0)
        # A corrected submission can still use the previously rejected key.
        corrected = self.client.post(_PREFIX + '/posts', headers=self.headers(self.official),
                                     json={**activity, 'category': 'daily'})
        self.assertEqual(corrected.status_code, 201, corrected.text)
        self.assertEqual(corrected.json()['post']['category'], 'daily')

    def test_idempotency_normalizes_omitted_daily_but_never_reclassifies_an_existing_post(self):
        body = self.post_body(requestId='category-daily')
        first = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=body).json()['post']
        explicit = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={**body, 'category': 'daily'})
        self.assertEqual(explicit.status_code, 201, explicit.text)
        self.assertEqual(explicit.json()['post']['id'], first['id'])
        changed = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json={**body, 'category': 'feedback'})
        self.assert_error(changed, 409, 'idempotency_conflict')
        feedback = self.post_body(requestId='category-feedback', category='feedback')
        posted = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=feedback).json()['post']
        replay = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=feedback)
        self.assertEqual(replay.json()['post']['id'], posted['id'])
        without_category = {key: value for key, value in feedback.items() if key != 'category'}
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=without_category),
                          409, 'idempotency_conflict')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests').fetchone()[0], 2)
        self.assertEqual(self.detail(first['id'])['post']['category'], 'daily')
        self.assertEqual(self.detail(posted['id'])['post']['category'], 'feedback')

    def test_feedback_pagination_is_stable_across_new_posts_and_cursors_cannot_cross_filters(self):
        ids = []
        for index in range(5):
            ids.append(self.publish(self.official if index % 2 else self.a, official=bool(index % 2),
                                    category='feedback', content=f'使用反馈 {index}')['id'])
            self.publish(content=f'日常记录 {index}')
        page = self.client.get(_PREFIX + '/posts', params={'filter': 'feedback', 'limit': 2}).json()
        self.assertEqual([post['id'] for post in page['posts']], ids[::-1][:2])
        newer = self.publish(category='feedback', content='翻页期间发布的新反馈')['id']
        seen = [post['id'] for post in page['posts']]
        first_cursor = page['nextCursor']
        while page['nextCursor']:
            page = self.client.get(_PREFIX + '/posts', params={
                'filter': 'feedback', 'limit': 2, 'cursor': page['nextCursor'],
            }).json()
            seen.extend(post['id'] for post in page['posts'])
        self.assertEqual(seen, ids[::-1])
        self.assertNotIn(newer, seen)
        for other_filter in ('all', 'official'):
            response = self.client.get(_PREFIX + '/posts', params={'filter': other_filter, 'cursor': first_cursor})
            self.assert_error(response, 400, 'invalid_community_request')
        refreshed = self.client.get(_PREFIX + '/posts', params={'filter': 'feedback'}).json()
        self.assertEqual(refreshed['posts'][0]['id'], newer)

    def test_v2_database_migration_preserves_records_interactions_and_legacy_retry_hashes(self):
        legacy_accounts = AuthStore(Path(self.temp.name) / 'legacy-v2.sqlite3')
        session = legacy_accounts.register({'username': 'legacy-reader', 'email': 'legacy@example.test', 'password': _PASSWORD})
        uid, token = session['user']['id'], session['token']
        payload = {'title': '', 'content': '迁移前的日常记录', 'kind': 'post',
                   'official': False, 'startsAt': None, 'place': ''}
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        with legacy_accounts.connection() as db:
            db.executescript('''
                CREATE TABLE community_schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
                INSERT INTO community_schema_migrations VALUES(1,1),(2,2);
                CREATE TABLE community_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                INSERT INTO community_meta VALUES('seed-v1','created');
                CREATE TABLE community_posts(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
                    author_id TEXT REFERENCES users(id) ON DELETE CASCADE,
                    is_official INTEGER NOT NULL CHECK(is_official IN (0,1)),
                    kind TEXT NOT NULL CHECK(kind IN ('post','activity')),
                    title TEXT NOT NULL,content TEXT NOT NULL,created_at INTEGER NOT NULL,
                    starts_at TEXT,place TEXT NOT NULL DEFAULT '',
                    CHECK(author_id IS NOT NULL OR is_official=1),
                    CHECK(kind!='activity' OR (is_official=1 AND starts_at IS NOT NULL)),
                    CHECK(kind!='post' OR (starts_at IS NULL AND place='')));
                CREATE TABLE community_comments(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
                    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
                    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    is_official INTEGER NOT NULL CHECK(is_official IN (0,1)),content TEXT NOT NULL,created_at INTEGER NOT NULL);
                CREATE TABLE community_likes(
                    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,PRIMARY KEY(post_id,user_id));
                CREATE TABLE community_requests(
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    request_id TEXT NOT NULL,operation TEXT NOT NULL,payload_hash TEXT NOT NULL,result_id TEXT NOT NULL,
                    PRIMARY KEY(user_id,request_id));
            ''')
            db.execute('''INSERT INTO community_posts(id,author_id,is_official,kind,title,content,created_at)
                VALUES('legacy-post',?,0,'post','',?,1234567)''', (uid, payload['content']))
            db.execute('''INSERT INTO community_posts(id,author_id,is_official,kind,title,content,created_at,starts_at,place)
                VALUES('legacy-activity',NULL,1,'activity','旧活动','保留活动内容',1234568,'2026-11-10T10:00:00Z','线上')''')
            db.execute("INSERT INTO community_comments(id,post_id,author_id,is_official,content,created_at) VALUES('legacy-comment','legacy-post',?,0,'原评论',1234569)", (uid,))
            db.execute("INSERT INTO community_likes VALUES('legacy-post',?)", (uid,))
            db.execute("INSERT INTO community_requests VALUES(?,'legacy-request','post',?,'legacy-post')", (uid, digest))
            original_rows = [dict(row) for row in db.execute('SELECT * FROM community_posts ORDER BY sequence')]
        for _ in range(2):
            migrated = CommunityStore(legacy_accounts)
            rows = migrated.list_posts(uid)['posts']
            self.assertEqual({post['id'] for post in rows}, {'legacy-post', 'legacy-activity'})
            self.assertTrue(all(post['category'] == 'daily' for post in rows))
            self.assertEqual(migrated.list_posts(filter='feedback')['posts'], [])
            detail = migrated.detail('legacy-post', uid)
            self.assertTrue(detail['post']['liked'])
            self.assertEqual((detail['post']['likeCount'], detail['post']['commentCount']), (1, 1))
            self.assertEqual(detail['comments'][0]['id'], 'legacy-comment')
            for extra in ({}, {'category': 'daily'}):
                replay = migrated.create_post(uid, token, {'requestId': 'legacy-request', **payload, **extra})
                self.assertEqual(replay['post']['id'], 'legacy-post')
            with self.assertRaises(AuthError) as changed:
                migrated.create_post(uid, token, {'requestId': 'legacy-request', **payload, 'category': 'feedback'})
            self.assertEqual(changed.exception.code, 'idempotency_conflict')
        with legacy_accounts.connection() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT version FROM community_schema_migrations ORDER BY version')], [1, 2, 3, 4])
            self.assertEqual(db.execute("SELECT payload_hash FROM community_requests WHERE request_id='legacy-request'").fetchone()[0], digest)
            for row, original in zip(db.execute('SELECT * FROM community_posts ORDER BY sequence'), original_rows):
                self.assertEqual({key: row[key] for key in original}, original)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE community_posts SET category='unsupported' WHERE id='legacy-post'")
        migrated.delete_post('legacy-post', uid, token)
        with self.assertRaises(AuthError) as deleted:
            migrated.create_post(uid, token, {'requestId': 'legacy-request', **payload})
        self.assertEqual(deleted.exception.code, 'community_content_deleted')
        with legacy_accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_comments').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_likes').fetchone()[0], 0)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_author_identity_stays_consistent_across_personal_and_official_content(self):
        self.grant(self.a, publishOfficial=True)
        admin_daily = self.publish(self.a)
        admin_official = self.publish(self.a, official=True)
        owner_daily = self.publish(self.official)
        owner_official = self.publish(self.official, official=True)
        self.assertEqual(admin_daily['authorName'], admin_official['authorName'])
        self.assertEqual(admin_official['authorName'], 'reader-a')
        self.assertTrue(admin_official['isOfficial'])
        self.assertFalse(admin_official['authorIsOfficial'])
        self.assertFalse(admin_daily['authorIsOfficial'])
        self.assertEqual(owner_daily['authorName'], owner_official['authorName'])
        self.assertTrue(owner_daily['authorIsOfficial'])
        self.assertTrue(owner_official['authorIsOfficial'])
        self.assertFalse(owner_daily['isOfficial'])
        admin_comment = self.comment(owner_daily['id'], self.a)['comment']
        owner_comment = self.comment(owner_daily['id'], self.official)['comment']
        self.assertEqual(admin_comment['authorName'], admin_official['authorName'])
        self.assertFalse(admin_comment['authorIsOfficial'])
        self.assertTrue(owner_comment['authorIsOfficial'])
        self.assertEqual(owner_comment['authorName'], owner_daily['authorName'])
        forged_post = self.client.post(_PREFIX + '/posts', headers=self.headers(self.b),
                                       json=self.post_body(authorIsOfficial=True))
        self.assert_error(forged_post, 400, 'invalid_community_request')
        forged_comment = self.client.post(f'{_PREFIX}/posts/{owner_daily["id"]}/comments', headers=self.headers(self.b),
            json={'requestId': 'forged-identity', 'content': '普通评论', 'authorIsOfficial': True})
        self.assert_error(forged_comment, 400, 'invalid_community_request')

    def test_likes_comments_and_activity_join_are_real_and_isolated_per_viewer(self):
        activity = next(post for post in self.store.list_posts()['posts'] if post['kind'] == 'activity')
        pid = activity['id']
        for _ in range(2):
            liked = self.membership(pid, self.a, 'like', True)
            self.assertEqual(liked['likeCount'], 1)
            self.assertTrue(liked['liked'])
            joined = self.membership(pid, self.a, 'join', True)
            self.assertEqual(joined['participantCount'], 1)
        b_before = self.detail(pid, self.b)['post']
        self.assertEqual(b_before['likeCount'], 1)
        self.assertFalse(b_before['liked'])
        self.assertFalse(b_before['joined'])
        self.membership(pid, self.b, 'like', True)
        self.membership(pid, self.b, 'join', True)
        first = self.comment(pid, self.a, requestId='comment-once')['comment']
        retry = self.comment(pid, self.a, requestId='comment-once')['comment']
        self.assertEqual(first['id'], retry['id'])
        self.assertTrue(first['canDelete'])
        other = self.comment(pid, self.b, requestId='comment-once')['comment']
        self.assertNotEqual(first['id'], other['id'])
        self.assertEqual(other['authorId'], self.b['user']['id'])
        a_view = self.detail(pid, self.a)
        self.assertEqual(a_view['post']['commentCount'], 2)
        self.assertEqual([comment['canDelete'] for comment in a_view['comments']], [True, False])
        self.membership(pid, self.a, 'like', False)
        self.membership(pid, self.a, 'join', False)
        for _ in range(2):
            self.assertEqual(self.membership(pid, self.a, 'like', False)['likeCount'], 1)
            self.assertEqual(self.membership(pid, self.a, 'join', False)['participantCount'], 1)
        b_after = self.detail(pid, self.b)['post']
        self.assertTrue(b_after['liked'])
        self.assertTrue(b_after['joined'])
        guest = self.detail(pid)['post']
        self.assertFalse(guest['liked'])
        self.assertFalse(guest['joined'])
        self.assertEqual((guest['likeCount'], guest['participantCount']), (1, 1))
        ordinary = self.publish()['id']
        denied = self.client.put(f'{_PREFIX}/posts/{ordinary}/join', headers=self.headers(self.a), json={'joined': True})
        self.assert_error(denied, 400, 'community_activity_required')

    def test_delete_requires_author_or_official_and_retry_cannot_resurrect_deleted_content(self):
        post = self.publish(requestId='post-to-delete')
        comment = self.comment(post['id'], self.b, requestId='comment-to-delete')['comment']
        self.membership(post['id'], self.b, 'like', True)
        denied = self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.b))
        self.assert_error(denied, 403, 'community_delete_forbidden')
        denied = self.client.delete(f'{_PREFIX}/comments/{comment["id"]}', headers=self.headers(self.a))
        self.assert_error(denied, 403, 'community_delete_forbidden')
        for _ in range(2):
            deleted = self.client.delete(f'{_PREFIX}/comments/{comment["id"]}', headers=self.headers(self.b))
            self.assertEqual(deleted.json(), {'deleted': True})
        self.assertEqual(self.detail(post['id'])['post']['commentCount'], 0)
        replay = self.client.post(f'{_PREFIX}/posts/{post["id"]}/comments', headers=self.headers(self.b),
                                  json={'requestId': 'comment-to-delete', 'content': '记录真实进展。'})
        self.assert_error(replay, 410, 'community_content_deleted')
        self.comment(post['id'], self.b)
        # Official moderation of other users' content also uses the allowlist.
        deleted = self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.official))
        self.assertEqual(deleted.json(), {'deleted': True})
        self.assert_error(self.client.get(f'{_PREFIX}/posts/{post["id"]}'), 404, 'community_post_not_found')
        replay = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a),
                                  json=self.post_body(requestId='post-to-delete'))
        self.assert_error(replay, 410, 'community_content_deleted')
        with self.app.state.accounts.connection() as db:
            for table in ('community_likes', 'community_comments', 'community_participants'):
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table} WHERE post_id=?', (post['id'],)).fetchone()[0], 0)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_comment_request_ids_cannot_be_reused_for_a_different_post_or_operation(self):
        first = self.publish(requestId='publish-key')
        second = self.publish()
        self.comment(first['id'], requestId='shared-comment')
        for pid, body in (
            (second['id'], {'requestId': 'shared-comment', 'content': '记录真实进展。'}),
            (first['id'], {'requestId': 'shared-comment', 'content': '更改过的评论'}),
            (first['id'], {'requestId': 'publish-key', 'content': '记录真实进展。'}),
        ):
            response = self.client.post(f'{_PREFIX}/posts/{pid}/comments', headers=self.headers(self.a), json=body)
            self.assert_error(response, 409, 'idempotency_conflict')
        self.assertEqual(self.detail(first['id'])['post']['commentCount'], 1)
        self.assertEqual(self.detail(second['id'])['post']['commentCount'], 0)

    def test_feed_keyset_pagination_handles_equal_timestamps_new_posts_and_deletion(self):
        with patch('community_store.time.time_ns', return_value=1_800_000_000_000_000_000):
            posts = [self.publish(content=f'第 {index} 条') for index in range(6)]
        original = {post['id'] for post in self.store.list_posts()['posts']}
        first = self.client.get(_PREFIX + '/posts', params={'limit': 2}).json()
        self.assertEqual([post['id'] for post in first['posts']], [posts[5]['id'], posts[4]['id']])
        newer = self.publish(content='翻页时刚发布')
        removed = posts[2]['id']
        self.client.delete(f'{_PREFIX}/posts/{removed}', headers=self.headers(self.a))
        seen = [post['id'] for post in first['posts']]
        cursor = first['nextCursor']
        while cursor:
            result = self.client.get(_PREFIX + '/posts', params={'limit': 2, 'cursor': cursor})
            self.assertEqual(result.status_code, 200, result.text)
            value = result.json()
            seen.extend(post['id'] for post in value['posts'])
            cursor = value['nextCursor']
        self.assertEqual(len(seen), len(set(seen)))
        self.assertEqual(set(seen), original - {removed})
        self.assertNotIn(newer['id'], seen)
        official = self.client.get(_PREFIX + '/posts', params={'filter': 'official', 'limit': 1}).json()
        self.assertTrue(all(post['isOfficial'] for post in official['posts']))
        wrong_scope = self.client.get(_PREFIX + '/posts', params={'cursor': official['nextCursor']})
        self.assert_error(wrong_scope, 400)

    def test_comments_are_bounded_and_page_by_stable_sequence_with_total_count(self):
        post = self.publish()
        uid, token = self.a['user']['id'], self.a['token']
        ids = []
        with patch('community_store.time.time_ns', return_value=1_800_000_000_000_000_000):
            for index in range(107):
                result = self.store.create_comment(post['id'], uid, token, {'requestId': f'page-{index}', 'content': f'第 {index} 条评论'})
                ids.append(result['comment']['id'])
        first = self.detail(post['id'])
        self.assertEqual(first['post']['commentCount'], 107)
        self.assertEqual(len(first['comments']), 50)
        second = self.detail(post['id'], commentCursor=first['commentsNextCursor'], commentLimit=100)
        self.assertEqual([comment['id'] for comment in first['comments'] + second['comments']], ids)
        self.assertIsNone(second['commentsNextCursor'])
        maximum = self.detail(post['id'], commentLimit=100)
        self.assertEqual(len(maximum['comments']), 100)
        self.assertIsNotNone(maximum['commentsNextCursor'])
        other = self.publish()
        wrong_post = self.client.get(f'{_PREFIX}/posts/{other["id"]}', params={'commentCursor': first['commentsNextCursor']})
        self.assert_error(wrong_post, 400)
        too_many = self.client.get(f'{_PREFIX}/posts/{post["id"]}', params={'commentLimit': 101})
        self.assert_error(too_many, 400)

    def test_parallel_retries_have_one_post_one_comment_and_one_membership_per_account(self):
        uid, token = self.a['user']['id'], self.a['token']
        body = self.post_body(requestId='parallel-post')
        with ThreadPoolExecutor(max_workers=8) as workers:
            outcomes = list(workers.map(lambda _: self.store.create_post(uid, token, body), range(8)))
        post_id = outcomes[0]['post']['id']
        self.assertEqual({value['post']['id'] for value in outcomes}, {post_id})
        comment = {'requestId': 'parallel-comment', 'content': '只创建一条'}
        with ThreadPoolExecutor(max_workers=8) as workers:
            outcomes = list(workers.map(lambda _: self.store.create_comment(post_id, uid, token, comment), range(8)))
        self.assertEqual(len({value['comment']['id'] for value in outcomes}), 1)
        activity = next(post for post in self.store.list_posts()['posts'] if post['kind'] == 'activity')
        def interact(index):
            session = self.a if index % 2 == 0 else self.b
            self.store.set_like(activity['id'], session['user']['id'], session['token'], {'liked': True})
            self.store.set_join(activity['id'], session['user']['id'], session['token'], {'joined': True})
        with ThreadPoolExecutor(max_workers=8) as workers:
            list(workers.map(interact, range(16)))
        result = self.detail(activity['id'])['post']
        self.assertEqual((result['likeCount'], result['participantCount']), (2, 2))
        self.assertEqual(self.detail(post_id)['post']['commentCount'], 1)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests WHERE user_id=?', (uid,)).fetchone()[0], 2)

    def test_failed_idempotency_claim_rolls_back_content_and_can_retry_after_recovery(self):
        uid, token = self.a['user']['id'], self.a['token']
        body = self.post_body(requestId='atomic-retry')
        with self.app.state.accounts.connection() as db:
            db.execute('''CREATE TRIGGER isolated_claim_failure BEFORE INSERT ON community_requests
                WHEN NEW.request_id='atomic-retry' BEGIN SELECT RAISE(ABORT,'isolated disk failure'); END''')
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.create_post(uid, token, body)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_posts WHERE author_id=?', (uid,)).fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests WHERE user_id=?', (uid,)).fetchone()[0], 0)
            db.execute('DROP TRIGGER isolated_claim_failure')
        result = self.store.create_post(uid, token, body)
        replay = self.store.create_post(uid, token, body)
        self.assertEqual(result['post']['id'], replay['post']['id'])

    def test_input_validation_rejects_overlong_invalid_and_privilege_fields_without_partial_writes(self):
        invalid_posts = [
            {'requestId': ''}, {'requestId': 'x' * 129}, {'requestId': 'key with spaces'},
            {'content': ''}, {'content': '  \n\t '}, {'content': 'x' * 5001}, {'content': '\ud800'},
            {'title': 'x' * 121}, {'title': 'two\nlines'}, {'content': 'bad\x00text'},
            {'official': 'true'}, {'official': 1}, {'kind': 'announcement'}, {'kind': []},
            {'startsAt': '2026-11-10T10:00:00Z'}, {'place': '不属于日常帖'}, {'authorId': 'forged'},
            {'kind': 'activity', 'official': True, 'title': '活动'},
            {'kind': 'activity', 'official': True, 'title': '', 'startsAt': '2026-11-10T10:00:00Z'},
            {'kind': 'activity', 'official': True, 'title': '活动', 'startsAt': '2026-11-10T10:00:00'},
            {'kind': 'activity', 'official': True, 'title': '活动', 'startsAt': 'invalid'},
            {'kind': 'activity', 'official': True, 'title': '活动', 'startsAt': '2026-11-10T10:00:00Z', 'place': 'x' * 121},
        ]
        for changes in invalid_posts:
            with self.subTest(fields=list(changes)):
                encoded = json.dumps(self.post_body(**changes), ensure_ascii=True)
                response = self.client.post(_PREFIX + '/posts', headers={**self.headers(self.official), 'Content-Type': 'application/json'}, content=encoded)
                self.assert_error(response, 400)
        self.assertEqual(len(self.store.list_posts()['posts']), 2)
        post = self.publish()
        for content in ('', 'x' * 1001, None, 42):
            response = self.client.post(f'{_PREFIX}/posts/{post["id"]}/comments', headers=self.headers(self.a),
                                        json={'requestId': self.next_request(), 'content': content})
            self.assert_error(response, 400)
        for name, field in (('like', 'liked'), ('join', 'joined')):
            for value in (1, 'true', None):
                response = self.client.put(f'{_PREFIX}/posts/{post["id"]}/{name}', headers=self.headers(self.a), json={field: value})
                self.assert_error(response, 400)
        for params in ({'limit': 0}, {'limit': 101}, {'limit': -1}, {'limit': 'true'}, {'filter': 'unknown'},
                       {'cursor': 'not-valid-json'}, {'cursor': '=' * 16}, {'cursor': 'x' * 513}):
            self.assert_error(self.client.get(_PREFIX + '/posts', params=params), 400)
        self.assertEqual(self.detail(post['id'])['post']['commentCount'], 0)
        too_large = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(content='x' * 66000))
        self.assert_error(too_large, 413, 'community_request_too_large')
        bad_type = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), content='plain text')
        self.assert_error(bad_type, 415, 'invalid_content_type')

    def test_cookie_writes_keep_csrf_origin_and_account_change_guards(self):
        login = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
                                  json={'identifier': 'reader-a', 'password': _PASSWORD})
        self.assertEqual(login.status_code, 200, login.text)
        csrf = login.json()['csrfToken']
        body = self.post_body(requestId='cookie-write')
        self.assert_error(self.client.post(_PREFIX + '/posts', json=body), 403, 'csrf_required')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers={'X-CSRF-Token': 'bad'}, json=body), 401, 'account_changed')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers={'X-CSRF-Token': csrf, 'Origin': 'https://evil.example.test'}, json=body), 403, 'origin_forbidden')
        accepted = self.client.post(_PREFIX + '/posts', headers={'X-CSRF-Token': csrf}, json=body)
        self.assertEqual(accepted.status_code, 201, accepted.text)
        self.assertEqual(accepted.json()['post']['authorId'], self.a['user']['id'])
        login_b = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
                                    json={'identifier': 'reader-b', 'password': _PASSWORD})
        self.assertEqual(login_b.status_code, 200, login_b.text)
        self.assert_error(self.client.get(_PREFIX + '/posts', headers={'X-CSRF-Token': csrf}), 401, 'account_changed')
        self.assert_error(self.client.post(_PREFIX + '/posts', headers={'X-CSRF-Token': csrf}, json=self.post_body()), 401, 'account_changed')
        current = self.client.get(_PREFIX + '/posts', headers={'X-CSRF-Token': login_b.json()['csrfToken']}).json()
        self.assertTrue(current['viewer']['signedIn'])
        self.assertFalse(next(post for post in current['posts'] if post['id'] == accepted.json()['post']['id'])['canDelete'])

    def test_public_authors_never_include_account_email_phone_or_tokens(self):
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE users SET username=?,phone=? WHERE id=?', ('13800001234', '+8613800001234', self.b['user']['id']))
        post = self.publish(self.b)
        self.comment(post['id'], self.a)
        value = self.detail(post['id'])
        self.assertEqual(value['post']['authorName'], '社区用户')
        encoded = json.dumps(value)
        for private in (self.a['user']['email'], self.b['user']['email'], '13800001234', self.a['token'], self.b['token']):
            self.assertNotIn(private, encoded)
        for entity in [value['post'], *value['comments']]:
            self.assertFalse({'email', 'phone', 'token', 'password'}.intersection(entity))

    def test_account_removal_cascades_content_and_interactions_but_keeps_other_accounts(self):
        a_post = self.publish(self.a)
        b_post = self.publish(self.b)
        self.comment(a_post['id'], self.b)
        self.comment(b_post['id'], self.a)
        self.membership(b_post['id'], self.a, 'like', True)
        activity = next(post for post in self.store.list_posts()['posts'] if post['kind'] == 'activity')
        self.membership(activity['id'], self.a, 'join', True)
        self.membership(activity['id'], self.b, 'join', True)
        self.app.state.accounts.delete_account(self.a['token'], _PASSWORD)
        self.assert_error(self.client.get(f'{_PREFIX}/posts/{a_post["id"]}'), 404)
        remaining = self.detail(b_post['id'], self.b)['post']
        self.assertEqual((remaining['commentCount'], remaining['likeCount']), (0, 0))
        self.assertEqual(self.detail(activity['id'])['post']['participantCount'], 1)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_requests WHERE user_id=?', (self.a['user']['id'],)).fetchone()[0], 0)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
        self.assert_error(self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body()), 401, 'session_expired')

    def test_store_rechecks_session_under_the_write_transaction(self):
        with self.assertRaises(AuthError) as mismatch:
            self.store.create_post(self.b['user']['id'], self.a['token'], self.post_body())
        self.assertEqual(mismatch.exception.status, 401)
        self.app.state.accounts.logout(self.a['token'])
        with self.assertRaises(AuthError) as revoked:
            self.store.create_post(self.a['user']['id'], self.a['token'], self.post_body())
        self.assertEqual(revoked.exception.code, 'session_expired')
        self.assertEqual(len(self.store.list_posts()['posts']), 2)

    def grant(self, session, **permissions):
        response = self.client.put(f'{_PREFIX}/admins/{session["user"]["id"]}',
                                    headers=self.headers(self.official), json={'permissions': _permissions(**permissions)})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json(), {'updated': True})

    def apply(self, session=None, **changes):
        response = self.client.post(_PREFIX + '/admin-applications', headers=self.headers(session or self.a),
                                    json={'requestId': self.next_request(), 'reason': '希望帮大家整理社区讨论。', **changes})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()['application']

    def management(self, session):
        response = self.client.get(_PREFIX + '/management', headers=self.headers(session))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        return response.json()

    def test_owner_adds_by_exact_identity_updates_every_permission_and_revokes_immediately(self):
        owner = self.management(self.official)['viewer']
        self.assertTrue(owner['isOfficial'])
        self.assertTrue(owner['canManageAdmins'])
        self.assertTrue(all(owner['permissions'].values()))
        self.assertEqual(self.management(self.a)['admins'], [])
        self.assertEqual(self.management(self.a)['applications'], [])
        for identity in ('reader-a', self.a['user']['email']):
            added = self.client.post(_PREFIX + '/admins', headers=self.headers(self.official),
                                     json={'identifier': identity, 'permissions': _permissions(publishOfficial=True)})
            self.assertEqual(added.status_code, 200, added.text)
        admins = self.management(self.official)['admins']
        self.assertEqual(len(admins), 1)
        self.assertEqual(admins[0]['userId'], self.a['user']['id'])
        self.assertEqual(admins[0]['username'], 'reader-a')
        self.assertEqual(admins[0]['permissions'], _permissions(publishOfficial=True))
        for key in _permissions():
            self.grant(self.a, **{key: True})
            viewer = self.management(self.a)['viewer']
            self.assertTrue(viewer['isAdmin'])
            self.assertFalse(viewer['isOfficial'])
            self.assertFalse(viewer['canManageAdmins'])
            self.assertEqual(viewer['permissions'], _permissions(**{key: True}))
            self.assertEqual(viewer['canPublishOfficial'], key in ('publishOfficial', 'publishActivity'))
        for _ in range(2):
            removed = self.client.delete(f'{_PREFIX}/admins/{self.a["user"]["id"]}', headers=self.headers(self.official))
            self.assertEqual(removed.json(), {'updated': True})
        viewer = self.management(self.a)['viewer']
        self.assertFalse(viewer['isAdmin'])
        self.assertEqual(viewer['permissions'], _permissions())
        self.assertEqual(self.management(self.official)['admins'], [])
        no_match = self.client.post(_PREFIX + '/admins', headers=self.headers(self.official),
                                    json={'identifier': 'reader-', 'permissions': _permissions()})
        self.assert_error(no_match, 404, 'community_user_not_found')

    def test_delegated_publication_permissions_are_independent_and_badges_follow_real_identity(self):
        self.grant(self.a, publishOfficial=True)
        official_post = self.publish(self.a, official=True)
        self.assertTrue(official_post['isOfficial'])
        self.assertTrue(official_post['isAdmin'])
        personal = self.publish(self.a)
        self.assertFalse(personal['isOfficial'])
        self.assertTrue(personal['isAdmin'])
        self.assertEqual(personal['authorName'], 'reader-a')
        comment = self.comment(personal['id'], self.a)['comment']
        self.assertTrue(comment['isAdmin'])
        self.assertFalse(comment['isOfficial'])
        denied = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(
            kind='activity', official=True, title='专注活动', startsAt='2026-11-10T10:00:00Z'))
        self.assert_error(denied, 403, 'community_official_required')
        self.grant(self.b, publishActivity=True)
        activity = self.publish(self.b, kind='activity', official=True, title='专注活动', startsAt='2026-11-10T10:00:00Z')
        self.assertTrue(activity['isOfficial'])
        self.assertTrue(activity['isAdmin'])
        self.assertFalse(self.management(self.b)['viewer']['permissions']['publishOfficial'])
        denied = self.client.post(_PREFIX + '/posts', headers=self.headers(self.b), json=self.post_body(official=True))
        self.assert_error(denied, 403, 'community_official_required')
        self.client.delete(f'{_PREFIX}/admins/{self.a["user"]["id"]}', headers=self.headers(self.official))
        denied = self.client.post(_PREFIX + '/posts', headers=self.headers(self.a), json=self.post_body(official=True))
        self.assert_error(denied, 403, 'community_official_required')
        # Historical official content stays official; the current role badge is
        # not a stale permission cache on existing posts or comments.
        self.assertTrue(self.detail(official_post['id'])['post']['isOfficial'])
        self.assertFalse(self.detail(personal['id'])['post']['isAdmin'])
        self.assertFalse(self.detail(personal['id'])['comments'][0]['isAdmin'])

    def test_post_and_comment_moderation_permissions_are_independent_and_enforced_on_delete(self):
        self.grant(self.a, moderatePosts=True)
        self.grant(self.b, moderateComments=True)
        post = self.publish(self.official)
        comment = self.comment(post['id'], self.official)['comment']
        a_view = self.detail(post['id'], self.a)
        b_view = self.detail(post['id'], self.b)
        self.assertTrue(a_view['post']['canDelete'])
        self.assertFalse(a_view['comments'][0]['canDelete'])
        self.assertFalse(b_view['post']['canDelete'])
        self.assertTrue(b_view['comments'][0]['canDelete'])
        self.assert_error(self.client.delete(f'{_PREFIX}/comments/{comment["id"]}', headers=self.headers(self.a)),
                          403, 'community_delete_forbidden')
        self.assert_error(self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.b)),
                          403, 'community_delete_forbidden')
        self.assertEqual(self.client.delete(f'{_PREFIX}/comments/{comment["id"]}', headers=self.headers(self.b)).json(), {'deleted': True})
        self.grant(self.a)
        self.assertFalse(self.detail(post['id'], self.a)['post']['canDelete'])
        self.assert_error(self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.a)), 403)
        self.grant(self.a, moderatePosts=True)
        self.assertEqual(self.client.delete(f'{_PREFIX}/posts/{post["id"]}', headers=self.headers(self.a)).json(), {'deleted': True})

    def test_applications_are_idempotent_only_one_pending_and_private_to_the_applicant_and_owner(self):
        first = self.apply(requestId='application-a')
        replay = self.apply(requestId='application-a')
        pending_again = self.apply(requestId='application-a-again', reason='补充一段不同说明')
        self.assertEqual(first['id'], replay['id'])
        self.assertEqual(first['id'], pending_again['id'])
        self.assertEqual(first['reason'], pending_again['reason'])
        other = self.apply(self.b)
        a_management = self.management(self.a)
        self.assertEqual(a_management['applications'], [])
        self.assertEqual(a_management['admins'], [])
        self.assertEqual(a_management['myApplication'], first)
        self.assertNotIn(other['id'], json.dumps(a_management))
        owner = self.management(self.official)
        self.assertEqual({item['id'] for item in owner['applications']}, {first['id'], other['id']})
        self.assertIsNone(owner['myApplication'])
        self.assertNotIn(self.a['user']['email'], json.dumps(owner))
        changed = self.client.post(_PREFIX + '/admin-applications', headers=self.headers(self.a),
                                   json={'requestId': 'application-a', 'reason': '修改过的原申请'})
        self.assert_error(changed, 409, 'idempotency_conflict')
        self.assert_error(self.client.get(_PREFIX + '/management'), 401)

    def test_only_owner_approves_and_an_approval_retry_never_restores_later_revoked_permissions(self):
        application = self.apply()
        permissions = _permissions(publishActivity=True, moderateComments=True)
        review = {'status': 'approved', 'permissions': permissions}
        path = f'{_PREFIX}/admin-applications/{application["id"]}'
        self.assert_error(self.client.put(path, headers=self.headers(self.a), json=review), 403, 'community_owner_required')
        response = self.client.put(path, headers=self.headers(self.official), json=review)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['application']['status'], 'approved')
        self.assertEqual(self.management(self.a)['viewer']['permissions'], permissions)
        self.assertEqual(self.management(self.a)['myApplication']['status'], 'approved')
        changed = self.client.put(path, headers=self.headers(self.official), json={'status': 'approved', 'permissions': _permissions()})
        self.assert_error(changed, 409, 'community_application_reviewed')
        rejected_after = self.client.put(path, headers=self.headers(self.official), json={'status': 'rejected'})
        self.assert_error(rejected_after, 409, 'community_application_reviewed')
        self.client.delete(f'{_PREFIX}/admins/{self.a["user"]["id"]}', headers=self.headers(self.official))
        retry = self.client.put(path, headers=self.headers(self.official), json=review)
        self.assertEqual(retry.status_code, 200, retry.text)
        self.assertFalse(self.management(self.a)['viewer']['isAdmin'])
        self.assertEqual(self.management(self.a)['viewer']['permissions'], _permissions())
        self.assertNotEqual(self.apply()['id'], application['id'])

    def test_admins_cannot_escalate_manage_others_or_remove_the_official_owner(self):
        self.grant(self.a, **{key: True for key in _permissions()})
        application = self.apply(self.b)
        permission_body = {'permissions': _permissions(**{key: True for key in _permissions()})}
        attempts = [
            ('POST', '/admins', {'identifier': 'reader-b', **permission_body}),
            ('PUT', f'/admins/{self.a["user"]["id"]}', permission_body),
            ('DELETE', f'/admins/{self.b["user"]["id"]}', None),
            ('PUT', f'/admin-applications/{application["id"]}', {'status': 'approved', **permission_body}),
        ]
        for method, path, body in attempts:
            denied = self.client.request(method, _PREFIX + path, headers=self.headers(self.a), json=body)
            self.assert_error(denied, 403, 'community_owner_required')
        # Even the official owner's own authenticated API cannot remove the
        # server allowlist capability or turn it into an editable admin row.
        for method, path, body in (
            ('POST', '/admins', {'identifier': self.official['user']['email'], 'permissions': _permissions()}),
            ('PUT', f'/admins/{self.official["user"]["id"]}', {'permissions': _permissions()}),
            ('DELETE', f'/admins/{self.official["user"]["id"]}', None),
        ):
            denied = self.client.request(method, _PREFIX + path, headers=self.headers(self.official), json=body)
            self.assert_error(denied, 403, 'community_owner_protected')
        self.assertTrue(self.management(self.official)['viewer']['canManageAdmins'])
        self.assertFalse(self.management(self.b)['viewer']['isAdmin'])

    def test_rejection_allows_a_new_application_and_direct_appointment_resolves_pending_application(self):
        first = self.apply()
        path = f'{_PREFIX}/admin-applications/{first["id"]}'
        for _ in range(2):
            response = self.client.put(path, headers=self.headers(self.official), json={'status': 'rejected'})
            self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(self.management(self.a)['viewer']['isAdmin'])
        second = self.apply(reason='补充参与经验后重新申请。')
        self.assertNotEqual(first['id'], second['id'])
        self.grant(self.a, moderateComments=True)
        self.assertEqual(self.management(self.a)['myApplication']['status'], 'approved')
        self.assertEqual(len(self.management(self.official)['applications']), 2)
        for session in (self.a, self.official):
            denied = self.client.post(_PREFIX + '/admin-applications', headers=self.headers(session),
                                      json={'requestId': self.next_request(), 'reason': '不应重复申请'})
            self.assert_error(denied, 409, 'community_already_admin')

    def test_concurrent_applications_and_reviews_produce_one_pending_and_one_decision(self):
        uid, token = self.a['user']['id'], self.a['token']
        def apply(index):
            return self.store.apply_admin(uid, token, {'requestId': f'application-parallel-{index}', 'reason': '参与管理'})
        with ThreadPoolExecutor(max_workers=8) as workers:
            results = list(workers.map(apply, range(8)))
        self.assertEqual(len({result['application']['id'] for result in results}), 1)
        application_id = results[0]['application']['id']
        def review(status):
            body = {'status': status}
            if status == 'approved':
                body['permissions'] = _permissions(moderatePosts=True)
            try:
                return self.store.review_application(application_id, self.official['user']['id'], self.official['token'], body)['application']['status']
            except AuthError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as workers:
            decisions = list(workers.map(review, ['approved', 'rejected']))
        self.assertEqual(decisions.count('community_application_reviewed'), 1)
        actual = self.management(self.a)
        self.assertEqual(actual['viewer']['isAdmin'], actual['myApplication']['status'] == 'approved')
        self.assertEqual(len(self.management(self.official)['applications']), 1)

    def test_failed_approval_is_atomic_and_deleted_applicants_and_admins_are_cleaned_up(self):
        application = self.apply()
        with self.app.state.accounts.connection() as db:
            db.execute('''CREATE TRIGGER isolated_grant_failure BEFORE INSERT ON community_admins
                BEGIN SELECT RAISE(ABORT,'isolated storage failure'); END''')
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.review_application(application['id'], self.official['user']['id'], self.official['token'],
                                          {'status': 'approved', 'permissions': _permissions(moderatePosts=True)})
        self.assertEqual(self.management(self.a)['myApplication']['status'], 'pending')
        self.assertFalse(self.management(self.a)['viewer']['isAdmin'])
        with self.app.state.accounts.connection() as db:
            db.execute('DROP TRIGGER isolated_grant_failure')
        self.grant(self.a, moderatePosts=True)
        self.apply(self.b)
        self.app.state.accounts.delete_account(self.a['token'], _PASSWORD)
        self.app.state.accounts.delete_account(self.b['token'], _PASSWORD)
        management = self.management(self.official)
        self.assertEqual(management['admins'], [])
        self.assertEqual(management['applications'], [])
        missing = self.client.put(f'{_PREFIX}/admin-applications/{application["id"]}', headers=self.headers(self.official),
                                  json={'status': 'approved', 'permissions': _permissions()})
        self.assert_error(missing, 404, 'community_application_not_found')
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_management_inputs_do_not_default_missing_permissions_or_expose_user_lookup_to_regular_accounts(self):
        invalid = [None, {}, {'publishOfficial': True}, {**_permissions(), 'publishActivity': 1},
                   {**_permissions(), 'moderateComments': 'false'}, {**_permissions(), 'canManageAdmins': True}]
        for permissions in invalid:
            response = self.client.put(f'{_PREFIX}/admins/{self.a["user"]["id"]}', headers=self.headers(self.official),
                                        json={'permissions': permissions})
            self.assert_error(response, 400)
        for reason in ('', '  ', 'x' * 501, 7):
            response = self.client.post(_PREFIX + '/admin-applications', headers=self.headers(self.a),
                                        json={'requestId': self.next_request(), 'reason': reason})
            self.assert_error(response, 400)
        for identifier in ('reader-b', 'nonexistent@example.test'):
            response = self.client.post(_PREFIX + '/admins', headers=self.headers(self.a),
                                        json={'identifier': identifier, 'permissions': _permissions()})
            self.assert_error(response, 403, 'community_owner_required')
        application = self.apply()
        for body in ({'status': 'approved'}, {'status': 'pending'}, {'status': 'rejected', 'permissions': _permissions()}):
            response = self.client.put(f'{_PREFIX}/admin-applications/{application["id"]}', headers=self.headers(self.official), json=body)
            self.assert_error(response, 400)
        self.assertEqual(self.management(self.a)['myApplication']['status'], 'pending')
        self.assertEqual(self.management(self.official)['admins'], [])


if __name__ == '__main__':
    unittest.main()
