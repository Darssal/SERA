import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

DateTime _at(String value) => readZoned(value, 'Asia/Hong_Kong')!;

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  int writes = 0;
  @override
  String get mode => 'minimal-calendar-display';
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

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 844);
  tester.platformDispatcher.textScaleFactorTestValue = 1.5;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void _expectUnclippedLine(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(
    paragraph.size.height + 1,
    greaterThanOrEqualTo(paragraph.textSize.height),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final continuation in [false, true]) {
    testWidgets(
      'short midnight event keeps its name and actual end visible at enlarged text ${continuation ? 'on continuation day' : 'on start day'}',
      (tester) async {
        _viewport(tester);
        final entry = CalendarEntry(
          id: 'short-midnight',
          title: '夜间核对',
          start: _at('2026-10-31T23:50:00+08:00'),
          end: _at('2026-11-01T00:10:00+08:00'),
        );
        final store = _Store(Workspace(revision: 1, entries: [entry]));
        final day = continuation ? '2026-11-01' : '2026-10-31';
        final controller = SeraController(repository: store, today: _at(day));
        await controller.initialize();
        controller.setSelectedDate(_at(day));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          controller.dispose();
        });
        await tester.pumpWidget(
          SeraApp(controller: controller, initialLocation: '/12'),
        );
        await tester.pumpAndSettle();
        final event = find.byKey(
          ValueKey('calendar-event:${entry.id}:${continuation ? 0 : 1430}'),
        );
        expect(event, findsOneWidget);
        final title = find.descendant(
          of: event,
          matching: find.text(entry.title),
        );
        final range = find.descendant(
          of: event,
          matching: find.textContaining('00:10'),
        );
        expect(title, findsOneWidget);
        expect(range, findsOneWidget);
        final rangeText = tester.widget<Text>(range).data!;
        expect(rangeText, contains('23:50'));
        if (continuation) {
          expect(rangeText, contains('昨日'));
          expect(rangeText, isNot(contains('次日')));
        } else {
          expect(rangeText, contains('次日'));
        }
        _expectUnclippedLine(tester, title);
        _expectUnclippedLine(tester, range);
        expect(controller.entry(entry.id)!.start, entry.start);
        expect(controller.entry(entry.id)!.end, entry.end);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'responsive task row preserves full date semantics and separates completion from opening',
    (tester) async {
      _viewport(tester);
      final semantics = tester.ensureSemantics();
      try {
        final task = SeraTask(
          id: 'long-title',
          title: List.filled(8, '跨年准备材料与核对设备').join('，'),
          estimatedMinutes: 120,
        );
        final entry = CalendarEntry(
          id: 'cross-year',
          taskId: task.id,
          title: task.title,
          start: _at('2026-12-31T23:00:00+08:00'),
          end: _at('2027-01-01T01:00:00+08:00'),
        );
        var opens = 0;
        var completions = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: seraTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: SeraTaskRow(
                  task,
                  entry: entry,
                  showDate: true,
                  onTap: () => opens++,
                  onDone: (_) => completions++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final metadata = find.textContaining('2026年');
        expect(metadata, findsOneWidget);
        final metadataText = tester.widget<Text>(metadata).data!;
        for (final part in ['2026年12月31日', '23:00', '2027年1月1日', '01:00']) {
          expect(metadataText, contains(part));
        }
        _expectUnclippedLine(tester, metadata);
        expect(
          tester.getSemantics(find.text(task.title)).label,
          contains(task.title),
        );
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        expect(completions, 1);
        expect(opens, 0);
        await tester.tap(find.text(task.title));
        await tester.pump();
        expect(opens, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
