import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _zone = 'Asia/Hong_Kong';
DateTime _date(String value) => readZoned(value, _zone)!;

CalendarEntry _event(String id, String start, String end) => CalendarEntry(
  id: id,
  title: '周安排 $id',
  start: _date(start),
  end: _date(end),
);

class _Store implements WorkspaceRepository {
  _Store(List<CalendarEntry> entries)
    : value = Workspace(
        revision: 1,
        preferences: const SeraPreferences(timeZone: _zone),
        entries: entries,
      );

  Workspace? value;
  int writes = 0;

  @override
  String get mode => 'compact-calendar-week-test';

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

Finder get _timeViewport =>
    find.byKey(const ValueKey('calendar-week-time-viewport'));

Finder get _timeScroll =>
    find.byKey(const ValueKey('calendar-week-time-scroll'));

ScrollPosition _timePosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: _timeScroll,
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

void _screen(WidgetTester tester, double width, {double textScale = 1}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<SeraController> _mount(
  WidgetTester tester,
  _Store store, {
  String location = '/13',
}) async {
  final controller = SeraController(
    repository: store,
    today: _date('2026-11-02'),
    seedDemo: false,
  );
  await controller.initialize();
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [(390.0, 1.0), (320.0, 1.5)]) {
    testWidgets(
      'bounded workweek keeps midnight and last-minute items reachable at '
      '${size.$1}px and ${size.$2} text scale',
      (tester) async {
        _screen(tester, size.$1, textScale: size.$2);
        final store = _Store([
          _event(
            'midnight',
            '2026-11-02T00:00:00+08:00',
            '2026-11-02T01:00:00+08:00',
          ),
          _event(
            'last-minute',
            '2026-11-02T23:58:00+08:00',
            '2026-11-03T00:00:00+08:00',
          ),
        ]);
        await _mount(tester, store);

        expect(tester.getSize(_timeViewport).height, lessThanOrEqualTo(380));
        expect(_timePosition(tester).maxScrollExtent, greaterThan(1000));
        expect(find.text('今日').hitTestable(), findsOneWidget);
        expect(find.text('计划').hitTestable(), findsOneWidget);
        expect(find.byTooltip('账户与设置'), findsNothing);

        for (final key in [
          'calendar-event:last-minute:1438',
          'calendar-event:midnight:0',
        ]) {
          final item = find.byKey(ValueKey(key));
          await tester.ensureVisible(item);
          await tester.pumpAndSettle();
          expect(item.hitTestable(), findsOneWidget);
          expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
          await tester.tap(item);
          await tester.pumpAndSettle();
          expect(find.text('日程详情'), findsOneWidget);
          await tester.tap(find.byTooltip('返回'));
          await tester.pumpAndSettle();
        }

        expect(find.text('日程').hitTestable(), findsWidgets);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late-only week initially shows its first actual arrangement', (
    tester,
  ) async {
    _screen(tester, 390);
    final store = _Store([
      _event(
        'evening',
        '2026-11-02T21:00:00+08:00',
        '2026-11-02T22:00:00+08:00',
      ),
    ]);
    await _mount(tester, store);

    final item = find.byKey(const ValueKey('calendar-event:evening:1260'));
    expect(item.hitTestable(), findsOneWidget);
    expect(_timePosition(tester).maxScrollExtent, closeTo(0, 1));
    expect(tester.getSize(_timeViewport).height, lessThan(250));
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused late Friday reveals both axes on a narrow workweek', (
    tester,
  ) async {
    _screen(tester, 320, textScale: 1.5);
    final store = _Store([
      _event(
        'monday',
        '2026-11-02T00:00:00+08:00',
        '2026-11-02T01:00:00+08:00',
      ),
      _event(
        'friday',
        '2026-11-06T23:58:00+08:00',
        '2026-11-07T00:00:00+08:00',
      ),
    ]);
    await _mount(tester, store, location: '/13?focusEntryId=friday');

    final item = find.byKey(const ValueKey('calendar-event:friday:1438'));
    expect(item.hitTestable(), findsOneWidget);
    expect(_timePosition(tester).pixels, greaterThan(1000));
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(find.text('日程详情'), findsOneWidget);
    expect(find.text('周安排 friday'), findsOneWidget);
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'workweek preserves a manual scroll across rebuild and detail return '
    'and resets it when changing weeks',
    (tester) async {
      _screen(tester, 390);
      final store = _Store([
        _event(
          'early',
          '2026-11-02T00:00:00+08:00',
          '2026-11-02T01:00:00+08:00',
        ),
        _event(
          'late',
          '2026-11-02T21:00:00+08:00',
          '2026-11-02T22:00:00+08:00',
        ),
        _event(
          'next-week',
          '2026-11-09T09:00:00+08:00',
          '2026-11-09T10:00:00+08:00',
        ),
      ]);
      final controller = await _mount(tester, store);
      final item = find.byKey(const ValueKey('calendar-event:late:1260'));
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      final offset = _timePosition(tester).pixels;
      expect(offset, greaterThan(1000));

      controller.setSelectedDate(_date('2026-11-03'));
      await tester.pumpAndSettle();
      expect(_timePosition(tester).pixels, closeTo(offset, 1));
      expect(item.hitTestable(), findsOneWidget);
      await tester.tap(item);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(_timePosition(tester).pixels, closeTo(offset, 1));

      final next = find.byTooltip('下一周');
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(_timePosition(tester).pixels, lessThan(100));
      expect(
        find
            .byKey(const ValueKey('calendar-event:next-week:540'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byTooltip('账户与设置'), findsNothing);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
