"""Community documentation contracts: temporary SQLite, no HTTP or live services."""
from collections import Counter
from io import BytesIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastapi import FastAPI
from PIL import Image

from api_contract import install_contract
from auth_store import AuthError, AuthStore
from community_api import attach_community


PREFIX = '/api/v1/community'
PERMISSIONS = {'publishOfficial': False, 'publishActivity': True,
               'moderatePosts': False, 'moderateComments': True}


class CommunityOpenApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.accounts = AuthStore(Path(cls.temp.name) / 'contract.sqlite3')
        cls.owner, cls.reader = [cls.accounts.register({
            'username': name, 'email': name + '@example.test',
            'password': 'ContractOnlyPassword123',
        }) for name in ('contract-owner', 'contract-reader')]
        cls.app = FastAPI()
        cls.app.state.accounts = cls.accounts
        with patch.dict('os.environ', {'SERA_COMMUNITY_OFFICIAL_USER_IDS': cls.owner['user']['id']}):
            attach_community(cls.app)
        cls.registered = cls.community_routes()

        async def compatibility(*_):
            raise AssertionError('OpenAPI generation must not invoke compatibility endpoints')

        install_contract(cls.app, compatibility)
        cls.document = cls.app.openapi()
        cls.schemas = cls.document['components']['schemas']
        cls.store = cls.app.state.community
        uid, token = cls.reader['user']['id'], cls.reader['token']
        cls.post = cls.store.create_post(uid, token, {
            'requestId': 'contract-post', 'content': 'Temporary contract post',
        })['post']
        cls.comment_result = cls.store.create_comment(cls.post['id'], uid, token, {
            'requestId': 'contract-comment', 'content': 'Temporary contract comment',
        })
        cls.application_result = cls.store.apply_admin(uid, token, {
            'requestId': 'contract-application', 'reason': 'Help maintain the community',
        })

    @classmethod
    def community_routes(cls):
        return Counter((route.path, method.lower())
                       for route in cls.app.routes if route.path.startswith(PREFIX)
                       for method in getattr(route, 'methods', []))

    def operation(self, suffix, method='get'):
        return self.document['paths'][PREFIX + suffix][method]

    def assert_response_fields(self, name, actual):
        """Every emitted field is documented and every promised field exists."""
        schema = self.schemas[name]
        self.assertEqual(set(actual), set(schema['properties']), name)
        self.assertEqual(set(actual), set(schema['required']), name)

    def test_all_explicit_operations_are_documented_without_registering_forwarders(self):
        self.assertEqual(self.community_routes(), self.registered)
        self.assertEqual(len(self.registered), 16)
        self.assertTrue(all(count == 1 for count in self.registered.values()))
        expected = {
            ('/media', 'post'): (201, 'CommunityMediaResult'),
            ('/posts', 'get'): (200, 'CommunityFeed'),
            ('/posts/{post_id}', 'get'): (200, 'CommunityDetail'),
            ('/posts', 'post'): (201, 'CommunityPostResult'),
            ('/posts/{post_id}/comments', 'post'): (201, 'CommunityCommentResult'),
            ('/posts/{post_id}/like', 'put'): (200, 'CommunityPostResult'),
            ('/posts/{post_id}/join', 'put'): (200, 'CommunityPostResult'),
            ('/posts/{post_id}', 'delete'): (200, 'CommunityDeleted'),
            ('/comments/{comment_id}', 'delete'): (200, 'CommunityDeleted'),
            ('/management', 'get'): (200, 'CommunityManagement'),
            ('/admin-applications', 'post'): (201, 'CommunityApplicationResult'),
            ('/admins', 'post'): (200, 'CommunityUpdated'),
            ('/admins/{user_id}', 'put'): (200, 'CommunityUpdated'),
            ('/admins/{user_id}', 'delete'): (200, 'CommunityUpdated'),
            ('/admin-applications/{application_id}', 'put'): (200, 'CommunityApplicationResult'),
        }
        for (suffix, method), (status, result) in expected.items():
            with self.subTest(path=suffix, method=method):
                response = self.operation(suffix, method)['responses'][str(status)]
                self.assertEqual(response['content']['application/json']['schema']['$ref'],
                                 '#/components/schemas/' + result)
                self.assertEqual(response['headers']['Cache-Control']['schema']['const'], 'no-store')
        self.assertIs(self.app.openapi(), self.document)

    def test_anonymous_reads_and_authenticated_writes_preserve_cookie_binding_requirements(self):
        schemes = self.document['components']['securitySchemes']
        self.assertEqual(schemes['BearerAuth']['scheme'], 'bearer')
        self.assertEqual((schemes['CookieAuth']['in'], schemes['CookieAuth']['name']), ('cookie', 'sera_session'))
        public = {(PREFIX + '/posts', 'get'), (PREFIX + '/posts/{post_id}', 'get'),
                  (PREFIX + '/media/{media_id}', 'get')}
        for path, method in self.registered:
            operation = self.document['paths'][path][method]
            expected = ([{}] if (path, method) in public else []) + [{'BearerAuth': []}, {'CookieAuth': []}]
            self.assertEqual(operation['security'], expected)
            header = next(item for item in operation['parameters'] if item['name'] == 'X-CSRF-Token')
            self.assertFalse(header['required'])  # Bearer requests need no CSRF header.
            self.assertIn('Required on cookie-authenticated mutations', header['description'])
            self.assertIn('401', operation['responses'])  # Invalid supplied credentials never become a guest.
        # Existing endpoint contract semantics remain untouched.
        self.assertEqual(self.document['paths']['/api/v1/auth/login']['post']['security'], [])
        self.assertEqual(self.document['paths']['/api/v1/workspace']['get']['security'],
                         [{'BearerAuth': []}, {'CookieAuth': []}])

    def test_both_pagination_contracts_match_actual_limits_scopes_and_cursor_fields(self):
        posts = {p['name']: p for p in self.operation('/posts')['parameters'] if p['in'] == 'query'}
        comments = {p['name']: p for p in self.operation('/posts/{post_id}')['parameters'] if p['in'] == 'query'}
        self.assertEqual(set(posts), {'filter', 'cursor', 'limit'})
        self.assertEqual(set(comments), {'commentCursor', 'commentLimit'})
        self.assertEqual(posts['filter']['schema']['enum'], ['all', 'official', 'feedback'])
        self.assertEqual(posts['limit']['schema'], {'type': 'integer', 'minimum': 1, 'maximum': 100, 'default': 20})
        self.assertEqual(comments['commentLimit']['schema']['default'], 50)
        self.assertEqual(comments['commentLimit']['schema']['maximum'], 100)
        first = self.store.list_posts(limit=1)
        second = self.store.list_posts(cursor=first['nextCursor'], limit=1)
        self.assertNotEqual(first['posts'][0]['id'], second['posts'][0]['id'])
        self.assert_response_fields('CommunityFeed', first)
        with self.assertRaises(AuthError) as wrong_scope:
            self.store.detail(self.post['id'], comment_cursor=first['nextCursor'])
        self.assertEqual(wrong_scope.exception.status, 400)
        with self.assertRaises(AuthError) as too_large:
            self.store.list_posts(limit=101)
        self.assertEqual(too_large.exception.status, 400)

    def test_real_store_payloads_cover_viewer_badges_counts_and_private_management(self):
        uid, token = self.reader['user']['id'], self.reader['token']
        detail = self.store.detail(self.post['id'], uid)
        self.assert_response_fields('CommunityDetail', detail)
        self.assert_response_fields('CommunityPost', detail['post'])
        self.assert_response_fields('CommunityComment', detail['comments'][0])
        self.assert_response_fields('CommunityViewer', detail['viewer'])
        self.assert_response_fields('CommunityPermissions', detail['viewer']['permissions'])
        self.assert_response_fields('CommunityCommentResult', self.comment_result)
        self.assert_response_fields('CommunityApplicationResult', self.application_result)
        self.assert_response_fields('CommunityApplication', self.application_result['application'])
        own = self.store.management(uid, token)
        self.assert_response_fields('CommunityManagement', own)
        self.assertEqual((own['admins'], own['applications']), ([], []))
        self.assertEqual(own['myApplication']['userId'], uid)
        owner = self.store.management(self.owner['user']['id'], self.owner['token'])
        self.assertTrue(owner['viewer']['canManageAdmins'])
        self.assertIn(uid, [a['userId'] for a in owner['applications']])
        self.assertEqual(self.schemas['CommunityPost']['properties']['authorId']['type'], ['string', 'null'])
        self.assertEqual(detail['post']['commentCount'], 1)
        self.assertIn('isAdmin', self.schemas['CommunityComment']['required'])
        self.assertEqual(detail['post']['category'], 'daily')
        self.assertEqual(detail['post']['media'], [])
        self.assertFalse(detail['post']['authorIsOfficial'])
        self.assertFalse(detail['comments'][0]['authorIsOfficial'])
        for name in ('CommunityPost', 'CommunityComment'):
            self.assertIn('authorIsOfficial', self.schemas[name]['required'])

    def test_feedback_category_and_author_identity_match_store_validation(self):
        uid, token = self.owner['user']['id'], self.owner['token']
        body = {'requestId': 'contract-feedback', 'content': 'Feedback from the official owner',
                'category': 'feedback'}
        post = self.store.create_post(uid, token, body)['post']
        self.assert_response_fields('CommunityPost', post)
        self.assertFalse(post['isOfficial'])  # Personal content does not change the author's identity.
        self.assertTrue(post['authorIsOfficial'])
        self.assertEqual(post['category'], 'feedback')
        feed = self.store.list_posts(filter='feedback')
        self.assertIn(post['id'], [p['id'] for p in feed['posts']])
        self.assertNotIn(self.post['id'], [p['id'] for p in feed['posts']])
        self.assertTrue(all(p['kind'] == 'post' and p['category'] == 'feedback' for p in feed['posts']))
        self.assertEqual(self.store.create_post(uid, token, body)['post']['id'], post['id'])
        with self.assertRaises(AuthError) as changed_category:
            self.store.create_post(uid, token, {**body, 'category': 'daily'})
        self.assertEqual(changed_category.exception.status, 409)
        with self.assertRaises(AuthError) as invalid_activity:
            self.store.create_post(uid, token, {
                'requestId': 'contract-invalid-activity-feedback', 'kind': 'activity',
                'category': 'feedback', 'official': True, 'title': 'Activity', 'content': 'Details',
                'startsAt': '2026-11-09T12:00:00Z',
            })
        self.assertEqual(invalid_activity.exception.status, 400)
        category = self.schemas['CommunityCreatePost']['properties']['category']
        self.assertEqual(category, {'type': 'string', 'enum': ['daily', 'feedback'], 'default': 'daily'})
        self.assertEqual(self.schemas['CommunityPost']['properties']['category'], category)
        self.assertEqual(self.schemas['CommunityCreatePost']['allOf'][0]['then']['properties']['category'],
                         {'const': 'daily'})
        self.assertNotIn('authorIsOfficial', self.schemas['CommunityCreatePost']['properties'])

    def test_binary_upload_and_media_contract_match_private_then_published_store_behavior(self):
        upload = self.operation('/media', 'post')
        self.assertEqual(set(upload['requestBody']['content']), {'image/jpeg', 'image/png', 'image/webp'})
        for content in upload['requestBody']['content'].values():
            self.assertEqual(content['schema'], {'type': 'string', 'format': 'binary', 'maxLength': 8 * 1024 * 1024})
        key = next(p for p in upload['parameters'] if p['name'] == 'Idempotency-Key')
        self.assertTrue(key['required'])
        self.assertEqual(key['schema']['$ref'], '#/components/schemas/CommunityIdentifier')
        download = self.operation('/media/{media_id}')['responses']['200']
        self.assertEqual(set(download['content']), {'image/jpeg', 'image/png'})
        self.assertEqual(download['headers']['Cache-Control']['schema']['const'], 'private, no-store')
        media_ids = self.schemas['CommunityCreatePost']['properties']['mediaIds']
        self.assertEqual((media_ids['default'], media_ids['maxItems'], media_ids['uniqueItems']), ([], 3, True))
        self.assertIn('media', self.schemas['CommunityPost']['required'])
        raw = BytesIO()
        with Image.new('RGBA', (24, 12), (10, 20, 30, 40)) as source:
            source.save(raw, 'PNG')
        uid, token = self.reader['user']['id'], self.reader['token']
        response = self.store.upload_media(uid, token, 'contract-media', raw.getvalue(), 'image/png')
        self.assert_response_fields('CommunityMediaResult', response)
        media = response['media']
        self.assert_response_fields('CommunityMedia', media)
        self.assertEqual((media['width'], media['height'], media['mimeType']), (24, 12, 'image/png'))
        pending, mime = self.store.read_media(media['id'], uid, token)
        self.assertEqual((len(pending), mime), (media['bytes'], media['mimeType']))
        with self.assertRaises(AuthError) as private:
            self.store.read_media(media['id'])
        self.assertEqual(private.exception.status, 404)
        post = self.store.create_post(uid, token, {'requestId': 'contract-post-media',
            'content': 'An image with required body text', 'mediaIds': [media['id']]})['post']
        self.assertEqual(post['media'], [media])
        self.assertEqual(self.store.read_media(media['id']), (pending, mime))
        self.assertTrue({'400', '401', '403', '409', '410', '413', '415'}.issubset(upload['responses']))

    def test_requests_describe_strict_permissions_and_kind_dependent_validation(self):
        permissions = self.schemas['CommunityPermissions']
        self.assertEqual(set(permissions['required']), set(PERMISSIONS))
        self.assertFalse(permissions['additionalProperties'])
        self.assertTrue(all(p == {'type': 'boolean'} for p in permissions['properties'].values()))
        post = self.schemas['CommunityCreatePost']
        self.assertEqual(set(post['required']), {'requestId', 'content'})
        self.assertFalse(post['additionalProperties'])
        self.assertEqual(post['properties']['content']['maxLength'], 5000)
        activity = post['allOf'][0]['then']
        self.assertEqual(set(activity['required']), {'title', 'startsAt', 'official'})
        self.assertEqual(activity['properties']['official'], {'const': True})
        self.assertEqual(post['allOf'][0]['else']['properties']['startsAt'], {'type': 'null'})
        review = self.schemas['CommunityReviewApplication']['oneOf']
        self.assertEqual(set(review[0]['required']), {'status', 'permissions'})
        self.assertEqual(review[1]['required'], ['status'])
        self.assertNotIn('permissions', review[1]['properties'])
        for schema in ('CommunityCreatePost', 'CommunityCreateComment', 'CommunityApplyAdmin'):
            self.assertIn('requestId', self.schemas[schema]['required'])
        with self.assertRaises(AuthError) as missing_permission:
            self.store.add_admin(self.owner['user']['id'], self.owner['token'], {
                'identifier': self.reader['user']['username'], 'permissions': {'publishActivity': True},
            })
        self.assertEqual(missing_permission.exception.status, 400)

    def test_errors_and_media_types_are_specific_to_actual_operations(self):
        created = self.operation('/posts', 'post')
        self.assertEqual(set(created['requestBody']['content']), {'application/json'})
        self.assertTrue({'400', '401', '403', '409', '410', '413', '415'}.issubset(created['responses']))
        for suffix, method in [('/posts/{post_id}', 'delete'), ('/comments/{comment_id}', 'delete')]:
            operation = self.operation(suffix, method)
            self.assertNotIn('requestBody', operation)
            self.assertNotIn('404', operation['responses'])  # Missing content deletion is idempotent success.
            self.assertNotIn('415', operation['responses'])
        self.assertIn('404', self.operation('/posts/{post_id}')['responses'])
        self.assertIn('404', self.operation('/admins/{user_id}', 'delete')['responses'])
        self.assertIn('409', self.operation('/admin-applications/{application_id}', 'put')['responses'])
        for path, method in self.registered:
            self.assertNotIn('422', self.document['paths'][path][method]['responses'])
            self.assertNotIn('429', self.document['paths'][path][method]['responses'])
        replay = self.store.create_post(self.reader['user']['id'], self.reader['token'], {
            'requestId': 'deleted-contract-post', 'content': 'Will be removed',
        })['post']
        self.store.delete_post(replay['id'], self.reader['user']['id'], self.reader['token'])
        with self.assertRaises(AuthError) as deleted:
            self.store.create_post(self.reader['user']['id'], self.reader['token'], {
                'requestId': 'deleted-contract-post', 'content': 'Will be removed',
            })
        self.assertEqual(deleted.exception.status, 410)


if __name__ == '__main__':
    unittest.main()
