import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../domain/planning_service.dart';
import 'planning_ai_provider.dart';
import 'workspace_repository.dart';
import 'auth_repository.dart' show configureAuthDio;

export 'workspace_repository.dart';
export 'planning_ai_provider.dart';

WorkspaceRepository createWorkspaceRepository({
  String apiBaseUrl = '',
  String? Function()? tokenProvider,
  Future<void> Function()? onUnauthorized,
}) => apiBaseUrl.trim().isEmpty
    ? LocalWorkspaceRepository()
    : HttpWorkspaceRepository(
        baseUrl: apiBaseUrl,
        tokenProvider: tokenProvider,
        onUnauthorized: onUnauthorized,
      );

/// Reads the platform store on every operation (including browser reloads).
/// A repository instance serializes writes; remote multi-client concurrency is
/// enforced by the REST server's SQLite revision transaction.
class LocalWorkspaceRepository implements WorkspaceRepository {
  LocalWorkspaceRepository({
    SharedPreferencesAsync? preferences,
    this.storageKey = 'sera.workspace.v1',
  }) : _preferences = preferences ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _preferences;
  final String storageKey;
  Future<void> _tail = Future<void>.value();

  @override
  String get mode => '本机持久化';

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<Workspace?> _read() async {
    try {
      final value = await _preferences.getString(storageKey);
      if (value == null) return null;
      final json = jsonDecode(value);
      if (json is! Map || !const [1, 2].contains(json['schemaVersion'])) {
        throw const RepositoryException('本地数据版本不受支持，请先导出或清空数据。');
      }
      return Workspace.fromJson(Map<String, dynamic>.from(json));
    } on RepositoryException {
      rethrow;
    } catch (_) {
      throw const RepositoryException('无法读取本地数据，请检查浏览器存储或应用存储权限。');
    }
  }

  @override
  Future<Workspace?> load() => _serial(_read);

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) => _serial(() async {
    final current = await _read();
    if ((current?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('数据已被修改，请刷新后重试。', conflict: true);
    }
    final saved = workspace.copyWith(revision: expectedRevision + 1);
    try {
      await _preferences.setString(storageKey, jsonEncode(saved.toJson()));
    } catch (_) {
      throw const RepositoryException('本地保存失败，修改尚未提交，请检查存储空间后重试。');
    }
    return saved;
  });

  @override
  Future<void> clear() => _serial(() async {
    try {
      await _preferences.remove(storageKey);
    } catch (_) {
      throw const RepositoryException('清空本地数据失败，请重试。');
    }
  });
}

