"""Server-side final placement checks, restricted to changed formal task blocks.

Existing conflicts/history remain representable. Importing a new fixed meeting or
external busy event must not make saving the calendar impossible.
"""
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from workspace_validation import ValidationError


def validate_placement_changes(previous, candidate, *, now=None):
    if candidate.get('schemaVersion') != 2: return
    now = now or datetime.now(timezone.utc)
    prefs = candidate['preferences']
    zone = ZoneInfo(prefs.get('timeZone', 'Asia/Hong_Kong'))
    def instant(raw, selected=zone):
        value = datetime.fromisoformat(raw.replace('Z', '+00:00'))
        return (value.replace(tzinfo=selected) if value.tzinfo is None else value).astimezone(timezone.utc)
    def bounds(entry):
        if not entry.get('allDay'): return instant(entry['start']), instant(entry['end'])
        original = ZoneInfo(entry.get('timeZone', 'Asia/Hong_Kong'))
        def day(key, stamp):
            raw = entry.get(key)
            value = datetime.fromisoformat(raw).date() if raw else instant(entry[stamp], original).astimezone(original).date()
            return datetime.combine(value, datetime.min.time(), tzinfo=zone).astimezone(timezone.utc)
        return day('startDate', 'start'), day('endDate', 'end')
    def timing(entry): return (entry.get('taskId'), entry.get('start'), entry.get('end'),
        entry.get('allDay', False), entry.get('startDate'), entry.get('endDate'))
    old = {entry['id']: entry for entry in (previous or {}).get('entries', [])}
    entries = candidate['entries']
    entries_by_id = {entry['id']: entry for entry in entries}
    tasks = {task['id']: task for task in candidate['tasks']}
    old_drafts = {draft['id']: draft for draft in (previous or {}).get('drafts', [])}
    automatic_ids = set()
    # A confirmed exception belongs only to the actual blocks of that plan.
    # It cannot raise preferences or grant another simultaneously saved plan
    # the same exception simply because they happen to share a calendar day.
    automatic_budgets = {}
    for draft in candidate.get('drafts', []):
        if draft.get('status') == 'committed' and not draft.get('targetTaskId') and old_drafts.get(draft['id'], {}).get('status') != 'committed':
            budget = draft.get('suggestedDailyBudget')
            if budget is not None:
                original = draft.get('originalDailyBudget')
                if (draft.get('budgetOverrideConfirmed') is not True or type(original) is not int or
                        not 15 <= original <= 480 or type(budget) is not int or not original < budget <= 1440):
                    raise ValidationError('Automatic plan budget override requires a valid explicit confirmation')
                goal_id = draft.get('goal', {}).get('id')
                if not goal_id or draft.get('targetGoalId') not in (None, goal_id):
                    raise ValidationError('Confirmed plan budget references an unrelated goal')
            for item in draft.get('items', []):
                blocks = ([item['entry']] if item.get('entry') else []) + item.get('additionalEntries', [])
                automatic_ids.update(block['id'] for block in blocks)
                if budget is not None:
                    task_id = item.get('task', {}).get('id')
                    formal_task = tasks.get(task_id)
                    if (formal_task is None or formal_task.get('goalId') != goal_id or
                            item['task'].get('goalId') != goal_id):
                        raise ValidationError('Confirmed plan budget references an unrelated task')
                    for block in blocks:
                        formal = entries_by_id.get(block['id'])
                        if (formal is None or block.get('taskId') != task_id or
                                formal.get('taskId') != task_id or timing(formal) != timing(block)):
                            raise ValidationError('Confirmed plan budget must match the saved task blocks')
                        if bounds(formal)[1] > instant(draft['goal']['deadline']):
                            raise ValidationError('Task block ends after its confirmed plan deadline')
                        previous_budget = automatic_budgets.get(block['id'])
                        if previous_budget is not None and previous_budget != budget:
                            raise ValidationError('Task block has conflicting plan budget confirmations')
                        automatic_budgets[block['id']] = budget
    changed = [entry for entry in entries if entry.get('taskId') and
        (entry['id'] not in old or timing(old[entry['id']]) != timing(entry) or entry['id'] in automatic_ids)
        and bounds(entry)[1] > now]
    if not changed: return
    affected = {entry['taskId'] for entry in changed}
    for tid in affected:
        task = tasks[tid]
        terminal = task.get('status') in ('done', 'canceled') or task.get('done') is True
        future = [entry for entry in entries if entry.get('taskId') == tid and bounds(entry)[1] > now]
        if terminal: raise ValidationError('Cannot add future blocks to a completed or canceled task')
        work = task.get('remainingMinutes', -1)
        if work < 0: work = task.get('estimatedMinutes', 30)
        minutes = [(bounds(entry)[1] - bounds(entry)[0]).total_seconds() / 60 for entry in future]
        if sum(minutes) > work + 1e-9: raise ValidationError('Task blocks exceed remaining work minutes')
        if len(future) > 1 and not task.get('splittable', False): raise ValidationError('Task does not allow split blocks')
        if len(future) > 1 and any(value < task.get('minBlockMinutes', 15) for value in minutes):
            raise ValidationError('Task block is shorter than minBlockMinutes')
    occupied = entries + candidate.get('externalBusyEntries', [])
    for entry in changed:
        task = tasks[entry['taskId']]
        start, end = bounds(entry)
        if task.get('notBefore') and start < instant(task['notBefore']):
            raise ValidationError('Task block starts before its phase window')
        for other in occupied:
            if other is entry: continue
            if start < bounds(other)[1] and end > bounds(other)[0]:
                raise ValidationError('Task block overlaps an existing task or busy event')
        deadline = task.get('dueAt')
        if deadline:
            if end > instant(deadline): raise ValidationError('Task block ends after its deadline')
        elif task.get('dueDate'):
            task_zone = ZoneInfo(task.get('timeZone', prefs.get('timeZone', 'Asia/Hong_Kong')))
            deadline = datetime.fromisoformat(task['dueDate']).replace(hour=23, minute=59, tzinfo=task_zone)
            if end > deadline.astimezone(timezone.utc): raise ValidationError('Task block ends after its due date')
        for dependency_id in task.get('dependencyIds', []):
            dependency = tasks[dependency_id]
            if dependency.get('done') or dependency.get('status') == 'done': continue
            blocks = [block for block in entries if block.get('taskId') == dependency_id]
            if not blocks or max(bounds(block)[1] for block in blocks) > start:
                raise ValidationError('Task block must follow its unfinished dependency blocks')
        if entry['id'] not in automatic_ids: continue
        # Preferences constrain automatic draft placement; a manually chosen
        # specific time may intentionally be outside the planning preferences.
        local_start, local_end = start.astimezone(zone), end.astimezone(zone)
        day = local_start.replace(hour=0, minute=0, second=0, microsecond=0)
        if local_start.isoweekday() not in prefs['weekdays'] or local_start < day + timedelta(minutes=prefs['startMinute']) or local_end > day + timedelta(minutes=prefs['endMinute']):
            raise ValidationError('Automatic task block is outside planning availability')
        rest_start, rest_end = prefs.get('restStart', 720), prefs.get('restEnd', 780)
        if rest_start < rest_end and local_start < day + timedelta(minutes=rest_end) and local_end > day + timedelta(minutes=rest_start):
            raise ValidationError('Automatic task block overlaps planning rest time')
        allocated = sum((bounds(block)[1] - bounds(block)[0]).total_seconds()/60 for block in entries
            if block.get('taskId') and bounds(block)[0].astimezone(zone).date() == local_start.date())
        budget = automatic_budgets.get(entry['id'], prefs['dailyBudget'])
        if allocated > budget + 1e-9: raise ValidationError('Automatic task blocks exceed daily planning budget')
        buffer = timedelta(minutes=prefs['bufferMinutes'])
        if any(other is not entry and start < bounds(other)[1] + buffer and end + buffer > bounds(other)[0] for other in occupied):
            raise ValidationError('Automatic task block does not preserve planning buffer')
