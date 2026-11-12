import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_theme.dart';

void main() {
  for (final size in const [Size(320, 568), Size(430, 600)]) {
    for (final bottomInset in [0.0, 260.0, 320.0]) {
      final scenario =
          '${size.width.toInt()}x${size.height.toInt()} inset ${bottomInset.toInt()}';
      testWidgets('native pickers validate, confirm and cancel at $scenario', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
        });

        final hostKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: seraTheme(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            // Match SeraApp: the Navigator is inside the centered 430 px
            // container, its same-width MediaQuery and the clipping boundary.
            builder: (context, child) => LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth.clamp(0.0, 430.0);
                return Center(
                  child: SizedBox(
                    width: width,
                    height: constraints.maxHeight,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: Size(width, constraints.maxHeight),
                        // DialogRoute's native SafeArea consumes this top
                        // padding. Do not add a second outer SafeArea.
                        padding: const EdgeInsets.only(top: 24),
                        viewPadding: const EdgeInsets.only(top: 24),
                        viewInsets: EdgeInsets.only(bottom: bottomInset),
                        alwaysUse24HourFormat: true,
                      ),
                      child: SeraMotionScope(
                        child: ClipRect(
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            home: Scaffold(key: hostKey, body: const Text('隔离时间选择器测试')),
          ),
        );
        _expectNoException(tester, '$scenario host first frame');
        await _settleChecked(tester, '$scenario host');
        final hostContext = hostKey.currentContext!;
        expect(Theme.of(hostContext).platform, TargetPlatform.android);
        expect(MediaQuery.sizeOf(hostContext), size);
        expect(MediaQuery.paddingOf(hostContext).top, 24);
        expect(MediaQuery.viewInsetsOf(hostContext).bottom, bottomInset);

        final confirmed = _openPicker(hostContext);
        await _pumpChecked(
          tester,
          Duration.zero,
          '$scenario picker first frame',
        );
        await _pumpChecked(
          tester,
          const Duration(milliseconds: 16),
          '$scenario picker entering frame',
        );
        await _settleChecked(tester, '$scenario picker entered');
        expect(find.byType(TimePickerDialog), findsOneWidget);
        final dialogContext = tester.element(find.byType(TimePickerDialog));
        expect(MediaQuery.alwaysUse24HourFormatOf(dialogContext), isTrue);
        final invalidTime = MaterialLocalizations.of(dialogContext)
            .invalidTimeLabel;
        final inputs = find.descendant(
          of: find.byType(TimePickerDialog),
          matching: find.byType(TextFormField),
        );
        expect(inputs, findsNWidgets(2));

        await _enterChecked(
          tester,
          inputs.at(0),
          '99',
          '$scenario invalid hour',
        );
        await _enterChecked(
          tester,
          inputs.at(1),
          '99',
          '$scenario invalid minute',
        );
        await _tapAction(tester, '确定', '$scenario reject invalid time');
        expect(find.byType(TimePickerDialog), findsOneWidget);
        expect(find.text(invalidTime), findsOneWidget);
        expect(confirmed.arrived, isFalse);
        _expectNoException(tester, '$scenario invalid result');

        await _enterChecked(tester, inputs.at(0), '16', '$scenario valid hour');
        await _enterChecked(
          tester,
          inputs.at(1),
          '45',
          '$scenario valid minute',
        );
        await _tapAction(tester, '确定', '$scenario confirm valid time');
        expect(find.byType(TimePickerDialog), findsNothing);
        await _expectResultArrived(
          tester,
          confirmed,
          '$scenario confirm result',
        );
        expect(confirmed.value, const TimeOfDay(hour: 16, minute: 45));
        _expectNoException(tester, '$scenario confirmed');

        final cancelled = _openPicker(hostContext);
        await _pumpChecked(
          tester,
          Duration.zero,
          '$scenario cancel picker first frame',
        );
        await _pumpChecked(
          tester,
          const Duration(milliseconds: 16),
          '$scenario cancel picker entering frame',
        );
        await _settleChecked(tester, '$scenario cancel picker entered');
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await _tapAction(tester, '取消', '$scenario cancel time');
        expect(find.byType(TimePickerDialog), findsNothing);
        await _expectResultArrived(
          tester,
          cancelled,
          '$scenario cancel result',
        );
        expect(cancelled.value, isNull);
        _expectNoException(tester, '$scenario cancelled');

        final dateConfirmed = _openDatePicker(hostContext);
        await _pumpChecked(tester, Duration.zero, '$scenario date first frame');
        await _pumpChecked(
          tester,
          const Duration(milliseconds: 16),
          '$scenario date entering frame',
        );
        await _settleChecked(tester, '$scenario date entered');
        expect(find.byType(DatePickerDialog), findsOneWidget);
        final dateLocalizations = MaterialLocalizations.of(
          tester.element(find.byType(DatePickerDialog)),
        );
        final dateInput = find
            .descendant(
              of: find.byType(DatePickerDialog),
              matching: find.byType(TextFormField),
            )
            .first;
        await _enterChecked(
          tester,
          dateInput,
          'invalid',
          '$scenario invalid date',
        );
        await _tapAction(
          tester,
          '确定',
          '$scenario reject invalid date',
          pickerType: DatePickerDialog,
        );
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(
          find.text(dateLocalizations.invalidDateFormatLabel),
          findsOneWidget,
        );
        expect(dateConfirmed.arrived, isFalse);
        _expectNoException(tester, '$scenario invalid date result');
        final selectedDate = DateTime(2026, 11, 5);
        await _enterChecked(
          tester,
          dateInput,
          dateLocalizations.formatCompactDate(selectedDate),
          '$scenario valid date',
        );
        await _tapAction(
          tester,
          '确定',
          '$scenario confirm valid date',
          pickerType: DatePickerDialog,
        );
        expect(find.byType(DatePickerDialog), findsNothing);
        await _expectResultArrived(
          tester,
          dateConfirmed,
          '$scenario date confirm result',
        );
        expect(dateConfirmed.value, selectedDate);
        _expectNoException(tester, '$scenario date confirmed');

        final dateCancelled = _openDatePicker(hostContext);
        await _pumpChecked(
          tester,
          Duration.zero,
          '$scenario cancel date first frame',
        );
        await _pumpChecked(
          tester,
          const Duration(milliseconds: 16),
          '$scenario cancel date entering frame',
        );
        await _settleChecked(tester, '$scenario cancel date entered');
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await _tapAction(
          tester,
          '取消',
          '$scenario cancel date',
          pickerType: DatePickerDialog,
        );
        expect(find.byType(DatePickerDialog), findsNothing);
        await _expectResultArrived(
          tester,
          dateCancelled,
          '$scenario date cancel result',
        );
        expect(dateCancelled.value, isNull);
        _expectNoException(tester, '$scenario date cancelled');
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }
  testWidgets(
    'picker card captures inside taps while its outside barrier cancels without reaching the host',
    (tester) async {
      final host = await _mountDynamicHost(tester, const Size(430, 700));
      final result = _openPicker(host.context);
      await _pumpChecked(tester, Duration.zero, 'barrier picker first frame');
      await _pumpChecked(
        tester,
        const Duration(milliseconds: 16),
        'barrier picker entering frame',
      );
      await _settleChecked(tester, 'barrier picker entered');
      final card = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      );
      expect(card, findsOneWidget);
      await tester.ensureVisible(card);
      await _settleChecked(tester, 'native card visible');
      expect(card.hitTestable(), findsOneWidget);
      // A Dialog's render box spans the viewport. Measure its native card
      // Material instead, then tap its inert top padding inside the surface.
      final cardRect = tester.getRect(card);
      expect(cardRect.width, lessThan(430));
      expect(cardRect.height, lessThan(676));
      expect(cardRect.center.dx, closeTo(215, 1));
      expect(cardRect.center.dy, closeTo(362, 1));
      final inside = Offset(cardRect.center.dx, cardRect.top + 6);
      expect(cardRect.contains(inside), isTrue);
      await tester.tapAt(inside);
      await _pumpChecked(tester, Duration.zero, 'inside card tap');
      await _settleChecked(tester, 'inside card tap settled');
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(result.arrived, isFalse);
      expect(host.tapCount.value, 0);

      const outside = Offset(4, 100);
      expect(cardRect.contains(outside), isFalse);
      await tester.tapAt(outside);
      await _pumpChecked(tester, Duration.zero, 'outside barrier tap');
      await _pumpChecked(
        tester,
        const Duration(milliseconds: 16),
        'outside barrier exiting frame',
      );
      await _settleChecked(tester, 'outside barrier dismissed');
      expect(find.byType(TimePickerDialog), findsNothing);
      await _expectResultArrived(tester, result, 'outside barrier result');
      expect(result.value, isNull);
      expect(host.tapCount.value, 0);
      _expectNoException(tester, 'barrier complete');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'keyboard inset changes preserve the native picker state, invalid input and entry mode',
    (tester) async {
      final host = await _mountDynamicHost(tester, const Size(320, 568));
      final result = _openPicker(host.context);
      await _pumpChecked(tester, Duration.zero, 'dynamic picker first frame');
      await _pumpChecked(
        tester,
        const Duration(milliseconds: 16),
        'dynamic picker entering frame',
      );
      await _settleChecked(tester, 'dynamic picker entered');
      final picker = find.byType(TimePickerDialog);
      final originalState = tester.state(picker);
      final localizations = MaterialLocalizations.of(tester.element(picker));
      final invalidTime = localizations.invalidTimeLabel;
      final dialTooltip = localizations.dialModeButtonLabel;
      final inputs = find.descendant(
        of: picker,
        matching: find.byType(TextFormField),
      );
      expect(inputs, findsNWidgets(2));
      final hourState = tester.state(inputs.at(0));
      final minuteState = tester.state(inputs.at(1));
      await _enterChecked(tester, inputs.at(0), '99', 'dynamic invalid hour');
      await _enterChecked(tester, inputs.at(1), '99', 'dynamic invalid minute');
      await _tapAction(tester, '确定', 'dynamic reject invalid time');
      expect(find.text(invalidTime), findsOneWidget);
      expect(result.arrived, isFalse);

      for (final inset in [320.0, 0.0]) {
        host.inset.value = inset;
        await _pumpChecked(
          tester,
          Duration.zero,
          'dynamic inset $inset first frame',
        );
        await _pumpChecked(
          tester,
          const Duration(milliseconds: 16),
          'dynamic inset $inset intermediate frame',
        );
        await _settleChecked(tester, 'dynamic inset $inset settled');
        expect(tester.state(picker), same(originalState));
        expect(inputs, findsNWidgets(2));
        expect(tester.state(inputs.at(0)), same(hourState));
        expect(tester.state(inputs.at(1)), same(minuteState));
        expect(
          tester.widget<TextFormField>(inputs.at(0)).controller!.text,
          '99',
        );
        expect(
          tester.widget<TextFormField>(inputs.at(1)).controller!.text,
          '99',
        );
        expect(find.text(invalidTime), findsOneWidget);
        expect(find.byTooltip(dialTooltip), findsOneWidget);
        expect(result.arrived, isFalse);
        _expectNoException(tester, 'dynamic inset $inset preserved');
      }

      await _enterChecked(tester, inputs.at(0), '16', 'dynamic valid hour');
      await _enterChecked(tester, inputs.at(1), '45', 'dynamic valid minute');
      await _tapAction(tester, '确定', 'dynamic confirm valid time');
      expect(picker, findsNothing);
      await _expectResultArrived(tester, result, 'dynamic confirm result');
      expect(result.value, const TimeOfDay(hour: 16, minute: 45));
      expect(host.tapCount.value, 0);
      _expectNoException(tester, 'dynamic complete');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

Future<_DynamicHost> _mountDynamicHost(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  final host = _DynamicHost();
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(host.inset.dispose);
  addTearDown(host.tapCount.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.clamp(0.0, 430.0);
          return Center(
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: ValueListenableBuilder<double>(
                valueListenable: host.inset,
                builder: (context, inset, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: Size(width, constraints.maxHeight),
                    padding: const EdgeInsets.only(top: 24),
                    viewPadding: const EdgeInsets.only(top: 24),
                    viewInsets: EdgeInsets.only(bottom: inset),
                    alwaysUse24HourFormat: true,
                  ),
                  child: SeraMotionScope(
                    child: ClipRect(child: child ?? const SizedBox.shrink()),
                  ),
                ),
              ),
            ),
          );
        },
      ),
      home: Scaffold(
        key: host.key,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => host.tapCount.value += 1,
          child: const SizedBox.expand(child: Text('隔离选择器背景')),
        ),
      ),
    ),
  );
  _expectNoException(tester, 'dynamic host first frame');
  await _settleChecked(tester, 'dynamic host');
  expect(Theme.of(host.context).platform, TargetPlatform.android);
  expect(MediaQuery.sizeOf(host.context), size);
  expect(MediaQuery.paddingOf(host.context).top, 24);
  return host;
}

