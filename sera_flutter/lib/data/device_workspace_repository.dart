import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sembast/sembast.dart';

import '../domain/models.dart';
import 'auth_repository.dart' show configureAuthDio;
import 'local_database.dart';
import 'repositories.dart';

/// Device records never use account REST/sync endpoints. Only explicitly
/// submitted AI/audio requests leave this store, through a separate capability.
class DeviceWorkspaceRepository
    implements
        WorkspaceRepository,
        LocalWorkspaceCache,
        PlanningAiProvider,
        InputUnderstandingProvider,
        CancellablePlanningAiProvider,
        CancellableInputUnderstandingProvider {
  DeviceWorkspaceRepository({
    required this.apiBaseUrl,
    Database? database,
    Dio? aiClient,
    Dio? voiceClient,
    this.migrateLegacy = true,
  }) : // Public injectable parameter names are kept for callers and tests.
       // ignore: prefer_initializing_formals
       _database = database,
       // ignore: prefer_initializing_formals
       _aiClient = aiClient,
       _voice =
           voiceClient ??
           Dio(
             BaseOptions(
               baseUrl: apiBaseUrl,
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 90),
             ),
           ) {
    configureAuthDio(_voice);
  }

  static const scope = 'device-local';
  final String apiBaseUrl;
  final bool migrateLegacy;
  Database? _database;
  Future<Database>? _opening;
  final Dio? _aiClient;
  final Dio _voice;
  final _store = stringMapStoreFactory.store('device');
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<RecordSnapshot<String, Map<String, Object?>>?>? _watch;
  HttpWorkspaceRepository? _ai;
  CancelToken? _voiceCancel;
  bool _closed = false;
  int _understandingGeneration = 0, _planningGeneration = 0;

  @override
  String get mode => '仅保存在此设备';
  @override
  Stream<void> get localChanges => _changes.stream;

  void _checkOpen() {
    if (_closed) throw const RepositoryException('本机工作区已关闭。');
  }

  Future<Database> get _db async {
    _checkOpen();
    final database = _database ??= await (_opening ??= openWorkspaceDatabase(
      'sera-device-workspace-v1',
    ));
    _checkOpen();
    _watch ??= _store.record('workspace').onSnapshot(database).listen((_) {
      if (!_closed) _changes.add(null);
    });
    return database;
  }

  Future<void> _migrate(Database db) async {
    if (!migrateLegacy || await _store.record('migration').exists(db)) return;
    final old =
        await LocalWorkspaceRepository().load() ??
        await LocalWorkspaceRepository(storageKey: 'sera.signed-out').load();
    _checkOpen();
    await db.transaction((txn) async {
      if (await _store.record('migration').exists(txn)) return;
      if (old != null && !await _store.record('workspace').exists(txn)) {
        await _store.record('workspace').put(txn, old.toJson());
      }
      await _store.record('migration').put(txn, {'complete': true});
    });
  }

  @override
  Future<Workspace?> load() async {
    final db = await _db;
    await _migrate(db);
    _checkOpen();
    final value = await _store.record('workspace').get(db);
    return value == null
        ? null
        : Workspace.fromJson(Map<String, dynamic>.from(value));
  }

  @override
  Future<Workspace?> loadLocal() => load();

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    final db = await _db;
    await _migrate(db);
    return db.transaction((txn) async {
      _checkOpen();
      final old = await _store.record('workspace').get(txn);
      if ((old?['revision'] ?? 0) != expectedRevision) {
        throw const RepositoryException('本机记录已有更新，请刷新后重试。', conflict: true);
      }
      final next = workspace.copyWith(revision: expectedRevision + 1);
      await _store.record('workspace').put(txn, next.toJson());
      return next;
    });
  }

  @override
  Future<void> clear() async {
    final db = await _db;
    await db.transaction((txn) async {
      _checkOpen();
      await _store.record('workspace').delete(txn);
      // Keep the migration marker, so clearing does not reimport old data.
      await _store.record('migration').put(txn, {'complete': true});
    });
  }

  Future<Json?> cloudReceipt(String accountId) async {
    final value = await _store.record('receipt:$accountId').get(await _db);
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  Future<void> saveCloudReceipt(String accountId, Json receipt) async {
    await _store.record('receipt:$accountId').put(await _db, receipt);
  }

  Future<void> forgetCloudReceipt(String accountId) async {
    await _store.record('receipt:$accountId').delete(await _db);
  }

  Future<String> deviceToken() async {
    final db = await _db;
    return db.transaction((txn) async {
      _checkOpen();
      final old = await _store.record('capability').get(txn);
      if (old?['token'] case final String token) return token;
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _store.record('capability').put(txn, {'token': token});
      return token;
    });
  }

  Future<HttpWorkspaceRepository> _provider() async {
    final token = await deviceToken();
    _checkOpen();
    return _ai ??= HttpWorkspaceRepository(
      baseUrl: apiBaseUrl,
      client: _aiClient,
      jobApiPath: '/api/v1/device/jobs',
      deviceToken: token,
    );
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    final generation = _understandingGeneration;
    final ai = await _provider();
    if (generation != _understandingGeneration) {
      throw const RepositoryException('已取消理解，输入已保留。');
    }
    return ai.understandInput(
      input: input,
      requestId: requestId,
      onStage: onStage,
    );
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
    final generation = _planningGeneration;
    final ai = await _provider();
    final workspace = await load();
    if (generation != _planningGeneration) {
      throw const RepositoryException('已取消规划，输入已保留。');
    }
    ai.usePlanningTimeZone(workspace?.preferences.timeZone ?? 'Asia/Hong_Kong');
    return ai.generateTaskBreakdown(
      title: title,
      deadline: deadline,
      dailyBudget: dailyBudget,
      notes: notes,
      prompt: prompt,
      requestId: requestId,
    );
  }

  @override
  void cancelPlanning() {
    _planningGeneration++;
    _ai?.cancelPlanning();
  }

  @override
  void cancelUnderstanding() {
    _understandingGeneration++;
    _ai?.cancelUnderstanding();
  }

  Future<Json> createAsrTicket() async {
    final response = await _voice.post<dynamic>(
      '/api/v1/device/asr/tickets',
      data: {'sampleRate': 16000},
      options: Options(headers: {'X-Sera-Device': await deviceToken()}),
    );
    _checkOpen();
    if (response.data is! Map) throw const RepositoryException('语音连接暂时不可用。');
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<String> transcribeAudio(
    Uint8List bytes, {
    required String filename,
    required String mimeType,
    int? durationMilliseconds,
  }) async {
    if (bytes.isEmpty ||
        bytes.length > 10 * 1024 * 1024 ||
        (durationMilliseconds ?? 1) > 60000) {
      throw const RepositoryException('录音需在 60 秒和 10 MiB 以内。');
    }
    cancelTranscription();
    final cancel = _voiceCancel = CancelToken();
    final response = await _voice.post<dynamic>(
      '/api/v1/device/ai/transcribe',
      cancelToken: cancel,
      options: Options(headers: {'X-Sera-Device': await deviceToken()}),
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(mimeType),
        ),
      }),
    );
    _checkOpen();
    final body = response.data;
    if (body is! Map ||
        body['source'] != 'siliconflow' ||
        body['text'] is! String ||
        (body['text'] as String).trim().isEmpty) {
      throw const RepositoryException('没有识别到语音内容，请重新录制。');
    }
    return (body['text'] as String).trim();
  }

  void cancelTranscription() {
    _voiceCancel?.cancel();
    _voiceCancel = null;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    cancelTranscription();
    _ai?.dispose();
    await _watch?.cancel();
    await _changes.close();
    final db = _database;
    if (db != null) await db.close();
  }
}
