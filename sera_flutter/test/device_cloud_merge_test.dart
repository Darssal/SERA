import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/device_cloud_merge.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

const _localTask = SeraTask(id: 'device-task', title: '买牛奶');
const _cloudTask = SeraTask(id: 'cloud-task', title: '已有云端待办');

DeviceCloudMerge _merge(
  Workspace device,
  Workspace cloud, {
  Json? receipt,
  bool? preferDevice,
  String account = 'a',
}) => mergeDeviceCloud(
  device: device,
  cloud: cloud,
  accountId: account,
  previousReceipt: receipt,
  preferDevice: preferDevice,
);

void main() {
  test(
    'additive import preserves cloud objects, stable IDs and source graph',
    () {
      final deadline = DateTime.utc(2030, 1, 2);
      final device = Workspace(
        tasks: [_localTask.copyWith(goalId: 'goal')],
        goals: [
          SeraGoal(
            id: 'goal',
            title: '采购',
            deadline: deadline,
            taskIds: const ['device-task'],
          ),
        ],
        entries: [
          CalendarEntry(
            id: 'block',
            title: '采购',
            start: deadline,
            end: deadline.add(const Duration(hours: 1)),
            taskId: 'device-task',
          ),
        ],
        planningSessions: [
          PlanningSession(
            id: 'source',
            updatedAt: deadline,
            stage: 'confirmed',
            resultEntity: const PlanningResultRef(
              kind: 'task',
              id: 'device-task',
            ),
          ),
        ],
      );
      final result = _merge(device, const Workspace(tasks: [_cloudTask]));
      expect(result.conflicts, isEmpty);
      expect(result.workspace.tasks.map((t) => t.id), [
        'cloud-task',
        'device-task',
      ]);
      expect(result.workspace.goals.single.taskIds, ['device-task']);
      expect(result.workspace.entries.single.taskId, 'device-task');
      expect(
        result.workspace.planningSessions.single.resultEntity!.id,
        'device-task',
      );
      expect(device.tasks.single.id, 'device-task');
      final retry = _merge(device, result.workspace, receipt: result.receipt);
      expect(retry.changed, isFalse);
      expect(retry.workspace.tasks, hasLength(2));
    },
  );

  test('same ID and semantic content reuses cloud despite entity revision', () {
    final cloud = Workspace(tasks: [_localTask.copyWith(revision: 12)]);
    final result = _merge(const Workspace(tasks: [_localTask]), cloud);
    expect(result.conflicts, isEmpty);
    expect(result.changed, isFalse);
    expect(result.workspace.tasks.single.revision, 12);
  });

  test('unresolved collision never partially writes otherwise new objects', () {
    final cloud = Workspace(tasks: [_localTask.copyWith(title: '云端内容')]);
    final device = Workspace(tasks: [_localTask, _cloudTask]);
    final result = _merge(device, cloud);
    expect(result.conflicts, ['tasks/device-task']);
    expect(result.workspace, same(cloud));
    expect(result.changed, isFalse);
    expect(result.receipt, isEmpty);
  });

  test('explicit cloud choice consumes input; later local edit can merge', () {
    final cloud = Workspace(tasks: [_localTask.copyWith(title: '云端内容')]);
    const device = Workspace(tasks: [_localTask, _cloudTask]);
    final chosen = _merge(device, cloud, preferDevice: false);
    expect(chosen.workspace.tasks.first.title, '云端内容');
    expect(chosen.workspace.tasks, hasLength(2));
    final retry = _merge(device, chosen.workspace, receipt: chosen.receipt);
    expect(retry.conflicts, isEmpty);
    expect(retry.changed, isFalse);
    final edited = _merge(
      Workspace(
        tasks: [
          _localTask.copyWith(title: '之后的本机编辑'),
          _cloudTask,
        ],
      ),
      chosen.workspace,
      receipt: chosen.receipt,
    );
    expect(edited.conflicts, isEmpty);
    expect(edited.workspace.tasks.first.title, '之后的本机编辑');
  });

  test('unchanged device never overwrites later cloud edits or resurrects deletion', () {
    const device = Workspace(tasks: [_localTask]);
    final first = _merge(device, const Workspace());
    final cloud = first.workspace.copyWith(
      tasks: [_localTask.copyWith(title: '另一个设备改名', revision: 8)],
    );
    final merged = _merge(device, cloud, receipt: first.receipt);
    expect(merged.changed, isFalse);
    expect(merged.workspace.tasks.single.title, '另一个设备改名');
    final deleted = _merge(device, const Workspace(), receipt: first.receipt);
    expect(deleted.changed, isFalse);
    expect(deleted.workspace.tasks, isEmpty);
  });

  test('simultaneous edits require explicit choice and never delete other cloud data', () {
    const device = Workspace(tasks: [_localTask]);
    final first = _merge(device, const Workspace(tasks: [_cloudTask]));
    final changedDevice = Workspace(
      tasks: [_localTask.copyWith(title: '本机修改')],
    );
    final changedCloud = first.workspace.copyWith(
      tasks: [
        _cloudTask,
        _localTask.copyWith(title: '云端修改', revision: 9),
      ],
    );
    final conflict = _merge(
      changedDevice,
      changedCloud,
      receipt: first.receipt,
    );
    expect(conflict.conflicts, ['tasks/device-task']);
    expect(conflict.changed, isFalse);
    final accepted = _merge(
      changedDevice,
      changedCloud,
      receipt: first.receipt,
      preferDevice: true,
    );
    expect(accepted.workspace.tasks.first.id, 'cloud-task');
    expect(accepted.workspace.tasks.last.title, '本机修改');
    expect(accepted.workspace.tasks.last.revision, 10);
  });

  test('receipt from another account cannot authorize an overwrite', () {
    const device = Workspace(tasks: [_localTask]);
    final a = _merge(device, const Workspace());
    final b = _merge(
      device,
      Workspace(tasks: [_localTask.copyWith(title: 'B账户的对象')]),
      account: 'b',
      receipt: a.receipt,
    );
    expect(b.conflicts, ['tasks/device-task']);
    expect(b.workspace.tasks.single.title, 'B账户的对象');
  });

  test('missing local objects never request cloud deletion', () {
    const device = Workspace(tasks: [_localTask]);
    final first = _merge(device, const Workspace(tasks: [_cloudTask]));
    final next = _merge(
      const Workspace(),
      first.workspace,
      receipt: first.receipt,
    );
    expect(next.changed, isFalse);
    expect(next.workspace.tasks, hasLength(2));
  });

  test('planning preferences inherit only into empty cloud; device effects stay local', () {
    final start = DateTime.utc(2030);
    final device = Workspace(
      preferences: const SeraPreferences(
        dailyBudget: 180,
        startMinute: 600,
        notifications: false,
        followUp: false,
        quietStart: 1200,
      ),
      externalBusyEntries: [
        CalendarEntry(
          id: 'external',
          title: '设备日历',
          start: start,
          end: start.add(const Duration(hours: 1)),
          source: 'device',
        ),
      ],
      entries: [
        CalendarEntry(
          id: 'local-event',
          title: '自建',
          start: start,
          end: start.add(const Duration(hours: 1)),
          externalId: 'device-mapping',
          syncState: 'synced',
        ),
      ],
      platformSettings: const {'calendar': 'private-device-calendar'},
      reminderStates: const {'delivered': true},
      focusSession: FocusSession(
        id: 'running',
        taskId: 'device-task',
        startedAt: start,
      ),
    );
    final empty = _merge(device, const Workspace());
    expect(empty.workspace.preferences.dailyBudget, 180);
    expect(empty.workspace.preferences.startMinute, 600);
    expect(empty.workspace.preferences.notifications, isTrue);
    expect(empty.workspace.preferences.followUp, isTrue);
    expect(empty.workspace.preferences.quietStart, 1320);
    expect(empty.workspace.platformSettings, isEmpty);
    expect(empty.workspace.reminderStates, isEmpty);
    expect(empty.workspace.externalBusyEntries, isEmpty);
    expect(empty.workspace.focusSession, isNull);
    expect(empty.workspace.entries.single.externalId, isNull);
    expect(empty.workspace.entries.single.syncState, 'local_only');
    final existing = _merge(
      device,
      const Workspace(
        tasks: [_cloudTask],
        preferences: SeraPreferences(dailyBudget: 60),
      ),
    );
    expect(existing.workspace.preferences.dailyBudget, 60);
  });

  test(
    'new dangling source result is rejected before creating an upload journal',
    () {
      final device = Workspace(
        planningSessions: [
          PlanningSession(
            id: 'deleted-result',
            updatedAt: DateTime.utc(2030),
            stage: 'confirmed',
            resultEntity: const PlanningResultRef(
              kind: 'task',
              id: 'deleted-task',
            ),
          ),
        ],
      );
      expect(
        () => _merge(device, const Workspace()),
        throwsA(isA<RepositoryException>()),
      );
    },
  );

  test('explicit device choice cannot downgrade a confirmed cloud source', () {
    final stamp = DateTime.utc(2030);
    final cloud = Workspace(
      tasks: const [_localTask],
      planningSessions: [
        PlanningSession(
          id: 'session',
          updatedAt: stamp,
          stage: 'confirmed',
          resultEntity: const PlanningResultRef(
            kind: 'task',
            id: 'device-task',
          ),
        ),
      ],
    );
    final local = Workspace(
      planningSessions: [
        PlanningSession(id: 'session', updatedAt: stamp, stage: 'input'),
      ],
    );
    expect(
      () => _merge(local, cloud, preferDevice: true),
      throwsA(isA<RepositoryException>()),
    );
  });

  test(
    'device-only delivery state does not mark user records pending again',
    () {
      final first = const Workspace(tasks: [_localTask]);
      final changed = first.copyWith(
        reminderStates: {'notified': true},
        platformSettings: {'calendarMap': 'x'},
        revision: 44,
      );
      expect(deviceCloudFingerprint(changed), deviceCloudFingerprint(first));
      expect(deviceCloudHasContent(const Workspace()), isFalse);
    },
  );

  test(
    'empty cloud with chosen planning preferences preserves those choices',
    () {
      const device = Workspace(
        tasks: [_localTask],
        preferences: SeraPreferences(dailyBudget: 240),
      );
      const cloud = Workspace(
        revision: 8,
        preferences: SeraPreferences(dailyBudget: 45, startMinute: 1020),
      );
      final result = _merge(device, cloud);
      expect(result.workspace.tasks.single.id, 'device-task');
      expect(result.workspace.preferences.dailyBudget, 45);
      expect(result.workspace.preferences.startMinute, 1020);
    },
  );

  test(
    'upsert revisions match server object versions instead of device counters',
    () {
      final created = _merge(
        Workspace(tasks: [_localTask.copyWith(revision: 12)]),
        const Workspace(),
      );
      expect(created.workspace.tasks.single.revision, 1);
      final existing = _merge(
        Workspace(tasks: [_localTask.copyWith(title: '本机修改', revision: 12)]),
        Workspace(
          tasks: [_localTask.copyWith(revision: 3)],
          entityVersions: const {'tasks/device-task': 7},
        ),
        preferDevice: true,
      );
      expect(existing.workspace.tasks.single.revision, 8);
    },
  );
}
