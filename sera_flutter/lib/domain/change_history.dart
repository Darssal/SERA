import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

const historyCollections = [
  'tasks',
  'entries',
  'goals',
  'drafts',
  'focusRecords',
  'externalBusyEntries',
  'reviews',
];

// Build only undoable business state. Serializing the workspace first would
// also visit every old history record and conversation, only to discard them.
Json historySnapshot(Workspace value) => {
  'schemaVersion': 2,
  'tasks': value.tasks.map((item) => item.toJson()).toList(),
  'entries': value.entries.map((item) => item.toJson()).toList(),
  'goals': value.goals.map((item) => item.toJson()).toList(),
  'drafts': value.drafts.map((item) => item.toJson()).toList(),
  'preferences': value.preferences.toJson(),
  'focusRecords': value.focusRecords.map((item) => item.toJson()).toList(),
  'externalBusyEntries': value.externalBusyEntries
      .map((item) => item.toJson())
      .toList(),
  'reviews': value.reviews.map((item) => item.toJson()).toList(),
};

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String historyEntityDigest(Json value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

String historySnapshotDigest(Json snapshot) {
  final normalized = <String, dynamic>{...snapshot};
  for (final collection in historyCollections) {
    final values = List<dynamic>.from(
      snapshot[collection] as List? ?? const [],
    );
    values.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    normalized[collection] = values;
  }
  // Only entity collections are sets; nested checklist, phase and conversation
  // orders remain meaningful and are never sorted away by the digest.
  return historyEntityDigest(normalized);
}

Map<String, Json> historyEntities(Json snapshot, String collection) {
  final raw = snapshot[collection];
  if (raw is! List) throw const FormatException('Missing history collection');
  final result = <String, Json>{};
  for (final item in raw) {
    if (item is! Map ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty ||
        result.containsKey(item['id'])) {
      throw const FormatException('Invalid history entity');
    }
    result[item['id'] as String] = Map<String, dynamic>.from(item);
  }
  return result;
}

Json _freeze(Json value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

ChangeRecord createCompactChange({
  required String id,
  required String label,
  required DateTime at,
  required Workspace before,
  required Workspace after,
}) => _compactSnapshots(
  ChangeRecord(id: id, label: label, at: at),
  historySnapshot(before),
  historySnapshot(after),
);

ChangeRecord _compactSnapshots(ChangeRecord record, Json before, Json after) {
  final oldValues = <String, dynamic>{};
  final newValues = <String, dynamic>{};
  final beforeOrder = <String, List<String>>{};
  for (final collection in historyCollections) {
    final old = historyEntities(before, collection);
    final next = historyEntities(after, collection);
    final changed = {
      ...old.keys,
      ...next.keys,
    }.where((id) => jsonEncode(old[id]) != jsonEncode(next[id])).toList();
    oldValues[collection] = [
      for (final id in changed)
        if (old[id] != null) old[id],
    ];
    newValues[collection] = [
      for (final id in changed)
        if (next[id] != null) next[id],
    ];
    if (changed.isNotEmpty ||
        jsonEncode(old.keys.toList()) != jsonEncode(next.keys.toList())) {
      beforeOrder[collection] = old.keys.toList();
    }
  }
  if (jsonEncode(before['preferences']) != jsonEncode(after['preferences'])) {
    oldValues['preferences'] = before['preferences'];
    newValues['preferences'] = after['preferences'];
  }
  final taskEntries = <String, Map<String, String>>{};
  if (record.label == '完成任务') {
    for (final task in (newValues['tasks'] as List).whereType<Map>()) {
      final taskId = task['id'] as String;
      taskEntries[taskId] = {
        for (final entry in (after['entries'] as List).whereType<Map>())
          if (entry['taskId'] == taskId)
            entry['id'] as String: historyEntityDigest(
              Map<String, dynamic>.from(entry),
            ),
      };
    }
  }
  return ChangeRecord(
    id: record.id,
    label: record.label,
    at: record.at,
    undone: record.undone,
    format: 'entity-delta-v1',
    before: _freeze(oldValues),
    after: _freeze(newValues),
    afterDigest: historySnapshotDigest(after),
    beforeOrder: beforeOrder,
    afterTaskEntries: taskEntries,
  );
}

// Migrate only complete legacy records during the next normal save. Pending
// synchronization operations retain their original payload and idempotency key.
ChangeRecord compactLegacyChange(ChangeRecord record) {
  if (record.format != null) return record;
  bool complete(Json snapshot) =>
      const [1, 2].contains(snapshot['schemaVersion']) &&
      snapshot['preferences'] is Map &&
      const [
        'tasks',
        'entries',
        'goals',
        'drafts',
        'focusRecords',
      ].every((key) => snapshot[key] is List) &&
      snapshot.keys.every(
        (key) =>
            key == 'schemaVersion' ||
            key == 'preferences' ||
            historyCollections.contains(key),
      );
  if (!complete(record.before) || !complete(record.after)) return record;
  try {
    return _compactSnapshots(
      record,
      historySnapshot(Workspace.fromJson(record.before)),
      historySnapshot(Workspace.fromJson(record.after)),
    );
  } catch (_) {
    // An incomplete historical record stays readable in its original format.
    return record;
  }
}

bool historyMatchesAfter(ChangeRecord record, Workspace current) {
  if (record.format != null && !record.isDelta) {
    throw const FormatException('Unsupported change history format');
  }
  final expected = record.isDelta
      ? record.afterDigest
      : historySnapshotDigest(
          historySnapshot(Workspace.fromJson(record.after)),
        );
  return expected == historySnapshotDigest(historySnapshot(current));
}

Workspace restoreHistoryBefore(ChangeRecord record, Workspace current) {
  if (record.format == null) return Workspace.fromJson(record.before);
  if (!record.isDelta) {
    throw const FormatException('Unsupported change history format');
  }
  final restored = historySnapshot(current);
  for (final collection in historyCollections) {
    final before = historyEntities(record.before, collection);
    final after = historyEntities(record.after, collection);
    final values = historyEntities(restored, collection);
    for (final id in {...before.keys, ...after.keys}) {
      final old = before[id];
      if (old == null) {
        values.remove(id);
      } else {
        values[id] = old;
      }
    }
    final order = record.beforeOrder[collection];
    if (order != null) {
      if (order.length != values.length ||
          order.toSet().length != order.length ||
          order.any((id) => !values.containsKey(id))) {
        throw const FormatException('Invalid history order');
      }
      restored[collection] = [for (final id in order) values[id]];
    } else {
      if (before.isNotEmpty || after.isNotEmpty) {
        throw const FormatException('Missing changed collection order');
      }
      restored[collection] = values.values.toList();
    }
  }
  if (record.before.containsKey('preferences') !=
      record.after.containsKey('preferences')) {
    throw const FormatException('Incomplete preferences change');
  }
  if (record.before.containsKey('preferences')) {
    restored['preferences'] = record.before['preferences'];
  }
  return Workspace.fromJson(restored);
}
