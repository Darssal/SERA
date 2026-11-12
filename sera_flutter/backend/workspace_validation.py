"""Pure workspace validation and change-metadata compatibility rules.

Independent of HTTP, authentication and storage; the v1 module re-exports these
symbols for older callers. Validation behavior and public errors are unchanged.
"""
from __future__ import annotations
import copy
import hashlib
import json
import re
from datetime import datetime, timezone


class ValidationError(ValueError):
    pass


class ConflictError(ValueError):
    pass


def integer(value, name, minimum=0, maximum=2**31 - 1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValidationError(f'{name} must be an integer between {minimum} and {maximum}')
    return value


def text(value, name, maximum=200, allow_empty=False):
    if not isinstance(value, str) or len(value) > maximum or (not allow_empty and not value.strip()):
        raise ValidationError(f'{name} must be a non-empty string of at most {maximum} characters')
    return value


def date(value, name):
    try:
        parsed = datetime.fromisoformat(text(value, name, 64).replace('Z', '+00:00'))
        return parsed.astimezone(timezone.utc).replace(tzinfo=None) if parsed.tzinfo else parsed
    except (ValueError, TypeError) as exc:
        raise ValidationError(f'{name} must be an ISO 8601 datetime') from exc


def calendar_date(value, name):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValidationError(f'{name} must be YYYY-MM-DD')
    return date(value, name)


def time_zone(value, name):
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    try: ZoneInfo(value)
    except (ZoneInfoNotFoundError, TypeError, ValueError):
        raise ValidationError(f'Unsupported {name}') from None


def objects(value, name, maximum):
    if not isinstance(value, list) or len(value) > maximum or any(not isinstance(x, dict) for x in value):
        raise ValidationError(f'{name} must be an object array of at most {maximum} items')
    return value


def identifiers(items, name):
    ids = [text(x.get('id'), f'{name}.id', 128) for x in items]
    if len(ids) != len(set(ids)):
        raise ValidationError(f'{name} contains duplicate ids')
    return set(ids)


def validate_planning_messages(value):
    # Missing/null conversations are legacy sessions. New histories are bounded
    # and remain display data; they cannot introduce privileged model roles.
    if value is None:
        return
    messages = objects(value, 'planningSession.messages', 100)
    identifiers(messages, 'planningSession.messages')
    for message in messages:
        if (not set(message) <= {'id', 'role', 'text', 'understanding'}
                or message.get('role') not in ('user', 'assistant')):
            raise ValidationError('Invalid planning message')
        text(message.get('text'), 'planningMessage.text', 10000, True)
        reply = message.get('understanding')
        if reply is not None:
            if message['role'] != 'assistant' or not isinstance(reply, dict):
                raise ValidationError('Invalid planning message reply')
            try:
                encoded = json.dumps(reply, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
            except (TypeError, ValueError, UnicodeError, RecursionError):
                raise ValidationError('Invalid planning message reply') from None
            if len(encoded) > 64000:
                raise ValidationError('Planning message reply is too large')
        if not message['text'].strip() and reply is None:
            raise ValidationError('Planning message requires text or a structured reply')


def strings(value, name, maximum=100):
    if not isinstance(value, list) or len(value) > maximum:
        raise ValidationError(f'{name} must be a string array')
    for item in value:
        text(item, name, 500)
    if len(value) != len(set(value)):
        raise ValidationError(f'{name} contains duplicates')
    return value


def validate_task(item):
    text(item.get('id'), 'task.id', 128)
    text(item.get('title'), 'task.title')
    text(item.get('notes', ''), 'task.notes', 10000, True)
    text(item.get('phase', ''), 'task.phase', 100, True)
    if item.get('notBefore') is not None:
        earliest = date(item['notBefore'], 'task.notBefore')
        if item.get('dueAt') is not None and earliest >= date(item['dueAt'], 'task.dueAt'):
            raise ValidationError('task.notBefore must be before task.dueAt')
    if item.get('goalId') is not None:
        text(item['goalId'], 'task.goalId', 128)
    integer(item.get('estimatedMinutes', 30), 'task.estimatedMinutes', 1, 1440)
    integer(item.get('actualSeconds', 0), 'task.actualSeconds', 0)
    integer(item.get('reminderMinutes', 10), 'task.reminderMinutes', -1, 10080)
    integer(item.get('revision', 1), 'task.revision', 1)
    if item.get('dueAt') is not None:
        date(item['dueAt'], 'task.dueAt')
    if type(item.get('done', False)) is not bool:
        raise ValidationError('task.done must be boolean')
    checklist = strings(item.get('checklist', []), 'task.checklist')
    completed = strings(item.get('completedChecks', []), 'task.completedChecks')
    if not set(completed).issubset(checklist):
        raise ValidationError('completedChecks must belong to checklist')
    if 'status' in item and item['status'] not in ('todo', 'in_progress', 'blocked', 'done', 'canceled'):
        raise ValidationError('Invalid task status')
    if 'priority' in item and item['priority'] not in ('high', 'normal', 'low'):
        raise ValidationError('Invalid task priority')
    strings(item.get('dependencyIds', []), 'task.dependencyIds', 2000)
    integer(item.get('remainingMinutes', -1), 'task.remainingMinutes', -1, 1440)
    integer(item.get('minBlockMinutes', 15), 'task.minBlockMinutes', 5, 240)
    if type(item.get('splittable', False)) is not bool: raise ValidationError('task.splittable must be boolean')
    if item.get('dueDate') is not None:
        calendar_date(item['dueDate'], 'task.dueDate')
    text(item.get('blockedReason', ''), 'task.blockedReason', 10000, True)
    time_zone(item.get('timeZone', 'Asia/Hong_Kong'), 'task.timeZone')


def validate_entry(item, *, external=False):
    text(item.get('id'), 'entry.id', 128)
    text(item.get('title'), 'entry.title')
    start, end = date(item.get('start'), 'entry.start'), date(item.get('end'), 'entry.end')
    maximum = 86400 if item.get('taskId') is not None and not external else 366 * 86400
    if end <= start or (end - start).total_seconds() > maximum:
        raise ValidationError('entry duration must be positive; task blocks are limited to 24 hours and other events to 366 days')
    integer(item.get('revision', 1), 'entry.revision', 1)
    for key in ('notes', 'place'):
        text(item.get(key, ''), f'entry.{key}', 10000, True)
    if item.get('taskId') is not None:
        text(item['taskId'], 'entry.taskId', 128)
    if type(item.get('locked', False)) is not bool:
        raise ValidationError('entry.locked must be boolean')
    if type(item.get('allDay', False)) is not bool: raise ValidationError('entry.allDay must be boolean')
    text(item.get('source', 'local'), 'entry.source', 128)
    text(item.get('syncState', 'local_only'), 'entry.syncState', 128)
    if item.get('externalId') is not None: text(item['externalId'], 'entry.externalId', 1000)
    time_zone(item.get('timeZone', 'Asia/Hong_Kong'), 'entry.timeZone')
    start_day, end_day = item.get('startDate'), item.get('endDate')
    if start_day is not None or end_day is not None:
        if not item.get('allDay'): raise ValidationError('Date-only bounds require an allDay entry')
        first, last = calendar_date(start_day, 'entry.startDate'), calendar_date(end_day, 'entry.endDate')
        if not 0 < (last - first).days <= 366: raise ValidationError('All-day date range must be positive and at most 366 days')


def validate_goal(item):
    text(item.get('id'), 'goal.id', 128)
    text(item.get('title'), 'goal.title')
    text(item.get('outcome', ''), 'goal.outcome', 10000, True)
    date(item.get('deadline'), 'goal.deadline')
    strings(item.get('taskIds', []), 'goal.taskIds', 2000)
    integer(item.get('revision', 1), 'goal.revision', 1)
    if item.get('status', 'active') not in ('active', 'paused', 'completed', 'archived'):
        raise ValidationError('Invalid goal status')


HISTORY_COLLECTION_LIMITS = {
    'tasks': 2000, 'entries': 4000, 'goals': 500, 'drafts': 500,
    'focusRecords': 10000, 'externalBusyEntries': 10000, 'reviews': 2000,
}
HISTORY_LEGACY_FIELDS = ('id', 'label', 'at', 'before', 'after', 'undone')
HISTORY_DELTA_METADATA = ('format', 'afterDigest', 'beforeOrder', 'afterTaskEntries')


def preserve_change_metadata(previous, incoming):
    """Permit only an unchanged old-client echo of an existing compact record.

    The caller has already checked the account and write version. Never alter an
    operation's original body: sync receipt digests describe that original body.
    """
    if (previous is None or previous.get('format') != 'entity-delta-v1'
            or previous.get('id') != incoming.get('id')):
        return incoming
    if incoming.get('format') is not None:
        return incoming  # The regular format validator handles newer writes.
    if set(incoming) != set(HISTORY_LEGACY_FIELDS):
        raise ValidationError('Compact history cannot lose its format metadata')
    known_before = {key: previous[key] for key in HISTORY_LEGACY_FIELDS}
    # JSON comparison distinguishes booleans from numbers inside snapshots.
    if json.dumps(known_before, sort_keys=True) != json.dumps(incoming, sort_keys=True):
        raise ValidationError('Compact history cannot be replaced by a changed legacy record')
    restored = copy.deepcopy(incoming)
    for key in HISTORY_DELTA_METADATA:
        if key in previous:
            restored[key] = copy.deepcopy(previous[key])
    validate_change_record(restored)
    return restored


def validate_change_record(item):
    text(item.get('label'), 'history.label', 200)
    date(item.get('at'), 'history.at')
    if not isinstance(item.get('before'), dict) or not isinstance(item.get('after'), dict):
        raise ValidationError('history snapshots must be objects')
    if type(item.get('undone')) is not bool:
        raise ValidationError('history.undone must be boolean')
    encoding = item.get('format')
    if encoding is None:
        if any(key in item for key in ('afterDigest', 'beforeOrder', 'afterTaskEntries')):
            raise ValidationError('history delta metadata requires an explicit format')
        return
    if encoding != 'entity-delta-v1':
        raise ValidationError('Unsupported history format')
    if not isinstance(item.get('afterDigest'), str) or not re.fullmatch(r'[0-9a-f]{64}', item['afterDigest']):
        raise ValidationError('history.afterDigest must be a SHA-256 digest')
    sides = {}
    for name in ('before', 'after'):
        snapshot = item[name]
        if set(snapshot) - (set(HISTORY_COLLECTION_LIMITS) | {'preferences'}):
            raise ValidationError('history delta contains an unsupported collection')
        sides[name] = {}
        for kind, maximum in HISTORY_COLLECTION_LIMITS.items():
            values = objects(snapshot.get(kind), f'history.{name}.{kind}', maximum)
            sides[name][kind] = identifiers(values, f'history.{name}.{kind}')
        if 'preferences' in snapshot and not isinstance(snapshot['preferences'], dict):
            raise ValidationError('history preferences must be an object')
    if ('preferences' in item['before']) != ('preferences' in item['after']):
        raise ValidationError('history preferences change must contain both sides')
    order = item.get('beforeOrder')
    if not isinstance(order, dict) or set(order) - set(HISTORY_COLLECTION_LIMITS):
        raise ValidationError('history.beforeOrder contains an unsupported collection')
    for kind, maximum in HISTORY_COLLECTION_LIMITS.items():
        changed = sides['before'][kind] | sides['after'][kind]
        if changed and kind not in order:
            raise ValidationError('history changed collection needs its original order')
        if kind not in order:
            continue
        ids = order[kind]
        if not isinstance(ids, list) or len(ids) > maximum:
            raise ValidationError('history.beforeOrder must contain bounded ID lists')
        for eid in ids:
            text(eid, 'history.beforeOrder.id', 128)
        if len(set(ids)) != len(ids) or not sides['before'][kind].issubset(ids):
            raise ValidationError('history.beforeOrder must cover original entities uniquely')
    scopes = item.get('afterTaskEntries', {})
    if not isinstance(scopes, dict) or len(scopes) > 2000:
        raise ValidationError('history.afterTaskEntries must be a task map')
    if item['label'] == '完成任务':
        if set(scopes) != sides['after']['tasks']:
            raise ValidationError('completion history requires its related-entry scope')
    elif scopes:
        raise ValidationError('related-entry scope is reserved for task completion')
    for task_id, entries in scopes.items():
        text(task_id, 'history.afterTaskEntries.taskId', 128)
        if not isinstance(entries, dict) or len(entries) > 4000:
            raise ValidationError('history entry scope must be a bounded digest map')
        for eid, digest in entries.items():
            text(eid, 'history.afterTaskEntries.entryId', 128)
            if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
                raise ValidationError('history entry scope must contain SHA-256 digests')


def validate_workspace(workspace):
    if not isinstance(workspace, dict) or workspace.get('schemaVersion') not in (1, 2):
        raise ValidationError('workspace.schemaVersion must be 1 or 2')
    integer(workspace.get('revision'), 'workspace.revision')
    tasks = objects(workspace.get('tasks'), 'tasks', 2000)
    entries = objects(workspace.get('entries'), 'entries', 4000)
    goals = objects(workspace.get('goals'), 'goals', 500)
    drafts = objects(workspace.get('drafts'), 'drafts', 500)
    focus = objects(workspace.get('focusRecords'), 'focusRecords', 10000)
    history = objects(workspace.get('history'), 'history', 30)
    task_ids, goal_ids = identifiers(tasks, 'tasks'), identifiers(goals, 'goals')
    identifiers(entries, 'entries')
    identifiers(drafts, 'drafts')
    identifiers(focus, 'focusRecords')
    identifiers(history, 'history')
    for item in tasks:
        validate_task(item)
        if item.get('goalId') is not None and item['goalId'] not in goal_ids:
            raise ValidationError('task references a missing goal')
    scheduled_tasks = set()
    for item in entries:
        validate_entry(item)
        task_id = item.get('taskId')
        if task_id is not None:
            if task_id not in task_ids or (workspace['schemaVersion'] == 1 and task_id in scheduled_tasks):
                raise ValidationError('entry references a missing or already scheduled task')
            scheduled_tasks.add(task_id)
    task_by_id = {item['id']: item for item in tasks}
    visited, visiting = set(), set()
    def visit(tid):
        if tid in visiting: raise ValidationError('Task dependency cycle')
        if len(visiting) > 256: raise ValidationError('Task dependency chain exceeds 256 levels')
        if tid in visited: return
        visiting.add(tid)
        for dependency in task_by_id[tid].get('dependencyIds', []):
            if dependency not in task_by_id: raise ValidationError('Task dependency references missing task')
            visit(dependency)
        visiting.remove(tid); visited.add(tid)
    for task_id in task_by_id: visit(task_id)
    for item in goals:
        validate_goal(item)
        if any(t not in task_ids or task_by_id[t].get('goalId') != item['id'] for t in item.get('taskIds', [])):
            raise ValidationError('goal references an unrelated task')
    for item in focus:
        if item.get('taskId') not in task_ids:
            raise ValidationError('focusRecord references a missing task')
        date(item.get('startedAt'), 'focusRecord.startedAt')
        integer(item.get('seconds'), 'focusRecord.seconds', 1, 86400)
    for item in drafts:
        validate_goal(item.get('goal', {}))
        if item.get('status') not in ('draft', 'committed'):
            raise ValidationError('draft.status must be draft or committed')
        integer(item.get('baseRevision', 0), 'draft.baseRevision')
        original_budget = item.get('originalDailyBudget')
        suggested_budget = item.get('suggestedDailyBudget')
        confirmed_budget = item.get('budgetOverrideConfirmed', False)
        if type(confirmed_budget) is not bool:
            raise ValidationError('draft.budgetOverrideConfirmed must be boolean')
        if (original_budget is None) != (suggested_budget is None):
            raise ValidationError('draft budget suggestion requires its original budget')
        if original_budget is not None:
            integer(original_budget, 'draft.originalDailyBudget', 15, 480)
            integer(suggested_budget, 'draft.suggestedDailyBudget', original_budget + 1, 1440)
        elif confirmed_budget:
            raise ValidationError('draft budget confirmation requires a suggestion')
        if item.get('status') == 'committed' and suggested_budget is not None and not confirmed_budget:
            raise ValidationError('draft budget suggestion must be confirmed before commit')
        capacity_limited = item.get('capacityLimited', False)
        capacity_confirmed = item.get('capacityConfirmed', False)
        if type(capacity_limited) is not bool or type(capacity_confirmed) is not bool:
            raise ValidationError('draft capacityLimited and capacityConfirmed must be boolean')
        if capacity_confirmed and not capacity_limited:
            raise ValidationError('draft capacity confirmation requires a capacity-limited plan')
        text(item.get('prompt', ''), 'draft.prompt', 10000, True)
        planned = objects(item.get('items'), 'draft.items', 2000)
        target_task = item.get('targetTaskId')
        if target_task is not None:
            if target_task not in task_ids or len(planned) != 1 or planned[0].get('task', {}).get('id') != target_task:
                raise ValidationError('task refinement draft must contain only its existing target task')
        if item.get('targetGoalId') is not None and item['targetGoalId'] not in goal_ids:
            raise ValidationError('draft references a missing target goal')
        integer(item.get('validationRevision', 0), 'draft.validationRevision')
        text(item.get('calendarFingerprint', ''), 'draft.calendarFingerprint', 256, True)
        base_versions = item.get('baseTaskVersions', {})
        if not isinstance(base_versions, dict): raise ValidationError('draft.baseTaskVersions must be an object')
        for key, version in base_versions.items():
            text(key, 'draft.baseTaskVersions.key', 128); integer(version, 'draft.baseTaskVersions.version')
        draft_ids = []
        has_unplanned_active_task = False
        for planned_item in planned:
            task = planned_item.get('task', {})
            validate_task(task)
            draft_ids.append(task['id'])
            original_version = task_by_id[target_task].get('revision', 1) if target_task is not None else None
            still_current = target_task is not None and base_versions.get(target_task, original_version) == original_version
            if still_current and task.get('goalId') != task_by_id[target_task].get('goalId'):
                raise ValidationError('task refinement cannot change goal ownership')
            if target_task is None and task.get('goalId') != item['goal']['id']:
                raise ValidationError('draft task references an unrelated goal')
            if planned_item.get('entry') is not None:
                validate_entry(planned_item['entry'])
                if planned_item['entry'].get('taskId') != task['id']:
                    raise ValidationError('draft entry references an unrelated task')
            extra_entries = objects(planned_item.get('additionalEntries', []), 'draft.additionalEntries', 100)
            for extra in extra_entries:
                validate_entry(extra)
                if extra.get('taskId') != task['id']: raise ValidationError('draft split entry references an unrelated task')
            task_status = task.get('status', 'done' if task.get('done', False) else 'todo')
            if (task_status not in ('done', 'canceled') and planned_item.get('entry') is None
                    and not extra_entries):
                has_unplanned_active_task = True
        if len(draft_ids) != len(set(draft_ids)):
            raise ValidationError('draft contains duplicate task ids')
        if (item.get('status') == 'committed' and capacity_limited
                and has_unplanned_active_task and not capacity_confirmed):
            raise ValidationError('draft capacity-limited plan must be confirmed before commit')
    for item in history:
        validate_change_record(item)
    p = workspace.get('preferences')
    if not isinstance(p, dict):
        raise ValidationError('preferences must be an object')
    weekdays = p.get('weekdays')
    if not isinstance(weekdays, list) or not weekdays or len(set(weekdays)) != len(weekdays):
        raise ValidationError('preferences.weekdays must be a non-empty unique integer array')
    for day in weekdays:
        integer(day, 'preferences.weekdays', 1, 7)
    integer(p.get('dailyBudget'), 'preferences.dailyBudget', 15, 480)
    integer(p.get('bufferMinutes'), 'preferences.bufferMinutes', 0, 120)
    start = integer(p.get('startMinute'), 'preferences.startMinute', 0, 1439)
    end = integer(p.get('endMinute'), 'preferences.endMinute', 1, 1440)
    if start >= end:
        raise ValidationError('preferences endMinute must follow startMinute')
    for key in ('quietStart', 'quietEnd'):
        integer(p.get(key), f'preferences.{key}', 0, 1439)
    for key in ('notifications', 'followUp', 'useAiContext'):
        if type(p.get(key, False)) is not bool:
            raise ValidationError(f'preferences.{key} must be boolean')
    for key in ('restStart', 'restEnd'):
        integer(p.get(key, 720 if key == 'restStart' else 780), f'preferences.{key}', 0, 1439)
    if 'timeZone' in p:
        time_zone(p['timeZone'], 'preferences.timeZone')
    if workspace['schemaVersion'] == 2:
        external = objects(workspace.get('externalBusyEntries', []), 'externalBusyEntries', 10000)
        identifiers(external, 'externalBusyEntries')
        for item in external: validate_entry(item, external=True)
        for name, maximum in (('planningSessions', 500), ('reviews', 2000)):
            values = objects(workspace.get(name, []), name, maximum)
            identifiers(values, name)
        for item in workspace.get('planningSessions', []):
            date(item.get('updatedAt'), 'planningSession.updatedAt')
            integer(item.get('dailyBudget', 90), 'planningSession.dailyBudget', 15, 480)
            for key in ('prompt', 'title', 'notes'): text(item.get(key, ''), f'planningSession.{key}', 10000, True)
            text(item.get('stage', 'input'), 'planningSession.stage', 64)
            validate_planning_messages(item.get('messages'))
            composer_draft = item.get('composerDraft')
            text('' if composer_draft is None else composer_draft, 'planningSession.composerDraft', 10000, True)
            if item.get('deadline') is not None: date(item['deadline'], 'planningSession.deadline')
            if item.get('draftId') is not None: text(item['draftId'], 'planningSession.draftId', 128)
            result = item.get('resultEntity')
            if result is not None:
                if (not isinstance(result, dict) or set(result) != {'kind', 'id'}
                        or result.get('kind') not in ('task', 'event')):
                    raise ValidationError('Invalid planningSession.resultEntity')
                text(result.get('id'), 'planningSession.resultEntity.id', 128)
                expected = planning_result_id(item['id'], result['kind'])
                if result['id'] != expected or item.get('stage') != 'confirmed':
                    raise ValidationError('Planning result requires confirmed stage and stable source id')
        for item in workspace.get('reviews', []):
            calendar_date(item.get('day'), 'review.day')
            if item.get('kind', 'daily') not in ('daily', 'weekly'): raise ValidationError('Invalid review.kind')
            text(item.get('feedback', ''), 'review.feedback', 10000, True)
        active_focus = workspace.get('focusSession')
        if active_focus is not None:
            if not isinstance(active_focus, dict) or active_focus.get('taskId') not in task_ids:
                raise ValidationError('Focus session references missing task')
            date(active_focus.get('startedAt'), 'focusSession.startedAt')
            text(active_focus.get('id'), 'focusSession.id', 128)
            if active_focus.get('lastResumedAt') is not None:
                if date(active_focus['lastResumedAt'], 'focusSession.lastResumedAt') < date(active_focus['startedAt'], 'focusSession.startedAt'):
                    raise ValidationError('focusSession.lastResumedAt cannot precede startedAt')
            if type(active_focus.get('isRunning', True)) is not bool: raise ValidationError('focusSession.isRunning must be boolean')
            integer(active_focus.get('accumulatedSeconds', 0), 'focusSession.accumulatedSeconds', 0, 86400)
            if active_focus.get('targetMinutes') is not None:
                integer(active_focus['targetMinutes'], 'focusSession.targetMinutes', 1, 1440)
        for name in ('reminderStates', 'platformSettings', 'entityVersions'):
            if not isinstance(workspace.get(name, {}), dict): raise ValidationError(f'{name} must be an object')
        for key, state in workspace.get('reminderStates', {}).items():
            text(key, 'reminderStates.key', 256)
            if not isinstance(state, dict) or state.get('status') not in ('ack', 'snoozed'):
                raise ValidationError('reminder state must be ack or snoozed')
            date(state.get('at'), 'reminderState.at')
            if state.get('scheduledAt') is not None: date(state['scheduledAt'], 'reminderState.scheduledAt')
            if state.get('snoozeUntil') is not None: date(state['snoozeUntil'], 'reminderState.snoozeUntil')
        for key, value in workspace.get('entityVersions', {}).items():
            text(key, 'entityVersions.key', 256); integer(value, 'entityVersions.version')


def planning_result_id(session_id, kind):
    return 'planning-' + kind + '-' + hashlib.sha256(session_id.encode('utf-8')).hexdigest()


def validate_planning_result_changes(previous, incoming, *, allow_imported_tombstones=False):
    """Completion is atomic; explicit whole-workspace imports may carry tombstones."""
    before = {item['id']: item for item in (previous or {}).get('planningSessions', [])}
    tasks = {item['id'] for item in incoming.get('tasks', [])}
    events = {item['id'] for item in incoming.get('entries', []) if item.get('taskId') is None}
    entries = {item['id'] for item in incoming.get('entries', [])}
    for session in incoming.get('planningSessions', []):
        result = session.get('resultEntity')
        old = before.get(session['id'], {}).get('resultEntity')
        if old is not None:
            if result != old or session.get('stage') != 'confirmed':
                raise ValidationError('Confirmed planning result cannot be changed or downgraded')
        elif result is not None:
            if result['id'] not in (tasks if result['kind'] == 'task' else events):
                if allow_imported_tombstones and not (result['kind'] == 'event' and result['id'] in entries):
                    continue
                raise ValidationError('New planning result and its entity must be saved together')
