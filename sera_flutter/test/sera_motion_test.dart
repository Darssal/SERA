import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';

void main() {
  test('tasks share primary motion and account settings open as a detail', () {
    for (final route in [
      '/04',
      '/17?filter=todo',
      '/37',
      '/12',
      '/13',
      '/14',
      '/20',
    ]) {
      expect(SeraMotion.motionFor(Uri.parse(route)), SeraRouteMotion.primary);
    }
    expect(SeraMotion.motionFor(Uri.parse('/30')), SeraRouteMotion.detail);
    expect(
      SeraMotion.motionFor(Uri.parse('/30-settings')),
      SeraRouteMotion.detail,
    );
  });

  test(
    'route identity follows entities and drafts without exposing query data',
    () {
      LocalKey keyFor(String location, {String slot = 'router-slot'}) =>
          SeraMotion.routeKey(
            routerKey: ValueKey(slot),
            uri: Uri.parse(location),
          );

      expect(keyFor('/25?taskId=first'), isNot(keyFor('/25?taskId=second')));
      expect(keyFor('/25?eventId=first'), isNot(keyFor('/25?eventId=second')));
      expect(keyFor('/08?draftId=first'), isNot(keyFor('/08?draftId=second')));
      expect(keyFor('/21?goalId=first'), isNot(keyFor('/21?goalId=second')));
      expect(
        keyFor('/05?sessionId=first'),
        isNot(keyFor('/05?sessionId=second')),
      );
      expect(keyFor('/04'), isNot(keyFor('/12')));
      expect(
        keyFor('/25?taskId=first'),
        isNot(keyFor('/25?taskId=first', slot: 'pushed-slot')),
      );
      expect(
        keyFor('/25?taskId=first&eventId=second'),
        keyFor('/25?eventId=second&taskId=first'),
      );
      expect(
        keyFor('/25?taskId=first&sort=title'),
        keyFor('/25?taskId=first&sort=date'),
      );
      expect(keyFor('/19?title=first'), isNot(keyFor('/19?title=second')));
      expect(
        keyFor('/16?start=2026-11-01T09%3A00%3A00'),
        isNot(keyFor('/16?start=2026-11-01T10%3A00%3A00')),
      );
      expect(
        keyFor('/05?new=1&prompt=first'),
        isNot(keyFor('/05?new=1&prompt=second')),
      );
      // A query prefill cannot overwrite a draft for an existing object.
      expect(
        keyFor('/19?taskId=first&title=old'),
        keyFor('/19?taskId=first&title=new'),
      );
      expect(
        keyFor('/19?draftId=first&title=old'),
        keyFor('/19?draftId=first&title=new'),
      );
      expect(
        keyFor('/16?eventId=first&start=old'),
        keyFor('/16?eventId=first&start=new'),
      );
      expect(
        keyFor('/reset-password?token=first'),
        isNot(keyFor('/reset-password?token=second')),
      );
      expect(
        keyFor('/verify-email?token=first'),
        isNot(keyFor('/verify-email?token=second')),
      );

      for (final location in [
        '/05?prompt=sample-private-prompt',
        '/19?notes=sample-private-notes',
        '/verify-email?token=sample-private-token',
        '/reset-password?token=sample-private-token',
      ]) {
        final description = keyFor(location).toString();
        expect(description, isNot(contains('sample-private')));
        expect(description, isNot(contains('?')));
      }
    },
  );

  testWidgets(
    'detail and primary routes have bounded intermediate frames and settle once',
    (tester) async {
      final harness = await _pumpHarness(tester);
      unawaited(harness.router.push<void>('/25?taskId=first'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final detail = harness.ledger.created.last;
      expect(_opacity(tester, detail), inExclusiveRange(0.0, 1.0));
      final detailOffset = _translation(tester, detail);
      expect(detailOffset.dx, inExclusiveRange(0.0, 18.01));
      expect(detailOffset.dy, 0);
      expect(_clipFor(detail), findsOneWidget);
      final numberOfInstances = harness.ledger.created.length;
      await tester.pumpAndSettle();
      expect(_opacity(tester, detail), 1);
      expect(_translation(tester, detail), Offset.zero);
      expect(harness.ledger.created.length, numberOfInstances);
      expect(_absorber(tester, detail).absorbing, isFalse);

      harness.router.go('/12');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final primary = harness.ledger.created.last;
      expect(primary.widget.label, '/12:');
      expect(_opacity(tester, primary), inExclusiveRange(0.0, 1.0));
      expect(_translation(tester, primary), Offset.zero);
      await tester.pumpAndSettle();
      expect(_opacity(tester, primary), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'moving pages stay clipped at mobile widths and in the desktop center',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final harness = await _pumpHarness(tester);

      for (final width in [320.0, 360.0, 390.0, 430.0, 800.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump();
        harness.router.go('/25?taskId=width-$width');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final page = harness.ledger.created.last;
        final clip = tester.getRect(_clipFor(page));
        final expectedWidth = math.min(width, 430.0);
        expect(clip.width, closeTo(expectedWidth, 0.01));
        expect(clip.left, closeTo((width - expectedWidth) / 2, 0.01));
        expect(clip.right, lessThanOrEqualTo(width));
        expect(_translation(tester, page).dx, inExclusiveRange(0.0, 18.01));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same dynamic route replaces a new entity but a refresh preserves its draft',
    (tester) async {
      final harness = await _pumpHarness(
        tester,
        initialLocation: '/25?taskId=first',
      );
      final first = harness.ledger.created.single;
      first.text.text = 'Unsaved local draft';
      harness.router.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(harness.ledger.created, hasLength(1));
      expect(first.text.text, 'Unsaved local draft');
      expect(_opacity(tester, first), 1);
      expect(_translation(tester, first), Offset.zero);

      harness.router.go('/25?taskId=second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final second = harness.ledger.created.last;
      expect(second, isNot(same(first)));
      expect(second.widget.label, '/25:second');
      expect(second.text.text, isEmpty);
      await tester.pumpAndSettle();
      expect(harness.ledger.disposed, contains(first));
      expect(find.byType(_ProbePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pushing the same URI creates an independent instance and restores the original on pop',
    (tester) async {
      final harness = await _pumpHarness(
        tester,
        initialLocation: '/25?taskId=first',
      );
      final original = harness.ledger.created.single;
      original.text.text = 'Original draft';
      final completed = harness.router.push<void>('/25?taskId=first');
      await tester.pumpAndSettle();
      final pushed = harness.ledger.created.last;
      expect(pushed, isNot(same(original)));
      expect(pushed.text.text, isEmpty);
      pushed.text.text = 'Independent pushed draft';
      harness.router.pop();
      await tester.pumpAndSettle();
      await completed;

      expect(harness.ledger.created, hasLength(2));
      expect(original.mounted, isTrue);
      expect(original.text.text, 'Original draft');
      expect(harness.ledger.disposed, contains(pushed));
      expect(find.byType(_ProbePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('form text and scroll position survive a detail push and pop', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester, initialLocation: '/19');
    final form = harness.ledger.created.single;
    await tester.enterText(
      find.byKey(const ValueKey('draft-/19:')),
      'Keep this form text',
    );
    form.focus.unfocus();
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('list-/19:')),
      const Offset(0, -330),
    );
    await tester.pumpAndSettle();
    final before = form.scroll.offset;
    expect(before, greaterThan(200));
    form.focus.requestFocus();
    await tester.pump();
    expect(form.focus.hasFocus, isTrue);

    final completed = harness.router.push<void>('/25?taskId=first');
    await tester.pumpAndSettle();
    harness.router.pop();
    await tester.pumpAndSettle();
    await completed;
    expect(form.mounted, isTrue);
    expect(form.text.text, 'Keep this form text');
    expect(form.scroll.offset, closeTo(before, 0.01));
    expect(form.focus.hasFocus, isTrue);
    expect(harness.ledger.created, hasLength(2));
    expect(tester.takeException(), isNull);
    form.focus.unfocus();
    await tester.pump();
  });

  testWidgets(
    'rapid go changes and a back action interrupting push leave one valid route',
    (tester) async {
      final harness = await _pumpHarness(tester);
      for (final location in ['/25?taskId=first', '/19?taskId=first', '/12']) {
        harness.router.go(location);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final original = harness.ledger.created.last;
      expect(original.widget.label, '/12:');
      expect(find.byType(_ProbePage), findsOneWidget);

      final completed = harness.router.push<void>('/25?taskId=second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final interrupted = harness.ledger.created.last;
      final beforeBack = _translation(tester, interrupted);
      expect(_opacity(tester, interrupted), inExclusiveRange(0.0, 1.0));
      harness.router.pop();
      await tester.pump();
      expect(
        _translation(tester, interrupted).dx,
        closeTo(beforeBack.dx, 0.01),
      );
      await tester.pumpAndSettle();
      await completed;
      expect(original.mounted, isTrue);
      expect(harness.ledger.disposed, contains(interrupted));
      expect(find.byType(_ProbePage), findsOneWidget);
      expect(_opacity(tester, original), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion removes movement and pointer delays without remounting a live form',
    (tester) async {
      final harness = await _pumpHarness(tester);
      final completed = harness.router.push<void>('/19');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final form = harness.ledger.created.last;
      form.text.text = 'Preserve during accessibility change';
      expect(_opacity(tester, form), inExclusiveRange(0.0, 1.0));

      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      expect(harness.ledger.created.last, same(form));
      expect(form.text.text, 'Preserve during accessibility change');
      expect(_opacity(tester, form), 1);
      expect(_translation(tester, form), Offset.zero);
      expect(_absorber(tester, form).absorbing, isFalse);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/19:'))),
      );
      expect(form.taps, 1);
      expect(SeraMotion.dialogStyle(form.context), AnimationStyle.noAnimation);
      expect(SeraMotion.sheetStyle(form.context), AnimationStyle.noAnimation);
      harness.router.pop();
      await tester.pumpAndSettle();
      await completed;

      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
        accessibleNavigation: true,
      );
      await tester.pump();
      unawaited(harness.router.push<void>('/25?taskId=accessible'));
      await tester.pumpAndSettle();
      final accessible = harness.ledger.created.last;
      expect(
        (ModalRoute.of(accessible.context)! as PageRoute<void>)
            .transitionDuration,
        Duration.zero,
      );
      expect(_opacity(tester, accessible), 1);
      expect(_translation(tester, accessible), Offset.zero);
      expect(_absorber(tester, accessible).absorbing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'enabling reduced motion after entry makes pop invisible and interactive in one frame',
    (tester) async {
      final harness = await _pumpHarness(tester);
      final original = harness.ledger.created.single;
      final completed = harness.router.push<void>('/25?taskId=first');
      await tester.pumpAndSettle();
      final detail = harness.ledger.created.last;
      expect(_opacity(tester, detail), 1);
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();

      harness.router.pop();
      await tester.pump();
      expect(find.byWidget(detail.widget), findsNothing);
      expect(find.byType(_ProbePage), findsOneWidget);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/04:'))),
      );
      expect(original.taps, 1);
      expect(detail.taps, 0);
      await tester.pumpAndSettle();
      await completed;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account route has no visible transition or touch lock with normal system motion',
    (tester) async {
      final harness = await _pumpHarness(tester, initialLocation: '/19');
      expect(harness.environment.value.disableAnimations, isFalse);
      expect(harness.environment.value.accessibleNavigation, isFalse);
      harness.router.go('/login');
      await tester.pump();
      final account = harness.ledger.created.last;
      expect(account.widget.label, '/login:');
      expect(
        (ModalRoute.of(account.context)! as PageRoute<void>).transitionDuration,
        Duration.zero,
      );
      expect(_opacity(tester, account), 1);
      expect(_translation(tester, account), Offset.zero);
      expect(_absorber(tester, account).absorbing, isFalse);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/login:'))),
      );
      expect(account.taps, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an open soft keyboard keeps route entry to a fade with no translation',
    (tester) async {
      final harness = await _pumpHarness(tester);
      harness.environment.value = harness.environment.value.copyWith(
        viewInsets: const EdgeInsets.only(bottom: 260),
      );
      await tester.pump();
      final completed = harness.router.push<void>('/19');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final form = harness.ledger.created.last;
      expect(_opacity(tester, form), inExclusiveRange(0.0, 1.0));
      expect(_translation(tester, form), Offset.zero);
      harness.environment.value = harness.environment.value.copyWith(
        viewInsets: EdgeInsets.zero,
      );
      await tester.pump();
      expect(_translation(tester, form), Offset.zero);
      await tester.pumpAndSettle();
      expect(_opacity(tester, form), 1);
      harness.router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final returningOffset = _translation(tester, form);
      expect(returningOffset.dx, 0);
      expect(returningOffset.dy, inExclusiveRange(0.0, 16.01));
      await tester.pumpAndSettle();
      await completed;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touches during entry and exit cannot reach either overlapping page',
    (tester) async {
      final harness = await _pumpHarness(tester);
      final original = harness.ledger.created.single;
      final completed = harness.router.push<void>('/25?taskId=first');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final detail = harness.ledger.created.last;
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/25:first'))),
      );
      expect(detail.taps, 0);
      expect(original.taps, 0);
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/25:first'))),
      );
      expect(detail.taps, 1);
      expect(original.taps, 0);

      harness.router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/04:'))),
      );
      expect(detail.taps, 1);
      expect(original.taps, 0);
      await tester.pumpAndSettle();
      await completed;
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/04:'))),
      );
      expect(original.taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'turning reduced motion off during entry does not rewind a form or relock it',
    (tester) async {
      final harness = await _pumpHarness(tester);
      final completed = harness.router.push<void>('/19');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final form = harness.ledger.created.last;
      form.text.text = 'Keep this draft across both toggles';
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
      );
      await tester.pump();
      expect(_opacity(tester, form), 1);
      expect(_translation(tester, form), Offset.zero);
      expect(_absorber(tester, form).absorbing, isFalse);
      expect(form.text.text, 'Keep this draft across both toggles');
      expect(harness.ledger.created, hasLength(2));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/19:'))),
      );
      expect(form.taps, 1);

      await tester.pumpAndSettle();
      harness.router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_opacity(tester, form), inExclusiveRange(0.0, 1.0));
      expect(_translation(tester, form).dy, inExclusiveRange(0.0, 16.01));
      await tester.pumpAndSettle();
      await completed;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turning reduced motion off during exit cannot resurrect the exiting page',
    (tester) async {
      final harness = await _pumpHarness(tester);
      final original = harness.ledger.created.single;
      final completed = harness.router.push<void>('/25?taskId=first');
      await tester.pumpAndSettle();
      final detail = harness.ledger.created.last;
      detail.text.text = 'Retain until disposal';
      harness.router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_opacity(tester, detail), inExclusiveRange(0.0, 1.0));
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      expect(find.byWidget(detail.widget), findsNothing);
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
      );
      await tester.pump();
      expect(find.byWidget(detail.widget), findsNothing);
      expect(detail.text.text, 'Retain until disposal');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/04:'))),
      );
      expect(original.taps, 1);
      expect(detail.taps, 0);
      await tester.pumpAndSettle();
      await completed;

      final nextCompleted = harness.router.push<void>('/25?taskId=second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final next = harness.ledger.created.last;
      expect(_opacity(tester, next), inExclusiveRange(0.0, 1.0));
      expect(_translation(tester, next).dx, inExclusiveRange(0.0, 18.01));
      expect(_absorber(tester, next).absorbing, isTrue);
      await tester.pumpAndSettle();
      harness.router.pop();
      await tester.pumpAndSettle();
      await nextCompleted;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a real modal remains interactive while its background is excluded and restores the form',
    (tester) async {
      final harness = await _pumpHarness(tester, initialLocation: '/19');
      final form = harness.ledger.created.single;
      form.text.text = 'Unsaved background input';
      var modalActions = 0;
      final completed = showDialog<bool>(
        context: form.context,
        barrierDismissible: false,
        animationStyle: SeraMotion.dialogStyle(form.context),
        builder: (context) => AlertDialog(
          content: const Text('Modal content'),
          actions: [
            TextButton(
              key: const ValueKey('modal-action'),
              onPressed: () {
                modalActions += 1;
                Navigator.of(context).pop(true);
              },
              child: const Text('Complete modal'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(_opacity(tester, form), 1);
      expect(_absorber(tester, form).absorbing, isTrue);
      final semantics = tester.widget<ExcludeSemantics>(
        find
            .descendant(
              of: _transitionFor(form),
              matching: find.byType(ExcludeSemantics),
            )
            .first,
      );
      expect(semantics.excluding, isTrue);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/19:'))),
      );
      expect(form.taps, 0);
      expect(find.text('Modal content'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modal-action')));
      await tester.pumpAndSettle();
      expect(await completed, isTrue);
      expect(modalActions, 1);
      expect(form.text.text, 'Unsaved background input');
      expect(_absorber(tester, form).absorbing, isFalse);
      expect(harness.ledger.created, hasLength(1));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tap-/19:'))),
      );
      expect(form.taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _transitionFor(_ProbePageState page) => find.ancestor(
  of: find.byWidget(page.widget),
  matching: find.byType(SeraRouteTransition),
);

Finder _clipFor(_ProbePageState page) => find
    .descendant(of: _transitionFor(page), matching: find.byType(ClipRect))
    .first;

double _opacity(WidgetTester tester, _ProbePageState page) => tester
    .widget<Opacity>(
      find
          .descendant(of: _transitionFor(page), matching: find.byType(Opacity))
          .first,
    )
    .opacity;

Offset _translation(WidgetTester tester, _ProbePageState page) {
  final transform = tester
      .widget<Transform>(
        find
            .descendant(
              of: _transitionFor(page),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform;
  return Offset(transform.storage[12], transform.storage[13]);
}

AbsorbPointer _absorber(WidgetTester tester, _ProbePageState page) =>
    tester.widget<AbsorbPointer>(
      find
          .descendant(
            of: _transitionFor(page),
            matching: find.byType(AbsorbPointer),
          )
          .first,
    );

Future<_Harness> _pumpHarness(
  WidgetTester tester, {
  String initialLocation = '/04',
}) async {
  final ledger = _PageLedger();
  final environment = ValueNotifier(const MediaQueryData());
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/:screen',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: _ProbePage(
            ledger: ledger,
            label:
                '${state.uri.path}:${state.uri.queryParameters['taskId'] ?? ''}',
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(environment.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => ColoredBox(
        color: const Color(0xffe9eeeb),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(constraints.maxWidth, 430.0);
            return Center(
              child: SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: ValueListenableBuilder<MediaQueryData>(
                  valueListenable: environment,
                  builder: (context, data, _) => MediaQuery(
                    data: data.copyWith(
                      size: Size(width, constraints.maxHeight),
                    ),
                    child: ClipRect(child: child ?? const SizedBox.shrink()),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(router: router, ledger: ledger, environment: environment);
}

class _Harness {
  _Harness({
    required this.router,
    required this.ledger,
    required this.environment,
  });
  final GoRouter router;
  final _PageLedger ledger;
  final ValueNotifier<MediaQueryData> environment;
}

class _PageLedger {
  final created = <_ProbePageState>[];
  final disposed = <_ProbePageState>[];
}

class _ProbePage extends StatefulWidget {
  const _ProbePage({required this.ledger, required this.label});
  final _PageLedger ledger;
  final String label;

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  final text = TextEditingController();
  final scroll = ScrollController();
  final focus = FocusNode();
  var taps = 0;

  @override
  void initState() {
    super.initState();
    widget.ledger.created.add(this);
  }

  @override
  void dispose() {
    widget.ledger.disposed.add(this);
    text.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text(widget.label),
        TextField(
          key: ValueKey('draft-${widget.label}'),
          controller: text,
          focusNode: focus,
        ),
        FilledButton(
          key: ValueKey('tap-${widget.label}'),
          onPressed: () => taps += 1,
          child: const Text('Action'),
        ),
        Expanded(
          child: ListView.builder(
            key: ValueKey('list-${widget.label}'),
            controller: scroll,
            itemExtent: 40,
            itemCount: 80,
            itemBuilder: (context, index) => Text('Item $index'),
          ),
        ),
      ],
    ),
  );
}