class _DynamicHost {
  final key = GlobalKey();
  final inset = ValueNotifier(0.0);
  final tapCount = ValueNotifier(0);
  BuildContext get context => key.currentContext!;
}

_PickerResult<TimeOfDay> _openPicker(BuildContext context) {
  final result = _PickerResult<TimeOfDay>();
  unawaited(
    SeraMotion.pickTime(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 15),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: '选择时间',
      confirmText: '确定',
      cancelText: '取消',
    ).then<void>(result.complete),
  );
  return result;
}

_PickerResult<DateTime> _openDatePicker(BuildContext context) {
  final result = _PickerResult<DateTime>();
  unawaited(
    SeraMotion.pickDate(
      context: context,
      initialDate: DateTime(2026, 10, 31),
      currentDate: DateTime(2026, 10, 31),
      firstDate: DateTime(2026, 10, 1),
      lastDate: DateTime(2026, 11, 30),
      initialEntryMode: DatePickerEntryMode.input,
      helpText: '选择日期',
      confirmText: '确定',
      cancelText: '取消',
    ).then<void>(result.complete),
  );
  return result;
}

Future<void> _enterChecked(
  WidgetTester tester,
  Finder input,
  String text,
  String stage,
) async {
  await tester.ensureVisible(input);
  await _settleChecked(tester, '$stage visible');
  expect(input.hitTestable(), findsOneWidget, reason: stage);
  _expectAboveKeyboard(tester, input, stage);
  await tester.enterText(input, text);
  await _pumpChecked(tester, Duration.zero, '$stage changed');
  await _settleChecked(tester, '$stage settled');
}

