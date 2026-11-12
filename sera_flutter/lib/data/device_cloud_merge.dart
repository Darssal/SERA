import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/models.dart';
import 'workspace_repository.dart';

const _collections = [
  'tasks',
  'entries',
  'goals',
  'drafts',
  'planningSessions',
  'focusRecords',
  'reviews',
];

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys =
        value.keys.cast<String>().where((k) => k != 'revision').toList()
          ..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

bool _equal(dynamic a, dynamic b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Json _planningPreferences(SeraPreferences value) {
  final json = value.toJson();
  return {
    for (final key in [
      'weekdays',
      'dailyBudget',
      'bufferMinutes',
      'startMinute',
      'endMinute',
      'timeZone',
      'restStart',
      'restEnd',
    ])
      key: json[key],
  };
}

/// Only user-owned portable records participate. Running focus, reminder
/// delivery state, calendar mappings and old undo snapshots belong to a device.
Json deviceCloudInput(Workspace value) {
  final json = value.toJson();
  json['entries'] = value.entries.where((e) => !e.isExternal).map((e) {
    final entry = e.toJson();
    entry['externalId'] = null;
    entry['syncState'] = 'local_only';
    return entry;
  }).toList();
  return {
    for (final key in _collections)
      key: (List<dynamic>.from(json[key] as List)
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String))),
    'preferences': _planningPreferences(value.preferences),
  };
}

String deviceCloudFingerprint(Workspace value) => sha256
    .convert(utf8.encode(jsonEncode(_canonical(deviceCloudInput(value)))))
    .toString();

bool deviceCloudHasContent(Workspace value) =>
    !_empty(value) ||
    !_equal(
      _planningPreferences(value.preferences),
      _planningPreferences(const SeraPreferences()),
    );

Map<String, Json> _entities(dynamic raw) => {
  for (final item in raw is List ? raw : const [])
    if (item is Map && item['id'] is String)
      item['id'] as String: Map<String, dynamic>.from(item),
};

bool _empty(Workspace value) =>
    value.tasks.isEmpty &&
    value.entries.isEmpty &&
    value.goals.isEmpty &&
    value.drafts.isEmpty &&
    value.planningSessions.isEmpty &&
    value.focusRecords.isEmpty &&
    value.reviews.isEmpty;

class DeviceCloudMerge {
  const DeviceCloudMerge({
    required this.workspace,
    required this.receipt,
    required this.conflicts,
    required this.changed,
  });

  final Workspace workspace;
  final Json receipt;
  final List<String> conflicts;
  final bool changed;
}

