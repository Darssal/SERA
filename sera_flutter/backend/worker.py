"""Single-host durable AI-job and Web Push worker. Restart-safe leases."""
import argparse
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import time
from zoneinfo import ZoneInfo

from ai_service import SiliconFlowPlanner, AiServiceError, load_api_key, DEFAULT_MODEL
from model_runtime import create_planner
from workflows import WorkflowStore, ensure_vapid
from sync_store import SyncStore


def process_job(store, planner):
    now = int(time.time())
    with store.accounts.connection() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute("SELECT * FROM jobs WHERE status IN ('queued','pending') OR (status='running' AND lease_until<?) ORDER BY created_at LIMIT 1", (now,)).fetchone()
        if row is None: return False
        db.execute("UPDATE jobs SET status='running',lease_until=?,updated_at=? WHERE id=?", (now + 120, now, row['id']))
    try:
        if row['kind'] == 'understand':
            result = planner.understand(json.loads(row['payload']))
        elif row['kind'] == 'plan':
            generate_for_workspace = getattr(planner, 'generate_for_workspace', None)
            if callable(generate_for_workspace):
                with store.accounts.connection() as db:
                    saved = db.execute('SELECT body FROM account_workspaces WHERE user_id=?',
                                       (row['user_id'],)).fetchone()
                workspace = json.loads(saved['body']) if saved else None
                result = generate_for_workspace(json.loads(row['payload']), workspace)
            else:
                result = planner.generate(json.loads(row['payload']))
        else:
            raise AiServiceError('不支持的 AI 作业类型。', 400, 'invalid_ai_request')
        status, error = 'succeeded', None
    except AiServiceError as exc:
        result, status, error = None, 'failed', str(exc)
    except Exception:
        result, status, error = None, 'failed', 'Worker could not process this job.'
    with store.accounts.connection() as db:
        db.execute("UPDATE jobs SET status=?,result=?,error=?,updated_at=?,lease_until=0 WHERE id=? AND status='running'",
                   (status, json.dumps(result, ensure_ascii=False) if result else None, error, int(time.time()), row['id']))
    return True


