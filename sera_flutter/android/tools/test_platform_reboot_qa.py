"""Parser tests only: no device mutation or Flutter process."""
import hashlib
import json
import unittest
from run_platform_reboot_qa import active_notification, persisted_reminder


class RebootEvidenceTest(unittest.TestCase):
    def test_only_active_unique_app_notification_counts(self):
        row = '    NotificationRecord(0x1: pkg=com.sera.sera_flutter user=UserHandle{0} id=1 tag=qa:normal:start importance=3)'
        self.assertTrue(active_notification('  Notification List:\n' + row, 'qa:normal:start'))
        self.assertFalse(active_notification('  Notification List:\n' + row, 'qa:reboot:start'))
        self.assertFalse(active_notification('  Enqueued Notification List:\n' + row, 'qa:normal:start'))
        self.assertFalse(active_notification('  Snoozed notifications:\n' + row, 'qa:normal:start'))
        self.assertFalse(active_notification('  Notification List:\n' + row.replace('pkg=com.sera.sera_flutter', 'pkg=other'), 'qa:normal:start'))

    def test_persisted_proof_requires_current_scope_id_fire_and_version(self):
        scope = 'qa-platform-reboot:123'
        hashed = hashlib.sha256(scope.encode()).hexdigest()
        rows = [{'id': 'qa-reboot-entry-123:start', 'fireAt': 123456, 'version': 'abc'}]
        xml = '<map><string name="activeScope">' + hashed + '</string><string name="notifications:' + hashed + '">' + json.dumps(rows) + '</string></map>'
        self.assertTrue(persisted_reminder(xml, scope, rows[0]['id'], 123456))
        self.assertFalse(persisted_reminder(xml, scope, rows[0]['id'], 123457))
        self.assertFalse(persisted_reminder(xml, scope + 'other', rows[0]['id'], 123456))
        self.assertFalse(persisted_reminder(xml, scope, 'other', 123456))
        self.assertFalse(persisted_reminder(xml.replace('"abc"', '""'), scope, rows[0]['id'], 123456))


if __name__ == '__main__':
    unittest.main()
