import copy
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from auth_store import AuthStore
from placement_policy import validate_placement_changes
from server import WorkspaceStore, ValidationError
from sync_store import SyncStore, migrate_workspace
from test_server import empty_workspace


NOW = datetime(2026, 11, 1, tzinfo=timezone.utc)


def workspace():
    value = migrate_workspace(empty_workspace())
    value['tasks'] = [{'id': 'task', 'title': 'Work', 'estimatedMinutes': 60, 'dueAt': '2026-11-02T18:00:00+08:00'}]
    return value


def block(eid='block', start='14:00', end='15:00', tid='task'):
    return {'id': eid, 'taskId': tid, 'title': 'Work', 'start': '2026-11-02T'+start+':00+08:00', 'end': '2026-11-02T'+end+':00+08:00'}


class PlacementPolicyTests(unittest.TestCase):
    def test_new_blocks_respect_model_phase_earliest_start(self):
        candidate = workspace()
        candidate['entries'] = [block()]
        candidate['tasks'][0]['notBefore'] = '2026-11-02T14:15:00+08:00'
        with self.assertRaises(ValidationError):
            validate_placement_changes(None, candidate, now=NOW)
        candidate['tasks'][0]['notBefore'] = '2026-11-02T14:00:00+08:00'
        validate_placement_changes(None, candidate, now=NOW)

    def test_new_blocks_reject_overlap_deadline_workload_and_dependency(self):
        for mutate in (
            lambda value: value['entries'].append({**block('meeting'), 'taskId': None}),
            lambda value: value['externalBusyEntries'].append({**block('external'), 'taskId': None}),
            lambda value: value['tasks'][0].update(dueAt='2026-11-02T14:30:00+08:00'),
            lambda value: value['tasks'][0].update(remainingMinutes=30),
            lambda value: (value['tasks'].append({'id': 'pre', 'title': 'Before'}), value['tasks'][0].update(dependencyIds=['pre'])),
        ):
            candidate = workspace(); candidate['entries'] = [block()]
            mutate(candidate)
            with self.subTest(candidate=candidate), self.assertRaises(ValidationError):
                validate_placement_changes(None, candidate, now=NOW)

    def test_split_minimum_and_dependency_order_are_checked(self):
        value = workspace(); value['entries'] = [block('one','14:00','14:30'), block('two','16:00','16:30')]
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
        value['tasks'][0].update(splittable=True,minBlockMinutes=30)
        validate_placement_changes(None,value,now=NOW)
        value['entries'][0] = block('one','14:00','14:10')
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
        value = workspace(); value['tasks'].append({'id':'pre','title':'Before','estimatedMinutes':30})
        value['tasks'][0]['dependencyIds']=['pre']
        value['entries']=[block(),block('before','15:00','15:30','pre')]
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
        value['entries'][1]=block('before','13:00','13:30','pre')
        validate_placement_changes(None,value,now=NOW)

    def test_fixed_import_preferences_and_history_do_not_invalidate_existing_blocks(self):
        previous = workspace(); previous['entries']=[block()]
        value=copy.deepcopy(previous)
        value['externalBusyEntries']=[{**block('external'),'taskId':None}]
        value['entries'].append({**block('fixed'),'taskId':None})
        value['preferences'].update(startMinute=960,endMinute=1020,dailyBudget=15)
        validate_placement_changes(previous,value,now=NOW)
        value['tasks'][0].update(title='Renamed',status='blocked',blockedReason='Waiting')
        validate_placement_changes(previous,value,now=NOW)
        historical=workspace(); historical['tasks'][0].update(done=True,status='done',remainingMinutes=0)
        historical['entries']=[{**block(),'start':'2026-10-01T14:00:00+08:00','end':'2026-10-01T15:00:00+08:00'}]
        validate_placement_changes(None,historical,now=NOW)

    def test_manual_time_may_be_outside_preferences_automatic_commit_must_follow(self):
        value=workspace(); value['entries']=[block(start='10:00',end='11:00')]
        validate_placement_changes(None,value,now=NOW)
        value['drafts']=[{'id':'draft','status':'committed','items':[{'task':value['tasks'][0],'entry':value['entries'][0]}]}]
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
        value['entries']=[block()]; value['drafts'][0]['items'][0]['entry']=value['entries'][0]
        validate_placement_changes(None,value,now=NOW)
        value['preferences']['dailyBudget']=30
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)

    def test_all_day_busy_pure_dates_follow_display_zone_for_new_and_legacy_entries(self):
        for date_fields in ({'startDate':'2026-11-02','endDate':'2026-11-03'}, {}):
            value=workspace(); value['preferences']['timeZone']='America/New_York'
            value['tasks'][0]['dueAt']='2026-11-04T00:00:00Z'
            value['externalBusyEntries']=[{'id':'all-day','title':'Busy date','allDay':True,
                'start':'2026-11-01T16:00:00Z','end':'2026-11-02T16:00:00Z',
                'timeZone':'Asia/Hong_Kong',**date_fields}]
            value['entries']=[{**block(),'start':'2026-11-03T01:00:00Z','end':'2026-11-03T02:00:00Z'}]
            with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
            value['entries']=[{**block(),'start':'2026-11-02T01:00:00Z','end':'2026-11-02T02:00:00Z'}]
            validate_placement_changes(None,value,now=NOW)

    def test_date_only_deadline_uses_tasks_original_zone(self):
        value=workspace(); value['tasks'][0].update(dueAt=None,dueDate='2026-11-02',timeZone='America/New_York')
        value['entries']=[{**block(),'start':'2026-11-03T03:00:00Z','end':'2026-11-03T04:00:00Z'}]
        validate_placement_changes(None,value,now=NOW)
        value['entries'][0].update(start='2026-11-03T04:00:00Z',end='2026-11-03T05:00:00Z')
        with self.assertRaises(ValidationError): validate_placement_changes(None,value,now=NOW)
    def test_rest_put_and_operation_batch_roll_back_invalid_placement(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'placement.sqlite3'
            auth=AuthStore(path)
            identity=auth.register({'username':'placement-user','email':'placement@example.test','password':'CorrectPassword123'})
            uid=identity['user']['id']; store=WorkspaceStore(path); sync=SyncStore(path)
            value=workspace(); saved=store.save(value,0,uid)
            # Dates well in the future make this independent of the test clock.
            invalid=copy.deepcopy(saved)
            invalid['tasks'][0]['dueAt']='2099-11-02T14:30:00Z'
            invalid['entries']=[{**block(),'start':'2099-11-02T14:00:00Z','end':'2099-11-02T15:00:00Z'}]
            with self.assertRaises(ValidationError): store.save(invalid,saved['revision'],uid)
            self.assertEqual(sync.load(uid)['entries'],[])
            operation={'id':'bad-block','entityType':'entries','entityId':'block','expectedVersion':0,'action':'upsert','value':invalid['entries'][0]}
            with self.assertRaises(ValidationError): sync.apply(uid,{'operations':[operation]})
            self.assertEqual(sync.load(uid)['entries'],[])
            with auth.connection() as db:
                self.assertEqual(db.execute('SELECT count(*) FROM sync_operations').fetchone()[0],0)

    def test_explicit_legacy_import_preserves_existing_conflicts_but_new_change_is_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'legacy.sqlite3'; auth=AuthStore(path)
            uid=auth.register({'username':'legacy-user','email':'legacy@example.test','password':'CorrectPassword123'})['user']['id']
            store=WorkspaceStore(path)
            value=workspace(); value['tasks'][0]['dueAt']='2099-11-02T18:00:00Z'
            value['entries']=[{**block(),'start':'2099-11-02T14:00:00Z','end':'2099-11-02T15:00:00Z'},
                {**block('fixed'),'taskId':None,'start':'2099-11-02T14:00:00Z','end':'2099-11-02T16:00:00Z'}]
            saved=store.save(value,0,uid,legacy_import=True)
            saved['tasks'][0]['title']='Imported conflict remains editable'
            saved=store.save(saved,saved['revision'],uid)
            saved['entries'][0]['start']='2099-11-02T14:30:00Z'
            with self.assertRaises(ValidationError): store.save(saved,saved['revision'],uid)


if __name__=='__main__':unittest.main()