Future<void> _tapAction(
  WidgetTester tester,
  String label,
  String stage, {
  Type pickerType = TimePickerDialog,
}) async {
  await _settleChecked(tester, '$stage before action');
  final button = find.descendant(
    of: find.byType(pickerType),
    matching: find.widgetWithText(TextButton, label),
  );
  expect(button, findsOneWidget, reason: stage);
  await tester.ensureVisible(button);
  await _settleChecked(tester, '$stage action visible');
  final hittable = button.hitTestable();
  expect(hittable, findsOneWidget, reason: stage);
  _expectAboveKeyboard(tester, button, stage, wholeControl: true);
  await tester.tap(hittable);
  await _pumpChecked(tester, Duration.zero, '$stage first frame');
  await _pumpChecked(
    tester,
    const Duration(milliseconds: 16),
    '$stage intermediate frame',
  );
  await _settleChecked(tester, '$stage completed');
}

void _expectAboveKeyboard(
  WidgetTester tester,
  Finder control,
  String stage, {
  bool wholeControl = false,
}) {
  // Read outside the native Dialog: it removes viewInsets after applying its
  // own padding. Hit testing alone cannot simulate an actual OS keyboard.
  final root = tester.element(find.byType(SeraMotionScope).first);
  final media = MediaQuery.of(root);
  final visibleBottom = media.size.height - media.viewInsets.bottom;
  final rect = tester.getRect(control);
  if (wholeControl) {
    expect(
      rect.top,
      greaterThanOrEqualTo(media.padding.top - 1),
      reason: '$stage action top',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(visibleBottom + 1),
      reason: '$stage action above keyboard',
    );
  } else {
    // A constrained viewport may show only the critical input area, but the
    // field's actual center must remain inside the unobscured window.
    expect(
      rect.center.dy,
      greaterThanOrEqualTo(media.padding.top - 1),
      reason: '$stage input center top',
    );
    expect(
      rect.center.dy,
      lessThanOrEqualTo(visibleBottom + 1),
      reason: '$stage input center above keyboard',
    );
    expect(
      rect.center.dx,
      greaterThanOrEqualTo(media.padding.left - 1),
      reason: '$stage input center left',
    );
    expect(
      rect.center.dx,
      lessThanOrEqualTo(media.size.width - media.padding.right + 1),
      reason: '$stage input center right',
    );
  }
}