def schedule_reminders(store, sync, now=None):
    now = time.time() if now is None else now
    with store.accounts.connection() as db:
        users = [row[0] for row in db.execute('SELECT user_id FROM account_workspaces')]
    for uid in users:
        workspace = sync.load(uid)
        prefs = workspace.get('preferences', {})
        if not prefs.get('notifications', True):
            with store.accounts.connection() as db:
                db.execute("UPDATE push_deliveries SET status='cancelled' WHERE user_id=? AND status='pending'", (uid,))
            continue
        tz = ZoneInfo(prefs.get('timeZone', 'Asia/Hong_Kong'))
        task_map = {task['id']: task for task in workspace.get('tasks', [])}
        active_keys = set()
        for entry in workspace.get('entries', []):
            task = task_map.get(entry.get('taskId'))
            if not task or task.get('done') or task.get('status') in ('done', 'completed', 'canceled'): continue
            if task.get('reminderMinutes', 10) < 0: continue
            start, end = datetime.fromisoformat(entry['start']), datetime.fromisoformat(entry['end'])
            if start.tzinfo is None: start = start.replace(tzinfo=tz)
            if end.tzinfo is None: end = end.replace(tzinfo=tz)
            candidates = [('start', start - timedelta(minutes=task.get('reminderMinutes', 10)), '/18', start + timedelta(minutes=10))]
            if prefs.get('followUp', True): candidates.append(('followup', end + timedelta(minutes=5), '/24', end + timedelta(minutes=40)))
            for kind, fire, route, expires in candidates:
                raw_fire = fire
                reminder_id = f'{entry["id"]}:{kind}'
                state = workspace.get('reminderStates', {}).get(reminder_id, {})
                scheduled_at = state.get('scheduledAt')
                if scheduled_at:
                    scheduled = datetime.fromisoformat(scheduled_at)
                    if scheduled.tzinfo is None: scheduled = scheduled.replace(tzinfo=tz)
                    if int(scheduled.timestamp() * 1000) != int(fire.timestamp() * 1000): state = {}
                else:
                    state = {}  # Legacy acknowledgment has no safe schedule identity.
                if state.get('status') == 'ack': continue
                if state.get('status') == 'snoozed':
                    postponed = state.get('snoozeUntil')
                    if postponed:
                        fire = datetime.fromisoformat(postponed)
                    elif state.get('at'):
                        fire = datetime.fromisoformat(state['at']) + timedelta(minutes=10)
                    if fire.tzinfo is None: fire = fire.replace(tzinfo=tz)
                    fire = fire.astimezone(tz)
                quiet_start, quiet_end = prefs.get('quietStart', 1320), prefs.get('quietEnd', 480)
                minute = fire.hour * 60 + fire.minute
                quiet = (quiet_start != quiet_end and (quiet_start <= minute < quiet_end if quiet_start < quiet_end else minute >= quiet_start or minute < quiet_end))
                if quiet:
                    target_day = fire + timedelta(days=1) if quiet_start > quiet_end and minute >= quiet_start else fire
                    fire = target_day.replace(hour=quiet_end // 60, minute=quiet_end % 60, second=0, microsecond=0)
                if fire > expires: continue
                fire_ms, expires_ms = int(fire.timestamp() * 1000), int(expires.timestamp() * 1000)
                key = f'{kind}:{entry["id"]}:{task["id"]}:{fire_ms}'
                active_keys.add(key)
                if expires.timestamp() <= now: continue
                pid = hashlib.sha256((uid + key).encode()).hexdigest()[:32]
                payload = {'id': pid, 'kind': 'reminder', 'reminderId': reminder_id, 'entryId': entry['id'], 'taskId': task['id'], 'title': '该向前一步了' if kind == 'start' else '现在进展如何？',
                    'body': task['title'], 'route': f'{route}?taskId={task["id"]}', 'scope': uid,
                    'scheduledAt': raw_fire.isoformat(),
                    'generation': workspace['revision'], 'fireAt': fire_ms, 'expiresAt': expires_ms,
                    'quietStart': quiet_start, 'quietEnd': quiet_end, 'timeZone': str(tz)}
                with store.accounts.connection() as db:
                    db.execute('''INSERT INTO push_deliveries(id,user_id,logical_key,payload,fire_at,status) VALUES(?,?,?,?,?,'pending')
                      ON CONFLICT(user_id,logical_key) DO UPDATE SET payload=excluded.payload,
                        status=CASE WHEN push_deliveries.status='cancelled' THEN 'pending'
                          WHEN push_deliveries.status='no_subscription' AND EXISTS(SELECT 1 FROM push_subscriptions WHERE user_id=excluded.user_id) THEN 'pending'
                          ELSE push_deliveries.status END,
                        attempts=CASE WHEN push_deliveries.status='cancelled' THEN 0 ELSE push_deliveries.attempts END''',
                      (pid, uid, key, json.dumps(payload, ensure_ascii=False), fire_ms))
        with store.accounts.connection() as db:
            rows = db.execute("SELECT id,logical_key FROM push_deliveries WHERE user_id=? AND status='pending'", (uid,)).fetchall()
            for row in rows:
                if ':' in row['logical_key'] and row['logical_key'] not in active_keys:
                    db.execute("UPDATE push_deliveries SET status='cancelled' WHERE id=?", (row['id'],))


def dispatch_pushes(store, sync, vapid_path, sender=None):
    from pywebpush import webpush, WebPushException
    sender = sender or webpush
    now_ms = int(time.time() * 1000)
    with store.accounts.connection() as db:
        rows = db.execute("SELECT * FROM push_deliveries WHERE status='pending' AND fire_at<=? AND attempts<5", (now_ms,)).fetchall()
    for row in rows:
        payload = json.loads(row['payload'])
        workspace = sync.load(row['user_id'])
        valid = payload['expiresAt'] > now_ms and (payload['generation'] == 0 or (workspace and workspace['revision'] == payload['generation']))
        if payload.get('taskId'):
            task = next((t for t in (workspace or {}).get('tasks', []) if t['id'] == payload['taskId']), None)
            valid = valid and task is not None and not task.get('done') and task.get('status') not in ('done', 'canceled') and workspace['preferences'].get('notifications', True)
        if not valid:
            with store.accounts.connection() as db: db.execute("UPDATE push_deliveries SET status='cancelled' WHERE id=?", (row['id'],))
            continue
        with store.accounts.connection() as db:
            subscriptions = db.execute('SELECT * FROM push_subscriptions WHERE user_id=?', (row['user_id'],)).fetchall()
        successes, failures = 0, 0
        for subscription in subscriptions:
            with store.accounts.connection() as db:
                live = db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND user_id=? AND expires_at>?',
                    (subscription['session_hash'], row['user_id'], int(time.time()))).fetchone()
                if not live:
                    db.execute('DELETE FROM push_subscriptions WHERE endpoint=? AND session_hash IS ?',
                        (subscription['endpoint'], subscription['session_hash']))
                    continue
            try:
                sender(subscription_info=json.loads(subscription['body']), data=json.dumps(payload, ensure_ascii=False),
                    vapid_private_key=str(vapid_path), vapid_claims={'sub': os.environ.get('VAPID_SUBJECT', 'mailto:sera-local@example.test')}, timeout=10, ttl=60)
                successes += 1
            except Exception as exc:
                failures += 1
                status = getattr(getattr(exc, 'response', None), 'status_code', None) or getattr(exc, 'status_code', None)
                if status in (404, 410):
                    with store.accounts.connection() as db: db.execute('DELETE FROM push_subscriptions WHERE endpoint=?', (subscription['endpoint'],))
        status = 'sent' if successes and not failures else ('failed' if row['attempts'] >= 4 else 'pending') if failures else 'no_subscription'
        with store.accounts.connection() as db:
            db.execute('UPDATE push_deliveries SET status=?,attempts=attempts+1,error=? WHERE id=?',
                       (status, f'{failures} subscription deliveries failed' if failures else None, row['id']))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', default=str(Path(__file__).with_name('sera.sqlite3')))
    parser.add_argument('--ai-key-file', default=os.environ.get('SILICONFLOW_API_KEY_FILE'))
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    store, sync = WorkflowStore(args.db), SyncStore(args.db)
    vapid = Path(args.db).with_suffix('.vapid.pem')
    ensure_vapid(vapid)
    planner = create_planner(load_api_key(args.ai_key_file), os.environ.get('SILICONFLOW_MODEL', DEFAULT_MODEL))
    while True:
        health = 'ok'
        try:
            process_job(store, planner)
            schedule_reminders(store, sync)
            dispatch_pushes(store, sync, vapid)
        except Exception:
            # Keep the worker alive and make failure observable without logging
            # provider credentials, customer payloads or subscription secrets.
            health = 'error'
        with store.accounts.connection() as db:
            db.execute('INSERT INTO service_heartbeats VALUES(?,?,?) ON CONFLICT(service) DO UPDATE SET updated_at=excluded.updated_at,status=excluded.status',
                ('worker', int(time.time()), health))
        if args.once: break
        time.sleep(2)


if __name__ == '__main__': main()
