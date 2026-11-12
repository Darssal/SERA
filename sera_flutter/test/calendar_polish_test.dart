import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/calendar_layout.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _zone = 'Asia/Hong_Kong';
DateTime _date(String value) => readZoned(value, _zone)!;
CalendarEntry _event(
  String id,
  String start,
  String end, {
  bool allDay = false,
}) => CalendarEntry(
  id: id,
  title: '日程 $id',
  start: _date(start),
  end: _date(end),
  allDay: allDay,
);

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  int writes = 0;
  @override
  String get mode => 'calendar-polish-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    writes++;
    return value = next.copyWith(revision: expectedRevision + 1);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('sub-minute imported events retain a visible slice', () {
    final entry = _event(
      'short',
      '2026-10-31T10:00:10+08:00',
      '2026-10-31T10:00:40+08:00',
    );
    final slice = calendarDaySlices([entry], _date('2026-10-31'), _zone).single;
    expect((slice.startMinute, slice.endMinute), (600, 601));
  });
  testWidgets('calendar day navigation advances the date across DST fallback', (
    tester,
  ) async {
    const zone = 'America/New_York';
    final store = _Store(
      const Workspace(
        revision: 1,
        preferences: SeraPreferences(timeZone: zone),
      ),
    );
    final c = SeraController(
      repository: store,
      today: readZoned('2026-11-01', zone),
      seedDemo: false,
    );
    await c.initialize();
    c.setSelectedDate(readZoned('2026-11-01', zone)!);
    await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/12'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('后一天'));
    await tester.pumpAndSettle();
    expect(calendarDateString(c.selectedDate), '2026-11-02');
    await tester.tap(find.byTooltip('前一天'));
    await tester.pumpAndSettle();
    expect(calendarDateString(c.selectedDate), '2026-11-01');
    expect(store.writes, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  test(
    'DST repeated hour retains positive elapsed duration and exclusive day end',
    () {
      const zone = 'America/New_York';
      final entry = CalendarEntry(
        id: 'dst',
        title: '重复小时中的会议',
        start: readZoned('2026-11-01T01:30:00-04:00', zone)!,
        end: readZoned('2026-11-01T01:15:00-05:00', zone)!,
        timeZone: zone,
      );
      final slice = calendarDaySlices(
        [entry],
        DateTime(2026, 11, 1),
        zone,
      ).single;
      expect((slice.startMinute, slice.endMinute), (90, 135));
      final wholeDay = entry.copyWith(
        start: readZoned('2026-11-01', zone)!,
        end: readZoned('2026-11-02', zone)!,
      );
      expect(
        calendarDaySlices(
          [wholeDay],
          DateTime(2026, 11, 1),
          zone,
        ).single.endMinute,
        1500,
      );
      expect(
        calendarDaySlices([wholeDay], DateTime(2026, 11, 2), zone),
        isEmpty,
      );
    },
  );
  test('overnight slices are clipped per day without mutating the event', () {
    final entry = _event(
      'night',
      '2026-10-31T23:00:00+08:00',
      '2026-11-01T01:00:00+08:00',
    );
    final first = calendarDaySlices([entry], _date('2026-10-31'), _zone).single;
    final second = calendarDaySlices(
      [entry],
      _date('2026-11-01'),
      _zone,
    ).single;
    expect((first.startMinute, first.endMinute), (1380, 1440));
    expect((second.startMinute, second.endMinute), (0, 60));
    expect(first.continuesAfter, isTrue);
    expect(second.continuesBefore, isTrue);
    expect(entry.minutes, 120);
  });
  test(
    'exclusive midnight end and all-day events stay out of next timed day',
    () {
      final midnight = _event(
        'midnight',
        '2026-10-31T23:00:00+08:00',
        '2026-11-01T00:00:00+08:00',
      );
      final allDay = _event(
        'all',
        '2026-10-31T00:00:00+08:00',
        '2026-11-02T00:00:00+08:00',
        allDay: true,
      );
      expect(
        calendarDaySlices([midnight, allDay], _date('2026-11-01'), _zone),
        isEmpty,
      );
      expect(formatEntryRange(allDay), '10月31日 周六–11月1日 周日 · 全天');
    },
  );
  test('overlapping events get separate lanes and adjacent short events stay tappable', () {
    final entries = [
      _event('a', '2026-10-31T10:00:00+08:00', '2026-10-31T11:00:00+08:00'),
      _event('b', '2026-10-31T10:30:00+08:00', '2026-10-31T11:30:00+08:00'),
      _event('c', '2026-10-31T14:00:00+08:00', '2026-10-31T14:05:00+08:00'),
      _event('d', '2026-10-31T14:10:00+08:00', '2026-10-31T14:15:00+08:00'),
    ];
    final groups = calendarOverlapGroups(
      calendarDaySlices(entries, _date('2026-10-31'), _zone),
      scale: 1.2,
    );
    expect(groups.length, 2);
    for (final group in groups) {
      expect(group.placements.map((p) => p.lane).toSet(), {0, 1});
      expect(group.placements.every((p) => p.lanes == 2), isTrue);
      expect(
        group.placements.every(
          (p) => (p.bottomMinute - p.topMinute) * 1.2 >= 49.9,
        ),
        isTrue,
      );
    }
  });
  test('short late-night event remains inside the day and never covers next content', () {
    final entry = _event(
      'late',
      '2026-10-31T23:58:00+08:00',
      '2026-11-01T00:00:00+08:00',
    );
    final group = calendarOverlapGroups(
      calendarDaySlices([entry], _date('2026-10-31'), _zone),
      scale: 1.2,
    ).single;
    expect(group.topMinute, 1438);
    expect(group.placements.single.slice.endMinute, 1440);
    expect((group.bottomMinute - group.topMinute) * 1.2, closeTo(50, .01));
  });
  testWidgets(
    'day agenda overlap rows both open the correct event without writes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [
            _event(
              'a',
              '2026-10-31T10:00:00+08:00',
              '2026-10-31T11:00:00+08:00',
            ),
            _event(
              'b',
              '2026-10-31T10:30:00+08:00',
              '2026-10-31T11:30:00+08:00',
            ),
          ],
        ),
      );
      final c = SeraController(
        repository: store,
        today: _date('2026-10-31'),
        seedDemo: false,
      );
      await c.initialize();
      await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/12'));
      await tester.pumpAndSettle();
      final a = find.byKey(const ValueKey('calendar-event:a:600'));
      final b = find.byKey(const ValueKey('calendar-event:b:630'));
      final aRect = tester.getRect(a);
      final bRect = tester.getRect(b);
      expect(aRect.bottom <= bRect.top, isTrue);
      expect(bRect.bottom - aRect.top, lessThan(200));
      await tester.ensureVisible(a);
      await tester.tap(a);
      await tester.pumpAndSettle();
      expect(find.text('日程 a'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pumpAndSettle();
      expect(find.text('日程 b'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    '320px workweek opens an accessible list for the correct overlapping items',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [
            _event(
              'a',
              '2026-10-30T10:00:00+08:00',
              '2026-10-30T11:00:00+08:00',
            ),
            _event(
              'b',
              '2026-10-30T10:30:00+08:00',
              '2026-10-30T11:30:00+08:00',
            ),
          ],
        ),
      );
      final c = SeraController(
        repository: store,
        today: _date('2026-10-30'),
        seedDemo: false,
      );
      await c.initialize();
      await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/13'));
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('calendar-group:2026-10-30:a'));
      expect(tester.getSize(group).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(group).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(group);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(find.byType(SeraAgendaRow), findsNWidgets(2));
      await tester.tap(find.text('日程 b'));
      await tester.pumpAndSettle();
      expect(find.text('日程 b'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'day agenda shows a sparse midnight and evening without empty hours',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [
            _event(
              'night',
              '2026-11-01T00:00:00+08:00',
              '2026-11-01T01:00:00+08:00',
            ),
            _event(
              'evening',
              '2026-11-01T21:00:00+08:00',
              '2026-11-01T22:00:00+08:00',
            ),
          ],
        ),
      );
      final c = SeraController(repository: store, today: _date('2026-11-01'));
      await c.initialize();
      await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/12'));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('calendar-event:night:0'));
      final last = find.byKey(const ValueKey('calendar-event:evening:1260'));
      expect(first.hitTestable(), findsOneWidget);
      expect(last.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(last).top - tester.getRect(first).top,
        lessThan(100),
      );
      expect(find.text('00:00–01:00'), findsOneWidget);
      expect(find.text('21:00–22:00'), findsOneWidget);
      expect(find.text('09:00'), findsNothing);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'day agenda separates all-day and keeps cross-year exclusive dates',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [
            _event(
              'all',
              '2026-12-31T00:00:00+08:00',
              '2027-01-02T00:00:00+08:00',
              allDay: true,
            ),
            _event(
              'cross',
              '2026-12-31T23:00:00+08:00',
              '2027-01-01T01:00:00+08:00',
            ),
            _event(
              'ended',
              '2026-12-31T22:00:00+08:00',
              '2027-01-01T00:00:00+08:00',
            ),
          ],
        ),
      );
      final c = SeraController(repository: store, today: _date('2027-01-01'));
      await c.initialize();
      await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/12'));
      await tester.pumpAndSettle();
      final all = find.byKey(const ValueKey('all-day:all'));
      final cross = find.byKey(const ValueKey('calendar-event:cross:0'));
      expect(tester.getRect(all).bottom, lessThan(tester.getRect(cross).top));
      expect(find.text('日程 ended'), findsNothing);
      expect(find.text('2026年12月31日 23:00–2027年1月1日 01:00'), findsOneWidget);
      expect(find.text('2026年12月31日 周四–2027年1月1日 周五 · 全天'), findsOneWidget);
      await tester.tap(find.byTooltip('后一天'));
      await tester.pumpAndSettle();
      expect(find.text('日程 all'), findsNothing);
      expect(find.text('日程 cross'), findsNothing);
      expect(find.text('这一天没有安排'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  for (final textScale in [1.0, 1.5]) {
    testWidgets(
      'narrow workweek single entries show title and time at text scale $textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 844);
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final store = _Store(
          Workspace(
            revision: 1,
            entries: [
              _event(
                'single',
                '2026-10-30T10:00:00+08:00',
                '2026-10-30T11:00:00+08:00',
              ),
              _event(
                'all',
                '2026-10-30T00:00:00+08:00',
                '2026-10-31T00:00:00+08:00',
                allDay: true,
              ),
            ],
          ),
        );
        final c = SeraController(repository: store, today: _date('2026-10-30'));
        await c.initialize();
        await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/13'));
        await tester.pumpAndSettle();
        final entry = find.byKey(const ValueKey('calendar-event:single:600'));
        expect(
          find.byKey(const ValueKey('calendar-group:2026-10-30:single')),
          findsNothing,
        );
        expect(find.text('1项'), findsNothing);
        expect(find.text('1 项'), findsNothing);
        expect(
          find.descendant(of: entry, matching: find.text('日程 single')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: entry, matching: find.text('10:00')),
          findsOneWidget,
        );
        expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(entry).width, greaterThanOrEqualTo(48));
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text('日程详情'), findsOneWidget);
        expect(find.text('日程 single'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        final allDay = find.byKey(const ValueKey('all-day:2026-10-30'));
        expect(
          find.descendant(of: allDay, matching: find.text('日程 all')),
          findsOneWidget,
        );
        await tester.ensureVisible(allDay);
        await tester.tap(allDay);
        await tester.pumpAndSettle();
        expect(find.text('日程详情'), findsOneWidget);
        expect(find.text('日程 all'), findsOneWidget);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