Future<void> _pumpChecked(
  WidgetTester tester,
  Duration duration,
  String stage,
) async {
  await tester.pump(duration);
  _expectNoException(tester, stage);
}

Future<void> _settleChecked(WidgetTester tester, String stage) async {
  // Each rendered frame is checked. A pending result cannot turn this into
  // an unbounded wait, and a transient overflow cannot be hidden by settling.
  for (var frame = 0; frame < 80; frame += 1) {
    await _pumpChecked(
      tester,
      const Duration(milliseconds: 16),
      '$stage frame $frame',
    );
    if (!tester.binding.hasScheduledFrame) {
      return;
    }
  }
  fail('$stage did not settle within 80 frames');
}

Future<void> _expectResultArrived<T>(
  WidgetTester tester,
  _PickerResult<T> result,
  String stage,
) async {
  // The caller must already have asserted that the native dialog is gone.
  // Observe the returned Future with bounded pumps instead of awaiting a
  // potentially unresolved result after a missed action.
  for (var frame = 0; frame < 20 && !result.arrived; frame += 1) {
    await _pumpChecked(
      tester,
      const Duration(milliseconds: 16),
      '$stage result frame $frame',
    );
  }
  expect(result.arrived, isTrue, reason: stage);
}

void _expectNoException(WidgetTester tester, String stage) {
  expect(tester.takeException(), isNull, reason: stage);
}

class _PickerResult<T> {
  bool arrived = false;
  T? value;

  void complete(T? result) {
    value = result;
    arrived = true;
  }
}
