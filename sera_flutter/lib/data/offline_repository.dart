import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sembast/sembast.dart';

import '../domain/models.dart';
import 'local_database.dart';
import 'repositories.dart';

/// Cached state and pending batches commit in one local transaction. Each remote
/// operation has a stable ID and object version, including unknown HTTP results.
class OfflineWorkspaceRepository
    implements
        WorkspaceRepository,
        PlanningAiProvider,
        InputUnderstandingProvider,
        CancellableInputUnderstandingProvider,
        CancellablePlanningAiProvider,
        LocalWorkspaceCache,
        SynchronizingWorkspaceRepository {
  OfflineWorkspaceRepository({
    required this.remote,
    required this.accountId,
    Database? database,
    // Public constructor parameter deliberately differs from the private field.
    // ignore: prefer_initializing_formals
  }) : _database = database;
  final HttpWorkspaceRepository remote;
  final String accountId;
  Database? _database;
  final _store = stringMapStoreFactory.store('workspace');
  final _instanceId = List.generate(
    // Dart's JavaScript backend uses 32-bit bitwise operations. Keep each
    // random draw within 16 bits instead of computing a 2^32 shift there.
    8,
    (_) => Random.secure().nextInt(65536).toRadixString(16).padLeft(4, '0'),
  ).join();
  int _operationSequence = 0;
  Future<void> _tail = Future.value();
  Future<void> _networkTail = Future.value();
  Future<Workspace?>? _syncInFlight;
  final _localChanges = StreamController<void>.broadcast();
  bool _syncAgain = false;
  bool _closed = false;
  bool _clearing = false;
  int _pending = 0;
  bool _offline = false;
  Json? _conflict;
  String? _lastSyncError;
  @override
  Stream<void> get localChanges => _localChanges.stream;

  void _notifyLocalChange() {
    if (!_closed) _localChanges.add(null);
  }

  @override
  Future<Workspace?> loadLocal() => _serial(() async {
    final state = await _read();
    _restoreStatus(state);
    return _workspace(state, 'local');
  });
  @override
  int get pendingCount => _pending;
  @override
  bool get isOffline => _offline;
  @override
  Json? get syncConflict => _conflict;
  @override
  String get mode => _offline
      ? '离线保存 · $_pending 项待同步'
      : _lastSyncError != null
      ? '本机已保存 · 同步待重试：$_lastSyncError'
      : _pending > 0
      ? '$_pending 项待同步'
      : '云端同步';
  Future<Database> get _db async => _database ??= await openWorkspaceDatabase(
    'sera-v2-${Uri.encodeComponent(accountId)}',
  );
  String _id(String kind) => '$kind-$_instanceId-${_operationSequence++}';
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed) throw const RepositoryException('工作区已关闭。');
        result.complete(await action());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  // HTTP never owns the local-write queue. A slow connection must not delay a
  // durable local edit, but remote requests still retain their original order.
  Future<T> _network<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _networkTail = _networkTail.then((_) async {
      try {
        if (_closed) throw const RepositoryException('工作区已关闭。');
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  void _restoreStatus(Json state) {
    _pending = _batches(state)
        .fold(0, (sum, batch) => sum + (batch['operations'] as List).length);
    _conflict = state['conflict'] is Map
        ? Map<String, dynamic>.from(state['conflict'] as Map)
        : null;
    _lastSyncError = state['syncError'] as String?;
  }

  bool _sameContent(Workspace a, Workspace b) {
    final first = a.toJson()
      ..remove('revision')
      ..remove('entityVersions');
    final second = b.toJson()
      ..remove('revision')
      ..remove('entityVersions');
    return jsonEncode(first) == jsonEncode(second);
  }

  Future<Workspace?> _startSync({bool afterSave = false}) {
    final running = _syncInFlight;
    if (running != null) {
      if (afterSave) _syncAgain = true;
      return running;
    }
    _syncAgain = false;
    final future = _network(_flush);
    _syncInFlight = future;
    // The queue is durable before this starts. Failures remain visible through
    // status and explicit synchronize(); no detached error is left unhandled.
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_syncInFlight, future)) _syncInFlight = null;
          if (_syncAgain &&
              !_closed &&
              !_offline &&
              _conflict == null &&
              _lastSyncError == null) {
            _startSync();
          }
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_syncInFlight, future)) _syncInFlight = null;
          if (!_closed) {
            _lastSyncError = error is RepositoryException
                ? error.message
                : '同步未完成，请重试。';
            _notifyLocalChange();
          }
        },
      ),
    );
    return future;
  }

  Future<Json> _read() async =>
      await _store.record('state').get(await _db) ?? <String, dynamic>{};
  Workspace? _workspace(Json s, String key) => s[key] is Map
      ? Workspace.fromJson(Map<String, dynamic>.from(s[key] as Map))
      : null;
  List<Json> _batches(Json s) => (s['batches'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  static const _lists = [
    'tasks',
    'entries',
    'goals',
    'drafts',
    'planningSessions',
    'focusRecords',
    'reviews',
    'externalBusyEntries',
    'history',
  ];
  static const _singletons = [
    'preferences',
    'focusSession',
    'reminderStates',
    'platformSettings',
  ];
  List<Json> _diff(Workspace before, Workspace after) {
    final a = before.toJson(), b = after.toJson();
    final result = <Json>[];
    for (final type in [..._lists, ..._singletons]) {
      final old = _lists.contains(type)
          ? {for (final e in a[type] as List) '${e['id']}': e}
          : {'singleton': a[type]};
      final next = _lists.contains(type)
          ? {for (final e in b[type] as List) '${e['id']}': e}
          : {'singleton': b[type]};
      for (final id in {...old.keys, ...next.keys}) {
        if (jsonEncode(old[id]) == jsonEncode(next[id])) continue;
        final version =
            before.entityVersions['$type/$id'] ??
            (old[id] is Map ? (old[id] as Map)['revision'] : null) ??
            (old[id] == null ? 0 : 1);
        result.add({
          'id': _id('op-${result.length}'),
          'entityType': type,
          'entityId': id,
          'expectedVersion': version,
          'action': next[id] == null ? 'delete' : 'upsert',
          'value': next[id],
        });
      }
    }
    return result;
  }

  Workspace _normalize(Workspace w) {
    final versions = Map<String, dynamic>.from(w.entityVersions);
    final json = w.toJson();
    for (final type in _lists) {
      for (final v in json[type] as List) {
        versions.putIfAbsent('$type/${v['id']}', () => v['revision'] ?? 1);
      }
    }
    for (final type in _singletons) {
      versions.putIfAbsent('$type/singleton', () => 1);
    }
    return w.copyWith(entityVersions: versions);
  }

  Workspace _apply(Workspace base, List<Json> operations) {
    final j = base.toJson();
    final versions = Map<String, dynamic>.from(base.entityVersions);
    for (final op in operations) {
      final type = op['entityType'] as String, id = op['entityId'] as String;
      if (_lists.contains(type)) {
        final values = List<dynamic>.from(j[type] as List)
          ..removeWhere((e) => e['id'] == id);
        if (op['action'] != 'delete') values.add(op['value']);
        j[type] = values;
      } else {
        j[type] = op['action'] == 'delete' ? null : op['value'];
      }
      versions['$type/$id'] = (op['expectedVersion'] as num).toInt() + 1;
    }
    j['entityVersions'] = versions;
    return Workspace.fromJson(j);
  }

  Future<Workspace?> _flush() async {
    while (true) {
      final state = await _serial(_read);
      _restoreStatus(state);
      final batches = _batches(state);
      if (batches.isEmpty) return _workspace(state, 'local');
      final batch = batches.first;
      try {
        final response = await remote.syncOperations(batch);
        final saved = _normalize(
          Workspace.fromJson(
            Map<String, dynamic>.from(response['workspace'] as Map),
          ),
        );
        await _serial(() async {
          await (await _db).transaction((txn) async {
            // Saves and other tabs can append/acknowledge batches while HTTP
            // runs. Rebase only the still-pending journal from this transaction.
            final current =
                await _store.record('state').get(txn) ?? <String, dynamic>{};
            final pending = _batches(current);
            final index = pending.indexWhere(
              (item) => item['batchId'] == batch['batchId'],
            );
            if (index < 0) {
              _restoreStatus(current);
              return;
            }
            pending.removeAt(index);
            final currentServer = _workspace(current, 'server');
            final confirmed =
                currentServer != null && currentServer.revision > saved.revision
                ? currentServer
                : saved;
            var visible = confirmed;
            for (final next in pending) {
              visible = _apply(
                visible,
                (next['operations'] as List)
                    .map((op) => Map<String, dynamic>.from(op as Map))
                    .toList(),
              );
            }
            final local = _workspace(current, 'local');
            // A server response can bring in another device's edits. Advancing
            // the local revision makes an older UI snapshot fail CAS safely.
            visible = visible.copyWith(
              revision: local == null
                  ? saved.revision
                  : local.revision + (_sameContent(local, visible) ? 0 : 1),
            );
            final next =
                <String, dynamic>{
                    ...current,
                    'server': confirmed.toJson(),
                    'local': visible.toJson(),
                    'batches': pending,
                  }
                  ..remove('conflict')
                  ..remove('syncError');
            await _store.record('state').put(txn, next);
            _restoreStatus(next);
            _notifyLocalChange();
            _offline = false;
          });
        });
      } catch (error) {
        if (_closed) throw const RepositoryException('工作区已关闭。');
        final failure = error is RepositoryException
            ? error
            : const RepositoryException('同步未完成，请重试。');
        final result = await _serial(() async {
          return (await _db).transaction((txn) async {
            final current =
                await _store.record('state').get(txn) ?? <String, dynamic>{};
            if (!_batches(current)
                .any((item) => item['batchId'] == batch['batchId'])) {
              _restoreStatus(current);
              return (obsolete: true, value: _workspace(current, 'local'));
            }
            final next = <String, dynamic>{
              ...current,
              if (failure.conflict) 'conflict': failure.details,
              if (!failure.conflict && !failure.offline)
                'syncError': failure.message,
            };
            await _store.record('state').put(txn, next);
            _restoreStatus(next);
            _notifyLocalChange();
            if (failure.offline) _offline = true;
            return (obsolete: false, value: _workspace(next, 'local'));
          });
        });
        if (result.obsolete) continue;
        if (!failure.offline && !failure.conflict) throw failure;
        return result.value;
      }
    }
  }

  @override
  Future<Workspace?> load() => _network(() async {
    final old = await _serial(_read);
    _restoreStatus(old);
    if (_batches(old).isNotEmpty) return _flush();
    try {
      var saved = await remote.load();
      if (saved == null) {
        try {
          saved = await remote.save(const Workspace(), expectedRevision: 0);
        } on RepositoryException catch (failure) {
          if (!failure.conflict) rethrow;
          saved = await remote.load();
          if (saved == null) rethrow;
        }
      }
      final confirmed = _normalize(saved);
      return await _serial(() async {
        return (await _db).transaction((txn) async {
          final current =
              await _store.record('state').get(txn) ?? <String, dynamic>{};
          if (_batches(current).isNotEmpty) {
            _restoreStatus(current);
            return _workspace(current, 'local');
          }
          final currentServer = _workspace(current, 'server');
          if (currentServer != null &&
              currentServer.revision > confirmed.revision) {
            _restoreStatus(current);
            return _workspace(current, 'local');
          }
          final previous = _workspace(current, 'local');
          final visible = previous == null
              ? confirmed
              : confirmed.copyWith(
                  revision:
                      previous.revision +
                      (_sameContent(previous, confirmed) ? 0 : 1),
                );
          final next = <String, dynamic>{
            'local': visible.toJson(),
            'server': confirmed.toJson(),
            'batches': <dynamic>[],
          };
          await _store.record('state').put(txn, next);
          _restoreStatus(next);
          _notifyLocalChange();
          _offline = false;
          return visible;
        });
      });
    } on RepositoryException catch (error) {
      if (!error.offline) rethrow;
      return _serial(() async {
        // A local save may have completed after the GET started.
        final current = await _read();
        _restoreStatus(current);
        _offline = true;
        _notifyLocalChange();
        final cached = _workspace(current, 'local');
        if (cached == null) {
          throw const RepositoryException('首次连接需要网络，请恢复连接后重试。', offline: true);
        }
        return cached;
      });
    }
  });

  @override
  Future<Workspace> save(
    Workspace value, {
    required int expectedRevision,
  }) async {
    final saved = await _serial(() async {
      if (_clearing) throw const RepositoryException('工作区正在清空，请稍后重试。');
      return (await _db).transaction((txn) async {
        final state =
            await _store.record('state').get(txn) ?? <String, dynamic>{};
        final before = _workspace(state, 'local') ?? const Workspace();
        if (before.revision != expectedRevision) {
          throw const RepositoryException('本机数据已有更新，请刷新后重试。', conflict: true);
        }
        final operations = _diff(before, value);
        final visible = _apply(
          before,
          operations,
        ).copyWith(revision: expectedRevision + 1);
        final batches = _batches(state);
        if (operations.isNotEmpty) {
          batches.add({
            'clientId': accountId,
            'batchId': _id('batch'),
            'baseRevision': _workspace(state, 'server')?.revision ?? 0,
            'operations': operations,
          });
        }
        final next = <String, dynamic>{
          ...state,
          'local': visible.toJson(),
          'batches': batches,
        };
        await _store.record('state').put(txn, next);
        _restoreStatus(next);
        _notifyLocalChange();
        return visible;
      });
    });
    // The caller can continue as soon as the complete local transaction commits.
    // _startSync owns and reports the background operation until completion.
    if (!_closed && !_clearing) _startSync(afterSave: true);
    return saved;
  }

  @override
  Future<Workspace?> synchronize() => _startSync();
  @override
  Future<Workspace?> resolveConflict({
    required bool keepLocal,
  }) => _network(() async {
    final before = await _serial(_read);
    final current = await remote.load() ?? const Workspace();
    await _serial(() async {
      await (await _db).transaction((txn) async {
        final s = await _store.record('state').get(txn) ?? <String, dynamic>{};
        if (jsonEncode(s) != jsonEncode(before)) {
          throw const RepositoryException(
            '本机数据已有更新，请重新选择冲突处理方式。',
            conflict: true,
          );
        }
        final local = _workspace(s, 'local') ?? current;
        final latest = <String, Json>{};
        if (keepLocal) {
          for (final b in _batches(s)) {
            for (final value in b['operations'] as List) {
              final op = Map<String, dynamic>.from(value as Map);
              latest['${op['entityType']}/${op['entityId']}'] = op;
            }
          }
          final confirmed = {
            for (final session in current.planningSessions)
              if (session.stage == 'confirmed' && session.resultEntity != null)
                session.id: session.resultEntity!,
          };
          for (final op in latest.values) {
            if (op['entityType'] != 'planningSessions' ||
                op['action'] != 'upsert') {
              continue;
            }
            final result = confirmed[op['entityId']];
            if (result == null) continue;
            final value = op['value'];
            final incoming = value is Map ? value['resultEntity'] : null;
            if (value is! Map ||
                value['stage'] != 'confirmed' ||
                incoming is! Map ||
                incoming['kind'] != result.kind ||
                incoming['id'] != result.id) {
              // Do not rewrite the cache or clear its conflict before the
              // user can choose the cloud result or export the local input.
              throw RepositoryException(
                '这次输入已在云端保存。请采用云端内容，本机修改仍保留。',
                conflict: true,
                details: _conflict ?? const {},
              );
            }
          }
        }
        var counter = 0;
        final ops = latest.entries.map((entry) {
          final op = entry.value;
          return <String, dynamic>{
            ...op,
            'id': _id('resolve-${counter++}'),
            'expectedVersion': current.entityVersions[entry.key] ?? 0,
          };
        }).toList();
        final batch = {
          'clientId': accountId,
          'batchId': _id('resolved'),
          'baseRevision': current.revision,
          'operations': ops,
        };
        final next = <String, dynamic>{
          'local': (keepLocal ? _apply(current, ops) : current)
              .copyWith(revision: local.revision + 1)
              .toJson(),
          'server': current.toJson(),
          'batches': [if (ops.isNotEmpty) batch],
        };
        await _store.record('state').put(txn, next);
        _restoreStatus(next);
        _notifyLocalChange();
      });
    });
    return _flush();
  });
  @override
  Future<void> clear() async {
    if (_clearing) throw const RepositoryException('工作区正在清空，请稍后重试。');
    _clearing = true;
    try {
      await _network(() async {
        await remote.clear();
        await _serial(() async {
          await _store.record('state').delete(await _db);
          _restoreStatus({});
          _notifyLocalChange();
          _offline = false;
        });
      });
    } finally {
      _clearing = false;
    }
  }

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async {
    if (_closed) throw const RepositoryException('工作区已关闭。');
    // An explicit generate/resume action also retries connectivity. A cached
    // offline flag must not block the real request after the network returns.
    return remote.generateTaskBreakdown(
      title: title,
      deadline: deadline,
      dailyBudget: dailyBudget,
      notes: notes,
      prompt: prompt,
      requestId: requestId,
    );
  }

  @override
  void cancelPlanning() => remote.cancelPlanning();

  @override
  void cancelUnderstanding() => remote.cancelUnderstanding();

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) {
    if (_closed) throw const RepositoryException('工作区已关闭。');
    return remote.understandInput(
      input: input,
      requestId: requestId,
      onStage: onStage,
    );
  }

  Future<void> purge() async {
    await dispose();
    await deleteWorkspaceDatabase('sera-v2-${Uri.encodeComponent(accountId)}');
  }

  Future<void> dispose() async {
    _closed = true;
    remote.dispose();
    await _tail;
    await _localChanges.close();
    await _database?.close();
  }
}
