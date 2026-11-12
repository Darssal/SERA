import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _channel = MethodChannel('com.sera/platform');

void _densityTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _DensityStore implements WorkspaceRepository {
  _DensityStore(this.value);

  Workspace? value;
  int writes = 0;

  @override
  String get mode => 'ui-density-test';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if ((value?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('工作区已被其他操作修改', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  SeraController controller,
  String path,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    SeraApp(key: UniqueKey(), controller: controller, initialLocation: path),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = DateTime(2026, 10, 28);
  final calls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'capabilities':
              return {
                'platform': 'android',
                'calendarSupported': false,
                'notificationsSupported': true,
                'backgroundNotifications': true,
                'recordingSupported': false,
                'calendarPermission': 'denied',
                'notificationPermission': 'granted',
                'microphonePermission': 'denied',
                'exactAlarmsSupported': false,
              };
            case 'scheduledNotifications':
              return <Map<String, dynamic>>[];
            case 'requestPermission':
              return 'granted';
            case 'showTestNotification':
              throw PlatformException(
                code: 'delivery_failed',
                message: '测试用系统拒绝了这次提醒',
              );
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  _densityTest(
    'disclosure retains an uncontrolled form value and validation after closing',
    (tester) async {
      final formKey = GlobalKey<FormState>();
      const inputKey = ValueKey('secondary-form-input');
      await tester.pumpWidget(
        MaterialApp(
          theme: seraTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SeraDisclosure(
                title: 'Secondary details',
                children: [
                  Form(
                    key: formKey,
                    child: TextFormField(
                      key: inputKey,
                      initialValue: 'initial value',
                      validator: (value) =>
                          value == 'valid' ? null : 'Correct this value',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(inputKey), findsNothing);

      await _tap(tester, find.text('Secondary details'));
      await tester.enterText(find.byKey(inputKey), 'unfinished value');
      final mountedForm = formKey.currentState;
      expect(mountedForm!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('Correct this value'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();

      await _tap(tester, find.text('Secondary details'));
      expect(find.byKey(inputKey), findsNothing);
      expect(find.byKey(inputKey, skipOffstage: false), findsOneWidget);
      expect(formKey.currentState, same(mountedForm));

      await _tap(tester, find.text('Secondary details'));
      final editable = find.descendant(
        of: find.byKey(inputKey),
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'unfinished value',
      );
      expect(find.text('Correct this value'), findsOneWidget);
      await tester.enterText(find.byKey(inputKey), 'valid');
      expect(formKey.currentState!.validate(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Correct this value'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  _densityTest(
    'preferences save the reviewed zone and visible privacy switch after folding',
    (tester) async {
      const original = SeraPreferences(
        restStart: 690,
        restEnd: 765,
        quietStart: 1290,
        quietEnd: 450,
        notifications: false,
        followUp: false,
      );
      final store = _DensityStore(
        const Workspace(revision: 1, preferences: original),
      );
      final controller = SeraController(repository: store, today: today);
      await controller.initialize();
      await _pump(tester, controller, '/31');
      final initialWrites = store.writes;
      final privacy = find.byType(SwitchListTile);
      expect(privacy, findsOneWidget);
      expect(
        find.ancestor(of: privacy, matching: find.byType(SeraDisclosure)),
        findsNothing,
      );
      expect(tester.widget<SwitchListTile>(privacy).value, isFalse);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await _tap(tester, privacy);
      await _tap(tester, find.widgetWithText(ChoiceChip, '120 分钟'));

      await _tap(tester, find.text('休息与时区'));
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('东京时间').last);
      await _tap(tester, find.text('休息与时区'));
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(tester.widget<SwitchListTile>(privacy).value, isTrue);
      expect(store.writes, initialWrites);
      expect(controller.data.preferences.toJson(), original.toJson());

      await _tap(tester, find.widgetWithText(SeraButton, '保存偏好'));
      final saved = controller.data.preferences;
      expect(saved.timeZone, 'Asia/Tokyo');
      expect(saved.dailyBudget, 120);
      expect(saved.useAiContext, isTrue);
      expect(saved.restStart, original.restStart);
      expect(saved.restEnd, original.restEnd);
      expect(saved.quietStart, original.quietStart);
      expect(saved.quietEnd, original.quietEnd);
      expect(saved.notifications, original.notifications);
      expect(saved.followUp, original.followUp);
      expect(store.value!.preferences.toJson(), saved.toJson());
      expect(store.writes, initialWrites + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  _densityTest(
    'folding invalid remaining work cannot bypass task validation and can recover',
    (tester) async {
      final store = _DensityStore(const Workspace(revision: 1));
      final controller = SeraController(repository: store, today: today);
      await controller.initialize();
      await _pump(tester, controller, '/19');
      final initialWrites = store.writes;
      await tester.enterText(find.byType(TextFormField).first, '核对展示材料');
      await _tap(tester, find.text('执行方式与前置条件'));
      final remaining = find.descendant(
        of: find.widgetWithText(SeraInput, '还需用时（分钟）'),
        matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(remaining);
      await tester.enterText(remaining, 'invalid remaining');
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(tester, find.text('执行方式与前置条件'));
      expect(remaining, findsNothing);

      await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
      expect(controller.data.tasks, isEmpty);
      expect(store.writes, initialWrites);
      expect(remaining, findsOneWidget);
      expect(
        tester.state<FormFieldState<String>>(remaining).errorText,
        isNotNull,
      );
      expect(
        tester.widget<TextFormField>(remaining).controller!.text,
        'invalid remaining',
      );

      await tester.ensureVisible(remaining);
      await tester.enterText(remaining, '45');
      await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
      expect(controller.data.tasks.single.remainingMinutes, 45);
      expect(controller.data.tasks.single.title, '核对展示材料');
      expect(store.writes, initialWrites + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  _densityTest(
    'event detail has no preparation action while legacy prefill keeps its deadline',
    (tester) async {
      final workspace = Workspace.fromJson(
        createSeedWorkspace(today).copyWith(revision: 1).toJson(),
      );
      final store = _DensityStore(workspace);
      final controller = SeraController(repository: store, today: today);
      await controller.initialize();
      final event = controller.entry('meeting-1')!;
      final originalCount = controller.data.tasks.length;
      await _pump(tester, controller, '/15?eventId=meeting-1');
      expect(find.text('添加会前准备任务'), findsNothing);
      expect(
        tester.widget<SeraScaffold>(find.byType(SeraScaffold)).footer,
        isNull,
      );
      expect(find.widgetWithText(TextButton, '编辑'), findsOneWidget);
      await _pump(
        tester,
        controller,
        Uri(
          path: '/19',
          queryParameters: {
            'title': '准备${event.title}',
            'estimatedMinutes': '15',
            'dueAt': event.start.toUtc().toIso8601String(),
            'fromEvent': '1',
          },
        ).toString(),
      );
      expect(find.text('来自AI的建议，请核对后保存'), findsNothing);
      expect(controller.data.tasks, hasLength(originalCount));
      await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
      final saved = controller.data.tasks.singleWhere(
        (task) => task.title == '准备${event.title}',
      );
      expect(saved.estimatedMinutes, 15);
      expect(saved.dueAt!.toUtc(), event.start.toUtc());
      expect(controller.entryForTask(saved.id), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  _densityTest(
    'focus timeout waits for the exit dialog and can continue safely',
    (tester) async {
      final controller = SeraController(
        repository: _DensityStore(
          createSeedWorkspace(today).copyWith(revision: 1),
        ),
        today: today,
      );
      await controller.initialize();
      await _pump(tester, controller, '/25?taskId=task-1');
      final active = controller.data.focusSession!;
      await _tap(tester, find.byTooltip('返回'));
      expect(find.byType(AlertDialog), findsOneWidget);
      controller.data = controller.data.copyWith(
        focusSession: FocusSession(
          id: active.id,
          taskId: active.taskId,
          startedAt: active.startedAt,
          lastResumedAt: DateTime.now(),
          accumulatedSeconds: controller.task(active.taskId)!.workMinutes * 60,
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(controller.data.focusSession, isNotNull);
      expect(controller.data.focusRecords, isEmpty);
      await _tap(tester, find.widgetWithText(TextButton, '继续专注'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(controller.data.focusSession, isNull);
      expect(controller.data.focusRecords, hasLength(1));
      expect(find.text('专注结束'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  _densityTest(
    'expanded secondary sections fit 320 px and large text with keyboard',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      for (final target in [
        ('/31', '休息与时区'),
        ('/33', '提醒状态与测试'),
        ('/18?taskId=task-1', '更多任务信息'),
        ('/19', '执行方式与前置条件'),
      ]) {
        final controller = SeraController(
          repository: _DensityStore(
            createSeedWorkspace(today).copyWith(revision: 1),
          ),
          today: today,
        );
        await controller.initialize();
        await _pump(tester, controller, target.$1);
        tester.view.physicalSize = const Size(320, 844);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await _tap(tester, find.text(target.$2));
        final disclosure = find.widgetWithText(SeraDisclosure, target.$2);
        await tester.ensureVisible(disclosure);
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -1600),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: target.$1);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        tester.view.resetViewInsets();
      }
    },
  );

  for (final route in ['33', '54']) {
    _densityTest(
      '$route keeps reminder controls, failures and exact-alarm access outside diagnostics',
      (tester) async {
        final store = _DensityStore(const Workspace(revision: 1));
        final controller = SeraController(repository: store, today: today);
        await controller.initialize();
        await _pump(tester, controller, '/$route');
        final initialWrites = store.writes;
        final reminders = find.widgetWithText(SwitchListTile, '启用任务提醒');
        final followUp = find.widgetWithText(SwitchListTile, '未开始时再提醒');
        final exactAlarm = find.widgetWithText(SeraButton, '允许准时提醒');
        for (final control in [reminders, followUp, exactAlarm]) {
          expect(control, findsOneWidget);
          expect(
            find.ancestor(of: control, matching: find.byType(SeraDisclosure)),
            findsNothing,
          );
        }
        expect(find.widgetWithText(SeraButton, '发送一条测试提醒'), findsNothing);
        await _tap(tester, reminders);
        expect(tester.widget<SwitchListTile>(reminders).value, isFalse);
        await _tap(tester, find.text('提醒状态与测试'));
        await _tap(tester, find.widgetWithText(SeraButton, '发送一条测试提醒'));
        expect(
          calls.where((call) => call.method == 'showTestNotification'),
          hasLength(1),
        );

        await _tap(tester, find.text('提醒状态与测试'));
        final failure = find.byWidgetPredicate(
          (widget) => widget is SeraNote && widget.body == '测试用系统拒绝了这次提醒',
        );
        expect(failure, findsOneWidget);
        expect(
          find.ancestor(of: failure, matching: find.byType(SeraDisclosure)),
          findsNothing,
        );
        expect(find.widgetWithText(SeraButton, '发送一条测试提醒'), findsNothing);
        expect(tester.widget<SwitchListTile>(reminders).value, isFalse);
        expect(store.writes, initialWrites);

        await _tap(tester, find.widgetWithText(SeraButton, '保存设置'));
        expect(controller.data.preferences.notifications, isFalse);
        expect(store.value!.preferences.notifications, isFalse);
        expect(
          calls.where((call) => call.method == 'cancelNotifications'),
          hasLength(1),
        );
        expect(store.writes, initialWrites + 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