class HttpWorkspaceRepository
    implements
        WorkspaceRepository,
        PlanningAiProvider,
        InputUnderstandingProvider,
        CancellableInputUnderstandingProvider,
        CancellablePlanningAiProvider {
  HttpWorkspaceRepository({
    required String baseUrl,
    Dio? client,
    String? Function()? tokenProvider,
    Future<void> Function()? onUnauthorized,
    String? Function()? csrfProvider,
    String jobApiPath = '/api/v1/jobs',
    String? deviceToken,
    // Public constructor parameter deliberately differs from the private field.
    // ignore: prefer_initializing_formals
  }) : _jobApiPath = jobApiPath,
       // ignore: prefer_initializing_formals
       _deviceToken = deviceToken,
       // ignore: prefer_initializing_formals
       _onUnauthorized = onUnauthorized,
       // Keep the public tokenProvider argument while storing it privately.
       // ignore: prefer_initializing_formals
       _tokenProvider = tokenProvider,
       _csrfProvider = csrfProvider,
       _client =
           client ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl.replaceFirst(RegExp(r'/+$'), ''),
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 12),
               sendTimeout: const Duration(seconds: 12),
               contentType: Headers.jsonContentType,
             ),
           ) {
    configureAuthDio(_client, csrfProvider: csrfProvider);
    _client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final operation = options.extra[_jobScopeKey];
          if (operation is _AiJobOperation) {
            if (!_sameAccount(operation)) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                  message: '账户已切换，已丢弃原请求。',
                ),
              );
              return;
            }
          } else {
            final token = _tokenProvider?.call();
            if (token != null && token.isNotEmpty) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
      ),
    );
  }
  final Dio _client;
  final String _jobApiPath;
  final String? _deviceToken;
  final String? Function()? _tokenProvider, _csrfProvider;
  static const _jobScopeKey = 'sera.ai-job.scope';
  _AiJobOperation? _planningOperation, _understandingOperation;
  final CancelToken _lifetime = CancelToken();
  String _planningTimeZone = 'Asia/Hong_Kong';
  void usePlanningTimeZone(String timeZone) => _planningTimeZone = timeZone;

  bool _sameAccount(_AiJobOperation operation) =>
      _tokenProvider?.call() == operation.authToken &&
      _csrfProvider?.call() == operation.csrfToken;

  Options _jobOptions(_AiJobOperation operation) => Options(
    extra: {_jobScopeKey: operation},
    headers: {
      if (_deviceToken != null) 'X-Sera-Device': _deviceToken,
      if (operation.authToken?.isNotEmpty == true)
        'Authorization': 'Bearer ${operation.authToken}',
      if (operation.csrfToken?.isNotEmpty == true)
        'X-CSRF-Token': operation.csrfToken,
    },
  );

  void _cancelOperation(_AiJobOperation? operation) {
    if (operation == null) return;
    operation.cancelToken.cancel();
    final id = operation.jobId;
    if (id != null && !operation.cancelSent && _sameAccount(operation)) {
      operation.cancelSent = true;
      unawaited(
        _client
            .post<dynamic>(
              '$_jobApiPath/${Uri.encodeComponent(id)}/cancel',
              data: <String, dynamic>{},
              options: _jobOptions(operation),
            )
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void cancelPlanning() {
    final operation = _planningOperation;
    _planningOperation = null;
    _cancelOperation(operation);
  }

  @override
  void cancelUnderstanding() {
    final operation = _understandingOperation;
    _understandingOperation = null;
    _cancelOperation(operation);
  }

  void dispose() {
    _lifetime.cancel();
    cancelPlanning();
    cancelUnderstanding();
  }

  Future<Json> syncOperations(Json payload) => _request(() async {
    final body = Map<String, dynamic>.from(
      (await _client.post<dynamic>(
            '/api/v1/sync/operations',
            data: payload,
            cancelToken: _lifetime,
          )).data
          as Map,
    );
    _decode(body);
    return body;
  });
  final Future<void> Function()? _onUnauthorized;
  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) => _request(() async {
    final body = await _runPlanningJob(
      kind: 'plan',
      requestId: requestId ?? 'plan-${DateTime.now().microsecondsSinceEpoch}',
      input: {
        'title': title,
        'deadline': deadline.toUtc().toIso8601String(),
        'dailyBudget': dailyBudget,
        'notes': notes,
        'prompt': prompt,
        'timeZone': _planningTimeZone,
      },
    );
    if (body is! Map ||
        body['source'] != 'siliconflow' ||
        body['model'] is! String ||
        body['tasks'] is! List ||
        (body['tasks'] as List).isEmpty) {
      throw const RepositoryException('AI 接口返回内容不完整，请重新生成。');
    }
    final tasks = (body['tasks'] as List).map((item) {
      if (item is! Map ||
          item['title'] is! String ||
          item['notes'] is! String ||
          item['estimatedMinutes'] is! int ||
          item['checklist'] is! List) {
        throw const RepositoryException('AI 任务格式不符合要求，请重新生成。');
      }
      return TaskOutline(
        title: item['title'] as String,
        notes: item['notes'] as String,
        estimatedMinutes: item['estimatedMinutes'] as int,
        checklist: List<String>.from(item['checklist'] as List),
        phase: item['phase'] as String? ?? '',
        notBefore: _planDate(item['notBefore']),
        deadline: _planDate(item['deadline']),
      );
    }).toList();
    return AiPlanResult(tasks: tasks, model: body['model'] as String);
  }, planningRequest: true);

  DateTime? _planDate(Object? value) {
    if (value == null) return null;
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null || !parsed.isUtc) {
      throw const RepositoryException('AI 阶段时间格式不符合要求，请重新生成。');
    }
    return parsed;
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) => _request(() async {
    final body = await _runPlanningJob(
      kind: 'understand',
      requestId: requestId,
      input: input,
      onStage: onStage,
    );
    if (body is! Map) {
      throw const RepositoryException('AI 理解结果不完整，请重试。');
    }
    return AiUnderstanding.fromJson(Map<String, dynamic>.from(body));
  }, planningRequest: true);

  Future<dynamic> _runPlanningJob({
    required String kind,
    required String requestId,
    required Json input,
    void Function(String stage)? onStage,
  }) async {
    if (_lifetime.isCancelled) {
      throw const RepositoryException('当前工作区已关闭。');
    }
    if (requestId.isEmpty || requestId.length > 128) {
      throw const RepositoryException('AI 请求标识无效，请重新开始。');
    }
    final understanding = kind == 'understand';
    final current = understanding
        ? _understandingOperation
        : _planningOperation;
    if (current != null) {
      throw const RepositoryException('请等待当前 AI 请求完成，或先取消。');
    }
    // Freeze the submitted payload before asynchronous interceptors run. Resume
    // must reuse the exact request, even if an editor changes its local map.
    final frozenInput = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(input)) as Map,
    );
    final operation = _AiJobOperation(
      authToken: _tokenProvider?.call(),
      csrfToken: _csrfProvider?.call(),
    );
    if (understanding) {
      _understandingOperation = operation;
    } else {
      _planningOperation = operation;
    }
    final token = operation.cancelToken;
    void ensureActive() {
      if (_lifetime.isCancelled ||
          token.isCancelled ||
          !_sameAccount(operation)) {
        _cancelOperation(operation);
        throw const RepositoryException(
          '操作已取消，输入已保留。',
          details: {'planningJobTerminal': true, 'jobStatus': 'canceled'},
        );
      }
    }

    Json decodeJob(dynamic body, {String? expectedId}) {
      if (body is! Map || body['job'] is! Map) {
        throw const RepositoryException(
          'AI 作业响应不完整，请重试恢复。',
          details: {'planningJobRecoverable': true},
        );
      }
      final job = Map<String, dynamic>.from(body['job'] as Map);
      final id = job['id'];
      if (id is! String ||
          id.isEmpty ||
          (expectedId != null && id != expectedId) ||
          job['kind'] != kind ||
          !const [
            'queued',
            'pending',
            'running',
            'succeeded',
            'failed',
            'canceled',
          ].contains(job['status'])) {
        throw const RepositoryException(
          'AI 作业标识或状态无效，请重试恢复。',
          details: {'planningJobRecoverable': true},
        );
      }
      return job;
    }

    try {
      ensureActive();
      onStage?.call(understanding ? '正在提交理解请求' : '正在提交规划请求');
      final response = await _client.post<dynamic>(
        _jobApiPath,
        cancelToken: token,
        options: _jobOptions(operation),
        data: {'kind': kind, 'requestId': requestId, 'input': frozenInput},
      );
      var job = decodeJob(response.data);
      final id = job['id'] as String;
      operation.jobId = id;
      ensureActive();
      final started = DateTime.now();
      while (!const [
        'succeeded',
        'failed',
        'canceled',
      ].contains(job['status'])) {
        ensureActive();
        onStage?.call(
          const ['queued', 'pending'].contains(job['status'])
              ? '等待模型处理'
              : understanding
              ? '模型正在理解你的描述'
              : '模型正在拆解目标',
        );
        if (DateTime.now().difference(started) > const Duration(seconds: 90)) {
          _cancelOperation(operation);
          throw const RepositoryException(
            'AI 处理超时，输入已保留，请稍后重试。',
            details: {'planningJobTerminal': true, 'jobStatus': 'canceled'},
          );
        }
        // Cancellation also releases the polling delay, including on sign-out.
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 400)),
          token.whenCancel.then<void>((_) {}),
        ]);
        ensureActive();
        final result = await _client.get<dynamic>(
          '$_jobApiPath/${Uri.encodeComponent(id)}',
          cancelToken: token,
          options: _jobOptions(operation),
        );
        ensureActive();
        job = decodeJob(result.data, expectedId: id);
      }
      ensureActive();
      if (job['status'] == 'canceled') {
        throw const RepositoryException(
          '已取消，输入已保留。',
          details: {'planningJobTerminal': true, 'jobStatus': 'canceled'},
        );
      }
      if (job['status'] == 'failed') {
        final error = job['error'];
        throw RepositoryException(
          error is Map
              ? '${error['message'] ?? error['error'] ?? 'AI 处理失败，请重试。'}'
              : error is String
              ? error
              : 'AI 处理失败，请重试。',
          details: {
            'planningJobTerminal': true,
            'jobStatus': 'failed',
            if (job['errorCode'] is String) 'code': job['errorCode'],
          },
        );
      }
      return job['result'];
    } catch (error) {
      if (error is RepositoryException) rethrow;
      // A late 401 from an old account must not invalidate the active account.
      ensureActive();
      rethrow;
    } finally {
      if (understanding && identical(_understandingOperation, operation)) {
        _understandingOperation = null;
      } else if (!understanding && identical(_planningOperation, operation)) {
        _planningOperation = null;
      }
    }
  }

  @override
  String get mode => 'HTTP 接口';

  Future<T> _request<T>(
    Future<T> Function() action, {
    bool planningRequest = false,
  }) async {
    try {
      return await action();
    } on RepositoryException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const RepositoryException(
          '操作已取消，输入已保留。',
          details: {'jobStatus': 'canceled'},
        );
      }
      if (error.response?.statusCode == 401) {
        if (_deviceToken != null) {
          throw const RepositoryException('设备请求暂时无法验证，请重新打开后重试。');
        }
        await _onUnauthorized?.call();
        throw const RepositoryException('登录已过期，请重新登录。');
      }
      if (error.response?.statusCode == 409) {
        throw RepositoryException(
          '服务器数据已有更新，请比较后处理。',
          conflict: true,
          details: error.response?.data is Map
              ? Map<String, dynamic>.from(error.response!.data as Map)
              : const {},
        );
      }
      final body = error.response?.data;
      final message = body is Map ? body['error'] : null;
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw RepositoryException(
          '接口请求超时，请检查连接后重试。',
          offline: true,
          details: {if (planningRequest) 'planningJobRecoverable': true},
        );
      }
      throw RepositoryException(
        message is String ? message : '无法连接业务接口，请检查服务地址及网络后重试。',
        offline:
            error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.unknown && error.response == null,
        details: {
          if (planningRequest &&
              (error.response == null ||
                  (error.response?.statusCode ?? 0) >= 500 ||
                  error.response?.statusCode == 429))
            'planningJobRecoverable': true,
        },
      );
    } catch (_) {
      throw const RepositoryException('接口返回的数据格式不正确，无法完成操作。');
    }
  }

  Workspace? _decode(dynamic response) {
    if (response is! Map || !response.containsKey('workspace')) {
      throw const RepositoryException('接口缺少 workspace 字段。');
    }
    final value = response['workspace'];
    if (value == null) {
      _planningTimeZone = 'Asia/Hong_Kong';
      return null;
    }
    if (value is! Map || !const [1, 2].contains(value['schemaVersion'])) {
      throw const RepositoryException('接口数据版本不受支持。');
    }
    final workspace = Workspace.fromJson(Map<String, dynamic>.from(value));
    _planningTimeZone = workspace.preferences.timeZone;
    return workspace;
  }

  @override
  Future<Workspace?> load() => _request(
    () async => _decode((await _client.get<dynamic>('/api/v1/workspace')).data),
  );

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) => _request(() async {
    final response = await _client.put<dynamic>(
      '/api/v1/workspace',
      data: {
        'workspace': workspace.copyWith(revision: expectedRevision).toJson(),
        'expectedRevision': expectedRevision,
      },
    );
    final saved = _decode(response.data);
    if (saved == null || saved.revision != expectedRevision + 1) {
      throw const RepositoryException('服务器未确认最新版本，请刷新核对保存结果。');
    }
    return saved;
  });

  @override
  Future<void> clear() => _request(() async {
    await _client.delete<dynamic>('/api/v1/workspace');
    _planningTimeZone = 'Asia/Hong_Kong';
  });
}

class _AiJobOperation {
  _AiJobOperation({required this.authToken, required this.csrfToken});
  final String? authToken, csrfToken;
  final CancelToken cancelToken = CancelToken();
  String? jobId;
  bool cancelSent = false;
}
