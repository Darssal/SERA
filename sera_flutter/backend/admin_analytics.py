"""Read-only community statistics from existing records, without event tracking.

The caller owns one SQLite read transaction and authorization. These aggregates
never read account_workspaces. Deletion/cancelation changes existing-row totals;
likes and participation have no creation time and cannot form a historical trend.
"""
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from auth_store import AuthError


TIME_ZONE = 'Asia/Hong_Kong'
_DAY_US = 86_400_000_000
_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def now_utc():
    return datetime.now(timezone.utc)


def parse_days(value):
    if isinstance(value, str) and value in ('7', '30', '90'):
        value = int(value)
    if type(value) is not int or value not in (7, 30, 90):
        raise AuthError('请选择最近 7、30 或 90 天。', 400, 'invalid_admin_request')
    return value


def _micros(value):
    delta = value.astimezone(timezone.utc) - _EPOCH
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def _iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')


def _contributors(db, start_us, end_us):
    return db.execute('''SELECT count(*) FROM (
        SELECT author_id FROM community_posts WHERE author_id IS NOT NULL AND created_at>=? AND created_at<=?
        UNION SELECT author_id FROM community_comments WHERE author_id IS NOT NULL AND created_at>=? AND created_at<=?)''',
        (start_us, end_us, start_us, end_us)).fetchone()[0]


def aggregate(db, days=30):
    """Return the public aggregate body and ordered IDs for CommunityPost DTOs."""
    days = parse_days(days)
    now = now_utc().astimezone(timezone.utc)
    zone = ZoneInfo(TIME_ZONE)
    local_now = now.astimezone(zone)
    start_date = local_now.date() - timedelta(days=days - 1)
    start = datetime.combine(start_date, time.min, zone)
    previous_start = start - timedelta(days=days)
    previous_end = now - timedelta(days=days)
    start_us, end_us = _micros(start), _micros(now)
    previous_start_us, previous_end_us = _micros(previous_start), _micros(previous_end)
    start_sec, end_sec = start_us // 1_000_000, end_us // 1_000_000
    previous_start_sec, previous_end_sec = previous_start_us // 1_000_000, previous_end_us // 1_000_000
    daily = [{'date': (start_date + timedelta(days=index)).isoformat(),
              'newUsers': 0, 'contributors': 0, 'posts': 0, 'comments': 0} for index in range(days)]

    # Epoch origins are local midnight, so integer buckets preserve the fixed
    # Hong Kong calendar day without asking SQLite for the host's local zone.
    for table, scale, field, lower, upper in (
        ('users', 1, 'newUsers', start_sec, end_sec),
        ('community_posts', 1_000_000, 'posts', start_us, end_us),
        ('community_comments', 1_000_000, 'comments', start_us, end_us),
    ):
        rows = db.execute(f'''SELECT CAST((created_at-?)/? AS INTEGER) AS day,count(*) AS count
            FROM {table} WHERE created_at>=? AND created_at<=? GROUP BY day''',
            (lower, 86400 * scale, lower, upper)).fetchall()
        for row in rows:
            daily[row['day']][field] = row['count']
    rows = db.execute('''SELECT day,count(DISTINCT author_id) AS count FROM (
        SELECT author_id,CAST((created_at-?)/? AS INTEGER) AS day FROM community_posts
            WHERE author_id IS NOT NULL AND created_at>=? AND created_at<=?
        UNION ALL SELECT author_id,CAST((created_at-?)/? AS INTEGER) AS day FROM community_comments
            WHERE author_id IS NOT NULL AND created_at>=? AND created_at<=?) GROUP BY day''',
        (start_us, _DAY_US, start_us, end_us, start_us, _DAY_US, start_us, end_us)).fetchall()
    for row in rows:
        daily[row['day']]['contributors'] = row['count']

    previous = {
        'newUsers': db.execute('SELECT count(*) FROM users WHERE created_at>=? AND created_at<=?',
                              (previous_start_sec, previous_end_sec)).fetchone()[0],
        'posts': db.execute('SELECT count(*) FROM community_posts WHERE created_at>=? AND created_at<=?',
                           (previous_start_us, previous_end_us)).fetchone()[0],
        'comments': db.execute('SELECT count(*) FROM community_comments WHERE created_at>=? AND created_at<=?',
                              (previous_start_us, previous_end_us)).fetchone()[0],
        'contributors': _contributors(db, previous_start_us, previous_end_us),
    }
    summary = {field: {'value': sum(day[field] for day in daily), 'previous': previous[field]}
               for field in ('newUsers', 'posts', 'comments')}
    summary['contributors'] = {'value': _contributors(db, start_us, end_us), 'previous': previous['contributors']}
    types = {'daily': 0, 'feedback': 0, 'activity': 0}
    for row in db.execute('''SELECT CASE WHEN kind='activity' THEN 'activity'
        WHEN category='feedback' THEN 'feedback' ELSE 'daily' END AS category,count(*) AS count
        FROM community_posts WHERE created_at>=? AND created_at<=? GROUP BY 1''', (start_us, end_us)):
        types[row['category']] = row['count']
    ranked = db.execute('''WITH ranked AS (
        SELECT p.id,p.sequence,
            (SELECT count(*) FROM community_likes l WHERE l.post_id=p.id) +
            (SELECT count(*) FROM community_comments c WHERE c.post_id=p.id) +
            (SELECT count(*) FROM community_participants j WHERE j.post_id=p.id) AS interactions
        FROM community_posts p WHERE p.created_at>=? AND p.created_at<=?)
        SELECT id,interactions FROM ranked WHERE interactions>0
        ORDER BY interactions DESC,sequence DESC LIMIT 5''', (start_us, end_us)).fetchall()

    def period(begin, end):
        return {'startDate': begin.astimezone(zone).date().isoformat(),
                'endDate': end.astimezone(zone).date().isoformat(), 'endAt': _iso(end)}

    result = {
        'days': days, 'timeZone': TIME_ZONE, 'generatedAt': _iso(now),
        'period': period(start, now), 'previousPeriod': period(previous_start, previous_end),
        'summary': {field: summary[field] for field in ('newUsers', 'contributors', 'posts', 'comments')},
        'daily': daily,
        'contentTypes': [{'key': key, 'label': label, 'count': types[key]}
                         for key, label in (('daily', '日常动态'), ('feedback', '使用反馈'), ('activity', '活动'))],
        'currentInteractions': {
            'likes': db.execute('SELECT count(*) FROM community_likes').fetchone()[0],
            'participants': db.execute('SELECT count(*) FROM community_participants').fetchone()[0],
        },
    }
    return result, ranked