/// Three-way, additive import. A receipt records the accepted device input and
/// cloud projection separately: choosing cloud must also consume that input.
/// Device deletions are never interpreted as a request to delete cloud records.
DeviceCloudMerge mergeDeviceCloud({
  required Workspace device,
  required Workspace cloud,
  required String accountId,
  Json? previousReceipt,
  bool? preferDevice,
}) {
  final input = deviceCloudInput(device);
  final valid =
      previousReceipt?['schemaVersion'] == 1 &&
      previousReceipt?['accountId'] == accountId;
  final oldInput = valid && previousReceipt?['input'] is Map
      ? Map<String, dynamic>.from(previousReceipt?['input'] as Map)
      : <String, dynamic>{};
  final oldCloud = valid && previousReceipt?['cloud'] is Map
      ? Map<String, dynamic>.from(previousReceipt?['cloud'] as Map)
      : <String, dynamic>{};
  final next = cloud.toJson();
  final conflicts = <String>[];
  for (final collection in _collections) {
    final local = _entities(input[collection]);
    final beforeLocal = _entities(oldInput[collection]);
    final beforeCloud = _entities(oldCloud[collection]);
    final target = _entities(next[collection]);
    for (final entry in local.entries) {
      final id = entry.key, value = entry.value;
      // An unchanged old copy must never overwrite a later cloud edit, nor
      // resurrect an object deleted from the account after an earlier import.
      if (_equal(value, beforeLocal[id])) continue;
      if (_equal(value, target[id])) continue;
      final safe =
          target[id] == null && beforeLocal[id] == null ||
          beforeCloud.containsKey(id) && _equal(target[id], beforeCloud[id]);
      if (!safe) {
        conflicts.add('$collection/$id');
        if (preferDevice != true) continue;
      }
      final replacement = Map<String, dynamic>.from(value);
      if (replacement.containsKey('revision')) {
        final expected =
            (cloud.entityVersions['$collection/$id'] as num?)?.toInt() ??
            (target[id]?['revision'] as num?)?.toInt() ??
            0;
        // Match SyncStore's upsert normalization now. Otherwise an ACK changes
        // entity revisions underneath the freshly recorded undo digest.
        replacement['revision'] = expected + 1;
      }
      target[id] = replacement;
    }
    next[collection] = target.values.toList();
  }
  if (_empty(cloud) &&
      !valid &&
      _equal(
        _planningPreferences(cloud.preferences),
        _planningPreferences(const SeraPreferences()),
      )) {
    next['preferences'] = {
      ...cloud.preferences.toJson(),
      ..._planningPreferences(device.preferences),
    };
  }
  // Do not partially import anything before the user chooses how to resolve
  // colliding objects. Source relationships and stable object IDs stay intact.
  if (conflicts.isNotEmpty && preferDevice == null) {
    return DeviceCloudMerge(
      workspace: cloud,
      receipt: const {},
      conflicts: conflicts,
      changed: false,
    );
  }
  final merged = Workspace.fromJson(next);
  _validateRelationships(cloud, merged);
  final acceptedCloud = merged.toJson();
  return DeviceCloudMerge(
    workspace: merged,
    receipt: {
      'schemaVersion': 1,
      'accountId': accountId,
      'inputFingerprint': deviceCloudFingerprint(device),
      'input': input,
      'cloud': {for (final key in _collections) key: acceptedCloud[key]},
    },
    conflicts: conflicts,
    changed: !_equal(cloud.toJson(), merged.toJson()),
  );
}

void _validateRelationships(Workspace before, Workspace after) {
  final tasks = {for (final task in after.tasks) task.id: task};
  final goals = {for (final goal in after.goals) goal.id: goal};
  final entries = {for (final event in after.entries) event.id: event};
  bool invalid =
      after.tasks.any(
        (task) =>
            task.goalId != null && !goals.containsKey(task.goalId) ||
            task.dependencyIds.any((id) => !tasks.containsKey(id)),
      ) ||
      after.entries.any(
        (event) => event.taskId != null && !tasks.containsKey(event.taskId),
      ) ||
      after.goals.any(
        (goal) => goal.taskIds.any(
          (id) => !tasks.containsKey(id) || tasks[id]!.goalId != goal.id,
        ),
      ) ||
      after.focusRecords.any((record) => !tasks.containsKey(record.taskId));
  final visited = <String>{}, visiting = <String>{};
  bool visit(String id) {
    if (visiting.contains(id) || visiting.length > 256) return false;
    if (!visited.add(id)) return true;
    visiting.add(id);
    for (final dependency in tasks[id]!.dependencyIds) {
      if (!tasks.containsKey(dependency) || !visit(dependency)) return false;
    }
    visiting.remove(id);
    return true;
  }

  if (!invalid) invalid = tasks.keys.any((id) => !visit(id));
  final oldSessions = {
    for (final session in before.planningSessions) session.id: session,
  };
  for (final session in after.planningSessions) {
    final result = session.resultEntity;
    final old = oldSessions[session.id]?.resultEntity;
    if (old != null &&
        (!_equal(old.toJson(), result?.toJson()) ||
            session.stage != 'confirmed')) {
      invalid = true;
    }
    if (result != null &&
        old == null &&
        (result.kind == 'task'
            ? !tasks.containsKey(result.id)
            : !entries.containsKey(result.id) || entries[result.id]!.isTask)) {
      invalid = true;
    }
  }
  if (invalid) {
    throw const RepositoryException(
      '部分本机记录的关联事项已变更，暂未合并。本机记录仍保留。',
      conflict: true,
    );
  }
}
