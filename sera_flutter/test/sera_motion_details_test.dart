import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_theme.dart';

void main() {
  testWidgets(
    'native date picker validates format and selectable days before returning the date',
    (tester) async {
      final harness = await _pumpDetails(tester);
      final completed = SeraMotion.pickDate(
        context: harness.context,
        initialDate: DateTime(2026, 10, 31),
        currentDate: DateTime(2026, 10, 31),
        firstDate: DateTime(2026, 10, 1),
        lastDate: DateTime(2026, 11, 30),
        selectableDayPredicate: (date) => date.day != 2,
        initialEntryMode: DatePickerEntryMode.input,
        helpText: 'Select a synthetic date',
        confirmText: 'Apply date',
        cancelText: 'Cancel date',
      );
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(find.text('Select a synthetic date'), findsOneWidget);
      final localizations = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      final input = find
          .descendant(
            of: find.byType(DatePickerDialog),
            matching: find.byType(TextFormField),
          )
          .first;
      await tester.enterText(input, 'invalid');
      await _tapPickerAction(tester, 'Apply date');
      expect(find.text(localizations.invalidDateFormatLabel), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsOneWidget);

      await tester.enterText(
        input,
        localizations.formatCompactDate(DateTime(2026, 11, 2)),
      );
      await _tapPickerAction(tester, 'Apply date');
      expect(find.text(localizations.dateOutOfRangeLabel), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.enterText(
        input,
        localizations.formatCompactDate(DateTime(2026, 11, 5)),
      );
      await _tapPickerAction(tester, 'Apply date');
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(await completed, DateTime(2026, 11, 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced native date picker has zero transition and cancellation returns null',
    (tester) async {
      final harness = await _pumpDetails(tester, reduced: true);
      final completed = SeraMotion.pickDate(
        context: harness.context,
        initialDate: DateTime(2026, 10, 31),
        firstDate: DateTime(2026, 10, 1),
        lastDate: DateTime(2026, 11, 30),
        cancelText: 'Cancel date',
      );
      await tester.pump();
      final route = ModalRoute.of(
        tester.element(find.byType(DatePickerDialog)),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(route.animation!.value, 1);
      await _tapPickerAction(tester, 'Cancel date');
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(await completed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an existing date beyond the default range is displayed unchanged and can be cancelled',
    (tester) async {
      final harness = await _pumpDetails(tester);
      final original = DateTime(2052, 7, 18);
      final completed = SeraMotion.pickDate(
        context: harness.context,
        initialDate: original,
        firstDate: DateTime(2020),
        lastDate: DateTime(2040, 12, 31),
        cancelText: 'Cancel future date',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.initialDate, original);
      expect(picker.lastDate.isBefore(original), isFalse);
      expect(picker.firstDate.isAfter(original), isFalse);
      expect(find.textContaining('2052'), findsWidgets);
      await _tapPickerAction(tester, 'Cancel future date');
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(await completed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native time picker rejects invalid input then returns the edited time',
    (tester) async {
      final harness = await _pumpDetails(tester);
      final completed = SeraMotion.pickTime(
        context: harness.context,
        initialTime: const TimeOfDay(hour: 9, minute: 15),
        initialEntryMode: TimePickerEntryMode.input,
        helpText: '选择时间',
        confirmText: '确定',
        cancelText: '取消',
      );
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(
        MediaQuery.alwaysUse24HourFormatOf(
          tester.element(find.byType(TimePickerDialog)),
        ),
        isTrue,
      );
      final localizations = MaterialLocalizations.of(
        tester.element(find.byType(TimePickerDialog)),
      );
      final inputs = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextFormField),
      );
      expect(inputs, findsNWidgets(2));
      await tester.enterText(inputs.at(0), '99');
      await tester.enterText(inputs.at(1), '99');
      await _tapPickerAction(tester, '确定');
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(find.text(localizations.invalidTimeLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(inputs.at(0), '16');
      await tester.enterText(inputs.at(1), '45');
      await _tapPickerAction(tester, '确定');
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(await completed, const TimeOfDay(hour: 16, minute: 45));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced native time picker has zero transition and cancellation returns null',
    (tester) async {
      final harness = await _pumpDetails(tester, reduced: true);
      final completed = SeraMotion.pickTime(
        context: harness.context,
        initialTime: const TimeOfDay(hour: 9, minute: 15),
        cancelText: 'Cancel time',
      );
      await tester.pump();
      final route = ModalRoute.of(
        tester.element(find.byType(TimePickerDialog)),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(route.animation!.value, 1);
      await _tapPickerAction(tester, 'Cancel time');
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(await completed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'motion scope gives an actual disclosure a compact intermediate height',
    (tester) async {
      final harness = await _pumpDetails(tester);
      final tile = find.byType(ExpansionTile);
      final style = ExpansionTileTheme.of(harness.context)
          .expansionAnimationStyle!;
      expect(style.duration, const Duration(milliseconds: 160));
      final closedHeight = tester.getSize(tile).height;
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final middleHeight = tester.getSize(tile).height;
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(tile).height;
      expect(middleHeight, greaterThan(closedHeight));
      expect(middleHeight, lessThan(expandedHeight));
      expect(find.byKey(const ValueKey('scope-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope settings and engine reduceMotion preserve a maintained child form and release observers',
    (tester) async {
      final harness = await _pumpDetails(tester, expanded: true);
      final original = harness.draftKey.currentState!;
      await tester.enterText(
        find.byKey(const ValueKey('scope-input')),
        'Maintained form input',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      expect(harness.draftKey.currentState, same(original));
      expect(
        ExpansionTileTheme.of(harness.context)
            .expansionAnimationStyle!
            .duration,
        Duration.zero,
      );
      final expandedHeight = tester.getSize(find.byType(ExpansionTile)).height;
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      final closedHeight = tester.getSize(find.byType(ExpansionTile)).height;
      expect(closedHeight, lessThan(expandedHeight));
      expect(find.byKey(const ValueKey('scope-input')), findsNothing);
      expect(harness.draftKey.currentState, same(original));
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      expect(
        tester.getSize(find.byType(ExpansionTile)).height,
        closeTo(expandedHeight, 0.01),
      );
      expect(original.text.text, 'Maintained form input');
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
      );
      await tester.pump();
      expect(
        ExpansionTileTheme.of(harness.context)
            .expansionAnimationStyle!
            .duration,
        const Duration(milliseconds: 160),
      );

      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pump();
      expect(
        ExpansionTileTheme.of(harness.context)
            .expansionAnimationStyle!
            .duration,
        Duration.zero,
      );
      expect(harness.draftKey.currentState, same(original));
      expect(original.text.text, 'Maintained form input');
      await tester.pumpWidget(const SizedBox.shrink());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'banner height animates and reverses without rebuilding the business subtree',
    (tester) async {
      final harness = await _pumpBanner(tester);
      final business = harness.businessKey.currentState!;
      business.text.text = 'Stable router-side input';
      final initialBuilds = harness.counter.builds;
      final banner = find.byType(SeraBannerTransition);
      expect(tester.getSize(banner).height, 0);
      harness.visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final enteringHeight = tester.getSize(banner).height;
      expect(enteringHeight, inExclusiveRange(0.0, 60.0));
      harness.visible.value = false;
      await tester.pump();
      expect(tester.getSize(banner).height, closeTo(enteringHeight, 0.01));
      final ignore = tester.widget<IgnorePointer>(
        find.descendant(of: banner, matching: find.byType(IgnorePointer)).first,
      );
      final semantics = tester.widget<ExcludeSemantics>(
        find
            .descendant(of: banner, matching: find.byType(ExcludeSemantics))
            .first,
      );
      final focus = tester.widget<ExcludeFocus>(
        find.descendant(of: banner, matching: find.byType(ExcludeFocus)).first,
      );
      expect(ignore.ignoring, isTrue);
      expect(semantics.excluding, isTrue);
      expect(focus.excluding, isTrue);
      await tester.pump(const Duration(milliseconds: 15));
      final returningHeight = tester.getSize(banner).height;
      expect(returningHeight, lessThan(enteringHeight));
      harness.visible.value = true;
      await tester.pump();
      expect(tester.getSize(banner).height, closeTo(returningHeight, 0.01));
      await tester.pumpAndSettle();
      expect(tester.getSize(banner).height, 60);
      expect(harness.businessKey.currentState, same(business));
      expect(harness.counter.initializations, 1);
      expect(harness.counter.builds, initialBuilds);
      expect(business.text.text, 'Stable router-side input');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'banner completes reduced motion immediately and does not rewind when it is disabled',
    (tester) async {
      final harness = await _pumpBanner(tester);
      final banner = find.byType(SeraBannerTransition);
      final business = harness.businessKey.currentState!;
      harness.visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(banner).height, inExclusiveRange(0.0, 60.0));
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      expect(tester.getSize(banner).height, 60);
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(banner).height, 60);
      harness.visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(banner).height, inExclusiveRange(0.0, 60.0));
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      expect(tester.getSize(banner).height, 0);
      harness.environment.value = harness.environment.value.copyWith(
        disableAnimations: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(banner).height, 0);
      expect(harness.businessKey.currentState, same(business));
      expect(harness.counter.initializations, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tapPickerAction(WidgetTester tester, String label) async {
  // Validation can remove an error row and move the actions. Resolve the
  // button only after that layout has settled, never at its stale position.
  await tester.pumpAndSettle();
  final action = find.text(label).hitTestable();
  expect(action, findsOneWidget);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<_DetailsHarness> _pumpDetails(
  WidgetTester tester, {
  bool reduced = false,
  bool expanded = false,
}) async {
  final environment = ValueNotifier(MediaQueryData(disableAnimations: reduced));
  final draftKey = GlobalKey<_DisclosureDraftState>();
  addTearDown(environment.dispose);
  await tester.pumpWidget(
    MaterialApp(
      // Match SeraApp's real locale/theme. The test-only Ahem font makes the
      // default English error wrap inside Flutter's fixed-height input picker.
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => ValueListenableBuilder<MediaQueryData>(
        valueListenable: environment,
        builder: (context, data, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: data.disableAnimations,
            accessibleNavigation: data.accessibleNavigation,
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        ),
      ),
      home: SeraMotionScope(
        child: Scaffold(
          body: SingleChildScrollView(
            child: ExpansionTile(
              title: const Text('Advanced'),
              initiallyExpanded: expanded,
              maintainState: true,
              children: [_DisclosureDraft(key: draftKey)],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _DetailsHarness(
    context: tester.element(find.byType(ExpansionTile)),
    environment: environment,
    draftKey: draftKey,
  );
}

class _DetailsHarness {
  _DetailsHarness({
    required this.context,
    required this.environment,
    required this.draftKey,
  });
  final BuildContext context;
  final ValueNotifier<MediaQueryData> environment;
  final GlobalKey<_DisclosureDraftState> draftKey;
}

class _DisclosureDraft extends StatefulWidget {
  const _DisclosureDraft({super.key});
  @override
  State<_DisclosureDraft> createState() => _DisclosureDraftState();
}

class _DisclosureDraftState extends State<_DisclosureDraft> {
  final text = TextEditingController();
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 160,
    child: TextField(key: const ValueKey('scope-input'), controller: text),
  );
}

Future<_BannerHarness> _pumpBanner(WidgetTester tester) async {
  final visible = ValueNotifier(false);
  final environment = ValueNotifier(const MediaQueryData());
  final businessKey = GlobalKey<_BusinessBodyState>();
  final counter = _BuildCounter();
  addTearDown(visible.dispose);
  addTearDown(environment.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ValueListenableBuilder<MediaQueryData>(
        valueListenable: environment,
        builder: (context, data, _) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: data.disableAnimations),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Column(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, value, child) =>
                  SeraBannerTransition(visible: value, child: child!),
              child: const SizedBox(height: 60, child: Text('Sync status')),
            ),
            Expanded(
              child: _BusinessBody(key: businessKey, counter: counter),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _BannerHarness(
    visible: visible,
    environment: environment,
    businessKey: businessKey,
    counter: counter,
  );
}

class _BannerHarness {
  _BannerHarness({
    required this.visible,
    required this.environment,
    required this.businessKey,
    required this.counter,
  });
  final ValueNotifier<bool> visible;
  final ValueNotifier<MediaQueryData> environment;
  final GlobalKey<_BusinessBodyState> businessKey;
  final _BuildCounter counter;
}

class _BuildCounter {
  var initializations = 0;
  var builds = 0;
}

class _BusinessBody extends StatefulWidget {
  const _BusinessBody({super.key, required this.counter});
  final _BuildCounter counter;
  @override
  State<_BusinessBody> createState() => _BusinessBodyState();
}

class _BusinessBodyState extends State<_BusinessBody> {
  final text = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.counter.initializations += 1;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.counter.builds += 1;
    return TextField(controller: text);
  }
}
