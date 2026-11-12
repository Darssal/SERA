import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/sera_controller.dart';
import '../../data/auth_repository.dart';
import '../../data/planning_ai_provider.dart';
import '../../data/workspace_repository.dart';
import '../../domain/models.dart';
import '../core/sera_flow_return.dart';
import '../core/sera_widgets.dart';
import '../core/sera_motion.dart';
import 'main_screens.dart';
import 'platform_screens.dart';
import 'voice_screens.dart';

/// Native Flutter implementations of the planning and supporting state screens.
Widget buildPlanningScreen(String id, {String? draftId, String? taskId}) {
  final canonical = _planningIds[id.split('-').first.padLeft(2, '0')] ?? id;
  return _PlanningScreen(
    key: ValueKey('$canonical:$draftId:$taskId'),
    id: canonical,
    draftId: draftId,
    taskId: taskId,
  );
}

const _planningIds = {
  '01': '01-welcome',
  '02': '02-preferences',
  '03': '03-connect',
  '05': '05-assistant',
  '06': '06-clarify',
  '07': '07-generating',
  '08': '08-plan',
  '10': '08-plan',
  '11': '11-applied',
  '22': '22-replan',
  '23': '23-replan-diff',
  '34': '34-history',
  '37': '37-empty-today',
  '38': '38-empty-goals',
  '39': '39-ai-error',
  '40': '40-offline',
  '41': '41-calendar-permission',
  '42': '42-partial-sync',
  '44': '44-discard',
  '48': '48-stale-plan',
  '49': '49-loading',
  '50': '50-voice',
  '51': '51-writing',
  '52': '52-adjusted',
  '53': '53-undo-conflict',
  '54': '54-notification-permission',
  '55': '55-draft-saved',
};

class _PlanningInput {
  String prompt = '';
  String title = '';
  String notes = '';
  DateTime? deadline;
  int? dailyBudget;
}

class _OriginalInputEditor extends StatefulWidget {
  const _OriginalInputEditor({required this.initialText});
  final String initialText;

  @override
  State<_OriginalInputEditor> createState() => _OriginalInputEditorState();
}

class _OriginalInputEditorState extends State<_OriginalInputEditor> {
  late final controller = TextEditingController(text: widget.initialText);
  bool _sent = false;

  void _send() {
    final text = controller.text.trim();
    if (_sent || text.isEmpty) return;
    _sent = true;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(text);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改原文'),
    content: SizedBox(
      width: 350,
      child: SeraInput(
        label: '这次想处理什么？',
        controller: controller,
        minLines: 2,
        maxLines: 6,
        maxLength: PlanningMessage.maxTextLength,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, _) => TextButton(
          onPressed: value.text.trim().isEmpty || _sent ? null : _send,
          child: const Text('保存并重新理解'),
        ),
      ),
    ],
  );
}

class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.waiting,
    required this.onSend,
    required this.onVoice,
    required this.hasMessages,
    required this.initialHint,
  });
  final TextEditingController controller;
  final bool waiting, hasMessages;
  final String initialHint;
  final VoidCallback onSend, onVoice;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      IconButton(
        key: const ValueKey('planning-chat-voice'),
        tooltip: '语音输入',
        onPressed: waiting ? null : onVoice,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: const SeraIcon('mic'),
      ),
      Expanded(
        child: TextField(
          key: const ValueKey('planning-chat-composer'),
          controller: controller,
          minLines: 1,
          maxLines: 4,
          maxLength: PlanningMessage.maxTextLength,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) {
            if (!waiting && controller.text.trim().isNotEmpty) onSend();
          },
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          style: const TextStyle(fontSize: 15, height: 22 / 15),
          decoration: InputDecoration(
            hintText: hasMessages ? '继续补充…' : initialHint,
            counterText: '',
          ),
        ),
      ),
      const SizedBox(width: 8),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, _) => IconButton.filled(
          key: const ValueKey('planning-chat-send'),
          tooltip: '发送消息',
          onPressed: waiting || value.text.trim().isEmpty ? null : onSend,
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor: SeraColors.brand,
            foregroundColor: Colors.white,
            disabledBackgroundColor: SeraColors.line,
          ),
          icon: const Icon(Icons.arrow_upward),
        ),
      ),
    ],
  );
}

class _PlanningScreen extends StatefulWidget {
  const _PlanningScreen({
    super.key,
    required this.id,
    this.draftId,
    this.taskId,
  });
  final String id;
  final String? draftId, taskId;
  @override
  State<_PlanningScreen> createState() => _PlanningScreenState();
}

class _DraftMenuOwner {
  const _DraftMenuOwner({
    required this.draftId,
    required this.taskId,
    required this.controller,
    required this.accountId,
    required this.sessionId,
    required this.route,
    required this.auth,
    required this.authSession,
  });
  final String draftId, taskId, accountId;
  final String? sessionId;
  final SeraController controller;
  final ModalRoute<dynamic>? route;
  final AuthRepository? auth;
  final AuthSession? authSession;
}

class _PlanningScreenState extends State<_PlanningScreen>
    with WidgetsBindingObserver {
  _PlanningInput _input = _PlanningInput();
  SeraController? _sessionController;
  String? _sessionId, _accountId;
  final _draftMenuOwners = <(String, String), _DraftMenuOwner>{};
  String _sessionStage = 'input';
  String? _sessionDraftId, _sessionSaveError;
  String? _sessionRequestId, _sessionRequestNotes, _generationFailure;
  String? _sessionTargetTaskId;
  int? _sessionBaseTaskRevision;
  Timer? _saveTimer;
  final _discardFocus = FocusScopeNode(
    debugLabel: 'draft-exit-confirmation',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  bool _restoring = false, _dirty = false;
  bool _allowSessionPop = false, _leavingSession = false;
  String? _loadedLocation;
  late final TextEditingController _prompt = TextEditingController(
    text: _input.prompt,
  );
  late final TextEditingController _title = TextEditingController(
    text: _input.title,
  );
  late final TextEditingController _notes = TextEditingController(
    text: _input.notes,
  );
  final _supplement = TextEditingController();
  final _chatEnd = GlobalKey();
  final _messages = <PlanningMessage>[];
  AiUnderstanding? _understanding;
  Json? _understandingInput;
  String? _understandingRequestId, _understandingError, _eventSaveError;
  final _clarificationAnswers = <String, String>{};
  bool _understandingPending = false, _deadlineIsDateOnly = false;
  final _autoSubmittedSessions = <String>{};
  String? _selectedReplanEntryId;
  int _understandingEpoch = 0;
  int _sessionEditEpoch = 0;
  final _formKey = GlobalKey<FormState>();
  bool _initialized = false;
  bool _restoredAfterLoading = false;
  bool _startedFromRoute = false;
  bool _submitting = false;
  bool _openingCommit = false;
  bool _adjustmentUndoPending = false;
  bool _writingStarted = false;
  String? _writeError;
  late SeraPreferences _preferences;
  DateTime? _deadline;
  int _budget = 90;
  String _historyTab = 'sessions';
  (SeraController, String)? _historyOwner;

  SeraController get _c => context.read<SeraController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prompt.addListener(_promptChanged);
    _supplement.addListener(_queueSessionSave);
    for (final controller in [_title, _notes]) {
      controller.addListener(_queueSessionSave);
    }
  }

  void _promptChanged() {
    if (!_initialized || _restoring || !_editableSession) return;
    _understandingEpoch++;
    if (_understandingPending) _c.cancelUnderstanding();
    setState(() {
      _understandingPending = false;
      _understanding = null;
      _understandingInput = null;
      _understandingRequestId = null;
      _understandingError = null;
      _clarificationAnswers.clear();
      _restoring = true;
      _title.clear();
      _restoring = false;
      _sessionStage = 'input';
      // Results from a different description must not seed the next request.
      _deadline = null;
      _deadlineIsDateOnly = false;
      _messages.clear();
      _seedChatMessages();
    });
    _queueSessionSave();
  }

  bool get _editableSession =>
      const {'05-assistant', '06-clarify'}.contains(widget.id);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        _editableSession &&
        _initialized &&
        _dirty) {
      unawaited(
        _persistSession().catchError((Object error) {
          if (mounted) setState(() => _sessionSaveError = '$error');
        }),
      );
    }
  }

  void _queueSessionSave({bool understandingEdited = false}) {
    if (!_initialized || _restoring || !_editableSession) return;
    if (!_understandingPending &&
        _understandingRequestId != null &&
        (understandingEdited || _notes.text != _input.notes)) {
      // Editing a recovered request starts a new interpretation. An unchanged
      // recovery keeps its original payload and reference time.
      setState(() {
        _understandingRequestId = null;
        _understandingInput = null;
        _understandingError = null;
        if (_sessionStage == 'understanding') {
          _sessionStage = _understanding == null ? 'input' : 'understood';
        }
      });
    }
    if (_sessionStage == 'generating' && _sessionRequestId != null) {
      // Editing confirmed inputs creates a new request, never a different
      // payload under the previous job's idempotency key.
      _sessionRequestId = null;
      _sessionRequestNotes = null;
      _sessionStage = 'clarify';
      _generationFailure = null;
    }
    _dirty = true;
    _sessionEditEpoch++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      unawaited(
        _persistSession().catchError((Object error) {
          if (mounted) setState(() => _sessionSaveError = '$error');
        }),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = _c;
    final location = GoRouterState.of(context).uri.toString();
    if (!_initialized ||
        (!c.loading && !_restoredAfterLoading) ||
        _accountId != c.accountId ||
        !identical(_sessionController, c) ||
        _loadedLocation != location) {
      _saveTimer?.cancel();
      _understandingEpoch++;
      _understandingPending = false;
      _loadedLocation = location;
      _selectedReplanEntryId = null;
      _restoring = true;
      _accountId = c.accountId;
      _sessionController = c;
      _input = _PlanningInput();
      final query = GoRouterState.of(context).uri.queryParameters;
      final prompt = widget.id == '05-assistant' ? query['prompt'] : null;
      final fresh = query['new'] == '1' || prompt?.trim().isNotEmpty == true;
      final saved = fresh
          ? null
          : query['sessionId'] != null
          ? c.planningSession(query['sessionId'])
          : widget.draftId != null
          ? c.data.planningSessions
                .where((s) => s.draftId == widget.draftId)
                .firstOrNull
          : widget.taskId != null
          ? null
          : c.planningSession();
      _sessionId = saved?.id ?? c.newId('planning');
      _sessionStage = saved?.stage ?? 'input';
      _sessionDraftId = saved?.draftId;
      _sessionRequestId = saved?.aiRequestId;
      _sessionRequestNotes = saved?.aiRequestNotes;
      _generationFailure = saved?.aiError;
      _sessionTargetTaskId = saved?.targetTaskId ?? widget.taskId;
      _sessionBaseTaskRevision = saved?.baseTaskRevision;
      _input
        ..prompt = saved?.prompt ?? ''
        ..title = saved?.title ?? ''
        ..notes = saved?.notes ?? ''
        ..deadline = saved?.deadline
        ..dailyBudget = saved?.dailyBudget;
      _prompt.text = _input.prompt;
      _title.text = _input.title;
      _notes.text = _input.notes;
      _supplement.text = saved?.composerDraft ?? '';
      _restoreUnderstanding(saved);
      if (prompt?.trim().isNotEmpty == true) _usePrompt(prompt!);
      _restoreMessages(saved);
      _preferences = c.data.preferences;
      _budget = _input.dailyBudget ?? _preferences.dailyBudget;
      _deadline = _input.deadline;
      _initialized = true;
      _restoredAfterLoading = !c.loading;
      _dirty = false;
      _restoring = false;
    }
    final query = GoRouterState.of(context).uri.queryParameters;
    if (widget.id == '05-assistant' &&
        query['submit'] == '1' &&
        !c.loading &&
        !c.busy &&
        _sessionStage == 'input' &&
        _prompt.text.trim().isNotEmpty &&
        _sessionId != null &&
        _autoSubmittedSessions.add(_sessionId!)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentRoute && _sessionStage == 'input') {
          unawaited(_understand());
        }
      });
    }
    if (widget.id == '51-writing' && !_writingStarted) {
      _writingStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentRoute) _commitDraft();
      });
    }
    if (widget.id == '07-generating' &&
        !_startedFromRoute &&
        !c.loading &&
        !c.busy &&
        _sessionStage == 'generating' &&
        _sessionRequestId != null &&
        GoRouterState.of(context).uri.queryParameters['start'] == '1') {
      _startedFromRoute = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentRoute) _generate(validate: false, resume: true);
      });
    }
  }

  @override
  void dispose() {
    _draftMenuOwners.clear();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _discardFocus.dispose();
    _prompt.dispose();
    _title.dispose();
    _notes.dispose();
    _supplement.dispose();
    _understandingEpoch++;
    // The persisted request can be resumed after leaving; disposing this view
    // only prevents its late completion from changing a different route.
    super.dispose();
  }

  PlanDraft? _draft(SeraController c) {
    if (widget.draftId != null) return c.draft(widget.draftId);
    if (_sessionDraftId != null) return c.draft(_sessionDraftId);
    if (_sessionRequestId != null) {
      return c.data.drafts
          .where((d) => d.aiRequestId == _sessionRequestId)
          .firstOrNull;
    }
    // A recovered progress screen must never open another session's last plan.
    if (widget.id == '07-generating') return null;
    return c.data.drafts.isEmpty ? null : c.data.drafts.last;
  }

  SeraTask? _task(SeraController c) {
    if (widget.taskId != null) return c.task(widget.taskId);
    for (final task in c.data.tasks) {
      if (!task.done && c.entryForTask(task.id) != null) return task;
    }
    return c.data.tasks.isEmpty ? null : c.data.tasks.first;
  }

  Future<void> _open(
    String id, {
    String? draftId,
    String? taskId,
    String? sessionId,
    String? from,
    bool fresh = false,
  }) {
    if (!_isCurrentRoute) return Future<void>.value();
    final target = id.split('-').first.padLeft(2, '0');
    final query = <String, String>{
      'draftId': ?draftId,
      'taskId': ?taskId,
      if (target != '19' && target != '16')
        if (sessionId ?? _sessionId case final String sid) 'sessionId': sid,
      if (fresh) 'new': '1',
      if (from ?? _planningOrigin case final String origin) 'from': origin,
    };
    final location = Uri(path: '/$id', queryParameters: query).toString();
    late Future<Object?> navigation;
    final currentStep = widget.id.split('-').first;
    final intermediate =
        target == '09' ||
        target == '51' ||
        const {
              '05',
              '06',
              '07',
              '08',
              '10',
              '22',
              '23',
              '39',
              '44',
              '48',
              '51',
            }.contains(currentStep) &&
            const {'06', '07', '08', '10', '39', '44', '48'}.contains(target);
    if (intermediate) {
      // Retain the Flutter pages needed by the pending operation without
      // recording every planning step as a browser Back destination.
      Router.neglect(context, () {
        navigation = context.push<Object?>(
          location,
          extra: const {'replaceHistoryOnExit': true},
        );
      });
    } else {
      navigation = context.push<Object?>(location);
    }
    return navigation.then((_) {
      if (!mounted || !_editableSession) return;
      final saved = _c.planningSession(_sessionId);
      _restoring = true;
      _prompt.text = saved?.prompt ?? '';
      _title.text = saved?.title ?? '';
      _notes.text = saved?.notes ?? '';
      _supplement.text = saved?.composerDraft ?? '';
      _input.prompt = _prompt.text;
      _input.title = _title.text;
      _input.notes = _notes.text;
      _budget = saved?.dailyBudget ?? _c.data.preferences.dailyBudget;
      _deadline = saved?.deadline;
      _restoreUnderstanding(saved);
      _restoreMessages(saved);
      _sessionStage = saved?.stage ?? 'input';
      _sessionDraftId = saved?.draftId;
      _sessionRequestId = saved?.aiRequestId;
      _sessionRequestNotes = saved?.aiRequestNotes;
      _generationFailure = saved?.aiError;
      _sessionTargetTaskId = saved?.targetTaskId;
      _sessionBaseTaskRevision = saved?.baseTaskRevision;
      if (saved == null) _sessionId = _c.newId('planning');
      _dirty = false;
      _restoring = false;
      setState(() {});
    });
  }

  bool get _isCurrentRoute {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final local = GoRouterState.of(context);
    final top = GoRouter.of(context).state;
    // GoRouter changes its stack before Navigator finishes the reverse frame.
    // A departing route can still report isCurrent during this narrow window.
    return local.pageKey == top.pageKey && local.uri == top.uri;
  }

  bool get _ownsGenerationRoute {
    if (!mounted || _c.accountId != _accountId) return false;
    // currentConfiguration.uri represents the declarative base on push().
    // state.uri resolves the actual top imperative match instead.
    final uri = GoRouter.of(context).state.uri;
    return uri.pathSegments.firstOrNull?.split('-').first == '07' &&
        (uri.queryParameters['sessionId'] == _sessionId ||
            (uri.queryParameters['sessionId'] == null &&
                widget.id == '07-generating' &&
                _isCurrentRoute));
  }

  String? get _planningOrigin {
    final value = GoRouterState.of(context).uri.queryParameters['from'];
    if (const {
      'today',
      'tasks',
      'goals',
      'history',
      'search',
    }.contains(value)) {
      return value;
    }
    return switch (widget.id) {
      '37-empty-today' => 'today',
      '38-empty-goals' => 'goals',
      _ => null,
    };
  }

  String get _planningReturnLocation => switch (_planningOrigin) {
    'today' => '/04',
    'tasks' => '/17?filter=todo',
    'history' => '/34',
    'search' => '/35',
    _ => '/20',
  };

  String get _planningReturnLabel => switch (_planningOrigin) {
    'tasks' || 'goals' => '返回计划',
    'history' => '返回记录',
    'search' => '返回搜索',
    _ => '返回今日',
  };

  void _leaveForOrigin() {
    if (!_isCurrentRoute) return;
    finishSeraFlow(
      context,
      fallback: _planningOrigin == null ? '/04' : _planningReturnLocation,
    );
  }

  void _finishTaskRefinement(String taskId, {bool fromGeneration = false}) {
    if (fromGeneration ? !_ownsGenerationRoute : !_isCurrentRoute) return;
    bool matchesTask(Uri uri) =>
        seraScreenId(uri) == '18' && uri.queryParameters['taskId'] == taskId;
    finishSeraFlow(
      context,
      fallback: Uri(
        path: '/18',
        queryParameters: {'taskId': taskId},
      ).toString(),
      accepts: findSeraFlowReturn(context, accepts: matchesTask) != null
          ? matchesTask
          : null,
    );
  }

  void _go(
    String id, {
    String? draftId,
    String? taskId,
    bool fromGeneration = false,
  }) {
    if (fromGeneration ? !_ownsGenerationRoute : !_isCurrentRoute) return;
    final query = <String, String>{};
    if (_planningOrigin case final String origin) query['from'] = origin;
    if (_sessionId != null) query['sessionId'] = _sessionId!;
    if (draftId != null) {
      query['draftId'] = draftId;
    }
    if (taskId != null) {
      query['taskId'] = taskId;
    }
    final location = Uri(
      path: '/$id',
      queryParameters: query.isEmpty ? null : query,
    ).toString();
    final step = id.split('-').first;
    bool matchesDraft(Uri uri) =>
        seraScreenId(uri) == '08' &&
        draftId != null &&
        uri.queryParameters['draftId'] == draftId;
    if (step == '08' &&
        findSeraFlowReturn(context, accepts: matchesDraft) != null) {
      // Dismissing the leave/conflict sheet resumes the existing draft instead
      // of leaving another copy of it underneath the new route.
      finishSeraFlow(context, fallback: location, accepts: matchesDraft);
    } else if (const {'06', '08', '39', '48'}.contains(step)) {
      // Changing a planning step must retain the page that started the flow.
      // Completion can then restore its actual filters, query and scroll state.
      Router.neglect(context, () => context.replace(location));
    } else {
      context.go(location);
    }
  }

  void _openResult(PlanningResultRef ref) {
    if (!_isCurrentRoute) return;
    context.push(
      Uri(
        path: ref.kind == 'task' ? '/18' : '/15',
        queryParameters: {ref.kind == 'task' ? 'taskId' : 'eventId': ref.id},
      ).toString(),
    );
  }

  Future<void> _openSessionEditor(String kind, {bool manual = false}) async {
    if (manual &&
        _prompt.text.trim().isEmpty &&
        _title.text.trim().isEmpty &&
        _notes.text.trim().isEmpty) {
      if (_supplement.text.trim().isEmpty) {
        if (_isCurrentRoute) {
          Router.neglect(
            context,
            () => context.push(
              kind == 'task' ? '/19' : '/16',
              extra: const {'replaceHistoryOnExit': true},
            ),
          );
        }
        return;
      }
      // Choosing manual entry is an explicit use of the typed text, without AI.
      _prompt.text = _supplement.text.trim();
      _supplement.clear();
    }
    final owner = _c;
    final sessionId = _sessionId;
    await runAction(context, () async {
      await _persistSession(
        stage: _understanding == null ? 'input' : 'understood',
      );
      if (!mounted ||
          !_isCurrentRoute ||
          !identical(_c, owner) ||
          _sessionId != sessionId ||
          _accountId != owner.accountId) {
        return;
      }
      final session = _c.planningSession(_sessionId);
      if (session?.resultEntity != null) {
        _openResult(session!.resultEntity!);
        return;
      }
      Router.neglect(
        context,
        () => context.push(
          Uri(
            path: kind == 'task' ? '/19' : '/16',
            queryParameters: {
              'sessionId': _sessionId!,
              if (_planningOrigin case final String origin) 'from': origin,
              if (manual) 'manual': '1' else 'fromAi': '1',
            },
          ).toString(),
          extra: const {'replaceHistoryOnExit': true},
        ),
      );
    });
  }

  void _saveInputs() {
    _input
      ..prompt = _prompt.text
      ..title = _title.text.trim()
      ..notes = _notes.text
      ..deadline = _deadline
      ..dailyBudget = _budget;
  }

  Future<void> _persistSession({
    String? stage,
    String? draftId,
    bool clearRequest = false,
  }) async {
    _saveTimer?.cancel();
    _saveInputs();
    if (_input.prompt.isEmpty &&
        _input.title.isEmpty &&
        _input.notes.isEmpty &&
        _supplement.text.isEmpty &&
        _messages.isEmpty) {
      return;
    }
    final c = _c;
    final account = c.accountId;
    if (_accountId != account) {
      throw const RepositoryException('账号已切换，请返回后重新输入。');
    }
    _sessionStage = stage ?? _sessionStage;
    _sessionDraftId = draftId ?? _sessionDraftId;
    if (clearRequest) {
      _sessionRequestId = null;
      _sessionRequestNotes = null;
    }
    final value = PlanningSession(
      id: _sessionId ??= c.newId('planning'),
      prompt: _input.prompt,
      title: _input.title,
      notes: _input.notes,
      composerDraft: _supplement.text,
      messages: List.of(_messages),
      deadline: _deadline,
      dailyBudget: _budget,
      stage: _sessionStage,
      draftId: _sessionDraftId,
      aiRequestId: _sessionRequestId,
      aiRequestNotes: _sessionRequestNotes,
      aiError: _understandingError ?? _generationFailure,
      targetTaskId: _sessionTargetTaskId,
      baseTaskRevision: _sessionBaseTaskRevision,
      understanding: _understanding?.toJson(),
      understandingInput: _understandingInput,
      understandingRequestId: _understandingRequestId,
      clarificationAnswers: Map.of(_clarificationAnswers),
      deadlineIsDateOnly: _deadlineIsDateOnly,
      updatedAt: DateTime.now(),
    );
    final editEpoch = _sessionEditEpoch;
    await c.savePlanningSession(value);
    if (!mounted || !identical(_c, c) || _c.accountId != account) return;
    setState(() {
      _sessionSaveError = null;
      _dirty = editEpoch != _sessionEditEpoch;
    });
  }

  Future<void> _saveAndOpen(String id, {String? stage}) async {
    await runAction(context, () async {
      await _persistSession(stage: stage);
      if (mounted) _open(id);
    });
  }

  Future<void> _saveAndBack() async {
    if (_leavingSession) return;
    _leavingSession = true;
    _understandingEpoch++;
    if (_understandingPending) {
      _c.cancelUnderstanding();
      _understandingPending = false;
      _understandingRequestId = null;
      _understandingInput = null;
      _sessionStage = 'understanding_canceled';
    }
    await runAction(context, () async {
      await _persistSession();
      if (mounted) {
        setState(() => _allowSessionPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrentRoute) {
            context.canPop() ? context.pop() : _leaveForOrigin();
          }
        });
      }
    });
    _leavingSession = false;
  }

  void _usePrompt(String value) {
    if (value.trim().isEmpty) return;
    _input.notes = '';
    _notes.text = '';
    _input.dailyBudget = _c.data.preferences.dailyBudget;
    _budget = _input.dailyBudget!;
    _input.prompt = value;
    _prompt.text = value;
    _deadline = null;
    _deadlineIsDateOnly = false;
    _understanding = null;
    _understandingInput = null;
    _understandingRequestId = null;
    _understandingError = null;
  }

  void _restoreUnderstanding(PlanningSession? saved) {
    _understanding = null;
    _understandingInput = saved?.understandingInput;
    _understandingRequestId = saved?.understandingRequestId;
    _understandingError = saved?.stage.startsWith('understanding') == true
        ? saved?.aiError
        : null;
    _deadlineIsDateOnly = saved?.deadlineIsDateOnly ?? false;
    _clarificationAnswers
      ..clear()
      ..addAll(saved?.clarificationAnswers ?? const {});
    if (saved?.understanding != null) {
      try {
        _understanding = AiUnderstanding.fromJson(saved!.understanding!);
      } catch (error) {
        _understandingError = '$error';
      }
    }
  }

  void _seedChatMessages() {
    if (_prompt.text.trim().isNotEmpty) {
      _messages.add(
        PlanningMessage(
          id: _c.newId('message'),
          role: 'user',
          text: _prompt.text.trim(),
        ),
      );
    }
    if (_notes.text.trim().isNotEmpty) {
      _messages.add(
        PlanningMessage(
          id: _c.newId('message'),
          role: 'user',
          text: _notes.text.trim(),
        ),
      );
    }
  }

  void _restoreMessages(PlanningSession? saved) {
    _messages
      ..clear()
      ..addAll(saved?.messages ?? const []);
    if (_messages.isEmpty) {
      _seedChatMessages();
      if (_understanding case final result?) {
        _messages.add(
          PlanningMessage(
            id: _c.newId('message'),
            role: 'assistant',
            text: result.summary,
            understanding: result.toJson(),
          ),
        );
      }
    }
    _scrollChatToEnd();
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final end = _chatEnd.currentContext;
      if (!mounted || !_isCurrentRoute || end == null) return;
      unawaited(
        Scrollable.ensureVisible(
          end,
          alignment: 1,
          duration: SeraMotion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
        ),
      );
    });
  }

  bool _currentUnderstanding(int epoch, String account, String session) =>
      mounted &&
      epoch == _understandingEpoch &&
      identical(_c, _sessionController) &&
      _c.accountId == account &&
      _sessionId == session;

  Future<void> _understand({
    bool resume = false,
    bool clarify = false,
    bool supplement = false,
  }) async {
    final c = _c;
    if (_understandingPending || c.understanding || c.busy) return;
    if (_messages.length >= PlanningSession.maxMessages) {
      setState(() => _understandingError = '对话已达到上限，请保存当前事项后开始新的输入。');
      return;
    }
    if (_prompt.text.trim().isEmpty) {
      setState(() => _understandingError = '请先写下你想处理的事情。');
      return;
    }
    if (clarify &&
        !supplement &&
        !_clarificationAnswers.values.any((value) => value.trim().isNotEmpty)) {
      setState(() => _understandingError = '请先补充至少一项回答。');
      return;
    }
    final account = c.accountId;
    final session = _sessionId ??= c.newId('planning');
    final epoch = ++_understandingEpoch;
    if (!resume ||
        _understandingRequestId == null ||
        _understandingInput == null) {
      final previous = _understanding?.toJson();
      if (clarify && previous != null) {
        previous['clarificationAnswers'] = Map.of(_clarificationAnswers);
      }
      _understandingInput = c.createUnderstandingInput(
        prompt: _prompt.text,
        notes: _notes.text,
        previous: clarify ? previous : null,
      );
      _understandingRequestId = c.newId('ai-understand');
    }
    setState(() {
      _understandingPending = true;
      _understandingError = null;
      _eventSaveError = null;
      _generationFailure = null;
    });
    final requestId = _understandingRequestId!;
    _scrollChatToEnd();
    try {
      // Persist the exact request before submitting. Recovery reuses its key,
      // original reference time and answers instead of starting a second job.
      await _persistSession(stage: 'understanding');
      if (!_currentUnderstanding(epoch, account, session)) return;
      final result = await c.understandInput(
        input: _understandingInput!,
        requestId: _understandingRequestId!,
      );
      if (!_currentUnderstanding(epoch, account, session)) return;
      final zone = c.data.preferences.timeZone;
      final hasDeadline = const ['goal', 'task'].contains(result.intent);
      _restoring = true;
      setState(() {
        _understanding = result;
        _title.text = result.title;
        _deadline = !hasDeadline || result.deadline == null
            ? null
            : inTimeZone(result.deadline!, zone);
        _deadlineIsDateOnly = hasDeadline && result.deadlineIsDateOnly;
        _budget = result.dailyBudget ?? c.data.preferences.dailyBudget;
        _messages.removeWhere((message) => message.id == requestId);
        _messages.add(
          PlanningMessage(
            id: requestId,
            role: 'assistant',
            text: result.summary,
            understanding: result.toJson(),
          ),
        );
        _understandingRequestId = null;
      });
      _restoring = false;
      await _persistSession(stage: 'understood');
      _scrollChatToEnd();
    } catch (error) {
      if (!_currentUnderstanding(epoch, account, session)) return;
      final failure = error is RepositoryException ? error : null;
      final recoverable =
          failure?.offline == true ||
          failure?.details['planningJobRecoverable'] == true;
      _understandingError = '$error';
      if (!recoverable) _understandingRequestId = null;
      try {
        await _persistSession(
          stage: recoverable ? 'understanding' : 'understanding_failed',
        );
      } catch (saveError) {
        if (_currentUnderstanding(epoch, account, session)) {
          _sessionSaveError = '$saveError';
        }
      }
    } finally {
      if (_currentUnderstanding(epoch, account, session)) {
        setState(() => _understandingPending = false);
      }
    }
  }

  Future<void> _sendChatMessage() async {
    final c = _c;
    if (!_isCurrentRoute ||
        _understandingPending ||
        c.understanding ||
        c.busy) {
      return;
    }
    final text = _supplement.text.trim();
    if (text.isEmpty) return;
    final first = _prompt.text.trim().isEmpty;
    final notes = [
      if (_notes.text.trim().isNotEmpty) _notes.text.trim(),
      if (!first) text,
    ].join('\n\n');
    if (_messages.length > PlanningSession.maxMessages - 2 ||
        notes.length > PlanningMessage.maxTextLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本次对话内容较多，请先保存当前事项，再开始新的输入。')),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (first) {
      _prompt.text = text;
    } else {
      _notes.text = notes;
      setState(
        () => _messages.add(
          PlanningMessage(id: c.newId('message'), role: 'user', text: text),
        ),
      );
    }
    _supplement.clear();
    await _understand(clarify: _understanding != null, supplement: true);
  }

  Future<void> _editOriginalInput() async {
    if (!_isCurrentRoute || _understandingPending || _c.busy) return;
    final c = _c;
    final account = c.accountId;
    final session = _sessionId;
    final auth = context.read<AuthRepository?>();
    final authSession = auth?.session;
    final text = await showDialog<String>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (_) => _OriginalInputEditor(initialText: _prompt.text),
    );
    if (text == null ||
        !mounted ||
        !_isCurrentRoute ||
        !identical(_c, c) ||
        c.accountId != account ||
        _sessionId != session ||
        !identical(context.read<AuthRepository?>(), auth) ||
        !identical(auth?.session, authSession)) {
      return;
    }
    _prompt.text = text;
    await _understand();
  }

  Future<void> _cancelUnderstanding() async {
    _understandingEpoch++;
    _c.cancelUnderstanding();
    setState(() {
      _understandingPending = false;
      _understandingRequestId = null;
      _understandingInput = null;
      _understandingError = '已取消理解，输入和补充回答已保留。';
    });
    await runAction(
      context,
      () => _persistSession(stage: 'understanding_canceled'),
    );
  }

  Future<void> _manualGoal() async {
    if (_understandingPending) await _cancelUnderstanding();
    if (!mounted) return;
    if (_prompt.text.trim().isEmpty && _supplement.text.trim().isNotEmpty) {
      _prompt.text = _supplement.text.trim();
      _supplement.clear();
    }
    if (_understanding == null) {
      final raw = _prompt.text.trim();
      _title.text = raw.length > 200 ? raw.substring(0, 200) : raw;
      _deadline = null;
      _deadlineIsDateOnly = false;
    }
    await _saveAndOpen('06-clarify', stage: 'clarify');
  }

  bool get _canGenerateUnderstoodGoal {
    final result = _understanding;
    final deadline = _planningDeadline;
    final now = _c.planningNow;
    return result != null &&
        result.intent == 'goal' &&
        result.questions.isEmpty &&
        _sessionTargetTaskId == null &&
        _sessionRequestId == null &&
        _sessionDraftId == null &&
        _title.text.trim().isNotEmpty &&
        _title.text.trim().length <= 200 &&
        deadline != null &&
        !deadline.isBefore(now) &&
        deadline.difference(dateOnly(now)).inDays <= 366 &&
        _budget >= 15 &&
        _budget <= 480 &&
        _supplement.text.trim().isEmpty &&
        !_understandingPending &&
        _understandingRequestId == null &&
        _understandingError == null &&
        _sessionSaveError == null &&
        _generationFailure == null;
  }

  void _includeGoalUnderstanding(AiUnderstanding result) {
    // Both routes send the same original input, interpretation and answers.
    final additions = [
      result.summary,
      result.outcome,
      ..._clarificationAnswers.entries
          .where((entry) => entry.value.trim().isNotEmpty)
          .map((entry) => '${entry.key}：${entry.value}'),
    ].where((value) => value.trim().isNotEmpty).toSet();
    _notes.text = [
      if (_notes.text.isNotEmpty) _notes.text,
      ...additions.where((value) => !_notes.text.contains(value)),
    ].join('\n\n');
  }

  Future<void> _generateUnderstoodGoal() async {
    if (!_isCurrentRoute ||
        _submitting ||
        _c.busy ||
        !_canGenerateUnderstoodGoal) {
      return;
    }
    _includeGoalUnderstanding(_understanding!);
    await _generate(validate: false);
  }

  Future<void> _acceptUnderstanding() async {
    final result = _understanding;
    if (result == null || _understandingPending) return;
    if (result.intent == 'goal') {
      _includeGoalUnderstanding(result);
      await _saveAndOpen('06-clarify', stage: 'clarify');
      return;
    }
    if (!const ['task', 'event'].contains(result.intent)) return;
    await _openSessionEditor(result.intent);
  }

  bool get _canSaveUnderstoodEvent {
    final result = _understanding;
    return result != null &&
        result.intent == 'event' &&
        result.title.trim().isNotEmpty &&
        result.questions.isEmpty &&
        result.start != null &&
        result.end != null &&
        result.end!.isAfter(result.start!) &&
        _supplement.text.trim().isEmpty &&
        !_understandingPending &&
        _understandingRequestId == null &&
        _understandingError == null &&
        _sessionSaveError == null;
  }

  Future<void> _saveUnderstoodEvent() async {
    if (!_isCurrentRoute ||
        _submitting ||
        _c.busy ||
        !_canSaveUnderstoodEvent) {
      return;
    }
    final owner = _c;
    final account = _accountId;
    final sessionId = _sessionId;
    final result = _understanding!;
    setState(() {
      _submitting = true;
      _eventSaveError = null;
    });
    try {
      await _persistSession(stage: 'understood');
      if (!mounted ||
          !_isCurrentRoute ||
          !identical(_c, owner) ||
          owner.accountId != account ||
          _sessionId != sessionId) {
        return;
      }
      final session = owner.planningSession(sessionId);
      if (session == null) throw const RepositoryException('这条输入已不存在。');
      final notes = <String>{
        if (result.summary.isNotEmpty) result.summary,
        if (result.outcome.isNotEmpty) result.outcome,
        if (session.notes.trim().isNotEmpty) session.notes.trim(),
        ...session.clarificationAnswers.entries
            .where((entry) => entry.value.trim().isNotEmpty)
            .map((entry) => '${entry.key}：${entry.value.trim()}'),
        if (session.prompt.trim().isNotEmpty) '原始输入：${session.prompt.trim()}',
      };
      final saved = await owner.saveEntry(
        CalendarEntry(
          id: owner.planningResultFor(session.id, 'event').id,
          title: result.title.trim(),
          start: result.start!,
          end: result.end!,
          timeZone: owner.data.preferences.timeZone,
          notes: notes.join('\n\n'),
          locked: true,
        ),
        sourceSessionId: session.id,
      );
      if (!mounted ||
          !_isCurrentRoute ||
          !identical(_c, owner) ||
          owner.accountId != account ||
          _sessionId != sessionId) {
        return;
      }
      final entry = owner.entry(saved.id)!;
      final messenger = ScaffoldMessenger.of(context);
      final router = GoRouter.of(context);
      final restored = finishSeraFlow(
        context,
        fallback: Uri(
          path: '/12',
          queryParameters: {'focusEntryId': saved.id},
        ).toString(),
      );
      if (!restored) {
        owner.setSelectedDate(
          inTimeZone(entry.start, owner.data.preferences.timeZone),
        );
      } else {
        showSeraSavedFeedback(
          messenger: messenger,
          router: router,
          message: '已保存：${entry.title} · ${formatDate(entry.start)}',
          location: Uri(
            path: '/15',
            queryParameters: {'eventId': saved.id},
          ).toString(),
          canOpen: () =>
              identical(messenger.context.read<SeraController?>(), owner) &&
              owner.accountId == account &&
              owner.entry(saved.id) != null,
        );
      }
    } catch (error) {
      if (mounted &&
          _isCurrentRoute &&
          identical(_c, owner) &&
          owner.accountId == account &&
          _sessionId == sessionId) {
        setState(() => _eventSaveError = '$error');
      }
    } finally {
      if (mounted && identical(_c, owner) && owner.accountId == account) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _generate({bool validate = true, bool resume = false}) async {
    if (!_isCurrentRoute || _submitting || _c.busy) return;
    if (validate && !(_formKey.currentState?.validate() ?? false)) return;
    if (_deadline == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选择目标截止日期，再生成计划。')));
      return;
    }
    setState(() => _submitting = true);
    final c = _c;
    try {
      _saveInputs();
      if (!resume || _sessionRequestId == null) {
        if (_sessionTargetTaskId != null) {
          final fresh = c.createTaskRefinementSession(
            _sessionTargetTaskId!,
            reason: _input.notes,
          );
          _sessionRequestId = fresh.aiRequestId;
          _sessionRequestNotes = fresh.aiRequestNotes;
          _sessionBaseTaskRevision = fresh.baseTaskRevision;
          _title.text = fresh.title;
          _prompt.text = fresh.prompt;
          _input.title = fresh.title;
          _input.prompt = fresh.prompt;
          _deadline = fresh.deadline!;
          _budget = fresh.dailyBudget;
        } else {
          _sessionRequestId = c.usesRemoteAi ? c.newId('ai-plan') : null;
          _sessionRequestNotes = c.planningRequestNotes(_input.notes);
        }
        _sessionDraftId = null;
      }
      _generationFailure = null;
      final requestId = _sessionRequestId;
      final requestNotes = _sessionRequestNotes;
      await _persistSession(stage: 'generating');
      if (!mounted || !_isCurrentRoute) return;
      if (widget.id != '07-generating') {
        Router.neglect(context, () {
          unawaited(
            context.push(
              Uri(
                path: '/07-generating',
                queryParameters: {
                  'sessionId': _sessionId!,
                  if (_planningOrigin case final String origin) 'from': origin,
                },
              ).toString(),
            ),
          );
        });
      }
      final draft = _sessionTargetTaskId != null
          ? await c.refineTaskPlan(
              _sessionTargetTaskId!,
              reason: _input.notes,
              requestId: requestId,
              requestNotes: requestNotes,
              requestDeadline: _deadline,
              requestDailyBudget: _budget,
              expectedTaskRevision: _sessionBaseTaskRevision,
            )
          : await c.generatePlan(
              title: _input.title,
              deadline: _planningDeadline!,
              dailyBudget: _budget,
              notes: _input.notes,
              prompt: _input.prompt,
              requestId: requestId,
              requestNotes: requestNotes,
            );
      if (mounted) {
        await _persistSession(stage: 'draft', draftId: draft.id);
        if (mounted) {
          _go(
            draft.needsPlanningConfirmation ? '39-ai-error' : '08-plan',
            draftId: draft.id,
            fromGeneration: true,
          );
        }
      }
    } catch (error) {
      if (!mounted) return;
      _generationFailure = '$error';
      final failure = error is RepositoryException ? error : null;
      final canceled =
          failure?.details['jobStatus'] == 'canceled' ||
          failure?.message.contains('取消') == true ||
          failure?.message.contains('停止生成') == true;
      final recoverable =
          !canceled &&
          _sessionRequestId != null &&
          (failure?.offline == true ||
              failure?.details['planningJobRecoverable'] == true);
      try {
        await _persistSession(
          stage: canceled
              ? 'canceled'
              : recoverable
              ? 'generating'
              : 'failed',
          clearRequest: !recoverable,
        );
      } catch (saveError) {
        _sessionSaveError = '$saveError';
        c.error = _generationFailure;
      }
      if (mounted) {
        if (canceled && _sessionTargetTaskId != null) {
          _finishTaskRefinement(_sessionTargetTaskId!, fromGeneration: true);
        } else {
          _go(canceled ? '06-clarify' : '39-ai-error', fromGeneration: true);
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancelGeneration() async {
    _c.cancelGeneration();
    _generationFailure = null;
    await runAction(context, () async {
      await _persistSession(stage: 'canceled', clearRequest: true);
      if (mounted) {
        _sessionTargetTaskId != null
            ? _finishTaskRefinement(_sessionTargetTaskId!)
            : _go('06-clarify');
      }
    });
  }

  Future<void> _modifyGeneration() async {
    _generationFailure = null;
    await runAction(context, () async {
      await _persistSession(stage: 'clarify', clearRequest: true);
      if (mounted) {
        _sessionTargetTaskId != null
            ? _finishTaskRefinement(_sessionTargetTaskId!)
            : _open('06-clarify');
      }
    });
  }

  Future<void> _commitDraft() async {
    if (!_isCurrentRoute || _submitting) return;
    final c = _c;
    final accountId = _accountId;
    final sessionId = _sessionId;
    bool ownsPage() =>
        mounted &&
        identical(_c, c) &&
        c.accountId == accountId &&
        _sessionId == sessionId;
    final draft = _draft(c);
    if (draft == null) {
      setState(() => _writeError = '没有找到这份草案，请重新打开或生成计划。');
      return;
    }
    var confirmLimits = false;
    if (draft.needsPlanningConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (dialogContext) => AlertDialog(
          title: Text(_planningNoticeTitle(draft)),
          content: Text(_planningNotice(draft)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回修改'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(_planningContinueLabel(draft)),
            ),
          ],
        ),
      );
      if (!ownsPage() || !_isCurrentRoute) return;
      if (confirmed != true) {
        _go('08-plan', draftId: draft.id);
        return;
      }
      confirmLimits = true;
    }
    setState(() {
      _submitting = true;
      _writeError = null;
    });
    try {
      if (confirmLimits) await c.confirmDraftPlanningLimits(draft.id);
      await c.commitDraft(draft.id);
      if (ownsPage()) {
        await _persistSession(stage: 'confirmed', draftId: draft.id);
        if (mounted && ownsPage() && _isCurrentRoute) {
          if (draft.targetTaskId != null) {
            final messenger = ScaffoldMessenger.of(context);
            _finishTaskRefinement(draft.targetTaskId!);
            messenger.showSnackBar(const SnackBar(content: Text('执行步骤已更新')));
          } else if (draft.targetGoalId != null) {
            final messenger = ScaffoldMessenger.of(context);
            final goalId = draft.targetGoalId!;
            bool matchesGoal(Uri uri) =>
                seraScreenId(uri) == '21' &&
                uri.queryParameters['goalId'] == goalId;
            finishSeraFlow(
              context,
              fallback: Uri(
                path: '/21',
                queryParameters: {'goalId': goalId},
              ).toString(),
              accepts: findSeraFlowReturn(context, accepts: matchesGoal) != null
                  ? matchesGoal
                  : null,
            );
            messenger.showSnackBar(const SnackBar(content: Text('目标计划已更新')));
          } else {
            final messenger = ScaffoldMessenger.of(context);
            finishSeraFlow(context, fallback: _planningReturnLocation);
            messenger.showSnackBar(const SnackBar(content: Text('目标已创建')));
          }
        }
      }
    } catch (error) {
      if (ownsPage() && _isCurrentRoute) {
        if (error is RepositoryException && error.conflict) {
          _go('48-stale-plan', draftId: draft.id);
        } else {
          setState(() => _writeError = '$error');
        }
      }
    } finally {
      if (ownsPage()) setState(() => _submitting = false);
    }
  }

  Future<void> _pickDeadline() async {
    final date = await SeraMotion.pickDate(
      context: context,
      initialDate: _deadline ?? _c.today,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (date == null || !mounted || !_isCurrentRoute) return;
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_deadline ?? _c.today),
    );
    if (!mounted || time == null || !_isCurrentRoute) return;
    setState(() {
      _deadline = inTimeZone(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
        _c.data.preferences.timeZone,
        wallClock: true,
      );
      _deadlineIsDateOnly = false;
    });
    _saveInputs();
    _queueSessionSave();
  }

  Future<void> _pickTime(bool start) async {
    final minute = start ? _preferences.startMinute : _preferences.endMinute;
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (time == null || !mounted || !_isCurrentRoute) return;
    final selected = time.hour * 60 + time.minute;
    if ((start && selected >= _preferences.endMinute) ||
        (!start && selected <= _preferences.startMinute)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('结束时间需要晚于开始时间。')));
      return;
    }
    setState(
      () => _preferences = start
          ? _preferences.copyWith(startMinute: selected)
          : _preferences.copyWith(endMinute: selected),
    );
  }

  Widget _stack(List<Widget> children, {double gap = 12}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ],
  );

  Widget _copy(
    String text, {
    double size = 15,
    Color? color,
    bool bold = false,
    TextAlign? align,
  }) => Text(
    text,
    textAlign: align,
    style: TextStyle(
      fontSize: size,
      height: 1.5,
      color: color ?? SeraColors.muted,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
    ),
  );

  Widget _footer(
    String label,
    VoidCallback? action, {
    String? secondary,
    VoidCallback? onSecondary,
    String? hint,
    bool busy = false,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SeraButton(label, onPressed: action, busy: busy),
      if (secondary != null) ...[
        const SizedBox(height: 12),
        SeraButton(secondary, onPressed: onSecondary, variant: 'quiet'),
      ],
      if (hint != null) ...[
        const SizedBox(height: 9),
        _copy(hint, size: 12, align: TextAlign.center),
      ],
    ],
  );

  Widget _symbol(String icon, {bool warning = false}) => Center(
    child: Container(
      width: 48,
      height: 48,
      margin: const EdgeInsets.only(top: 24, bottom: 16),
      decoration: BoxDecoration(
        color: warning ? SeraColors.amberBg : SeraColors.mint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: SeraIcon(
          icon,
          size: 24,
          color: warning ? SeraColors.amber : SeraColors.brand,
        ),
      ),
    ),
  );

  Widget _successCopy(String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            height: 4 / 3,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 8),
          _copy(body, align: TextAlign.center),
        ],
      ],
    ),
  );

  Widget _row(
    String title,
    String subtitle,
    String icon, {
    VoidCallback? onTap,
    String? trailing,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SeraIcon(icon, size: 22, color: SeraColors.brand),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _copy(title, size: 16, color: SeraColors.ink, bold: true),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _copy(subtitle, size: 13),
                ],
              ],
            ),
          ),
          if (trailing != null) _copy(trailing, size: 12),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SeraIcon('chevron', size: 16),
            ),
        ],
      ),
    ),
  );

  Widget _fields(List<Widget> children) => SeraCard(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _steps(int active) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 2; i++) ...[
          if (i > 0)
            Container(
              width: 10,
              height: 1,
              margin: const EdgeInsets.fromLTRB(5, 12, 5, 0),
              color: i <= active ? SeraColors.brand : SeraColors.line,
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 25,
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i <= active ? SeraColors.brand : SeraColors.line,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      color: i <= active ? Colors.white : SeraColors.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _copy(
                    ['确认目标', '计划草案'][i],
                    size: 12,
                    color: i == active ? SeraColors.brand : SeraColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _noDraft() => SeraScaffold(
    title: '计划草案',
    body: SeraEmpty(
      '还没有可查看的草案',
      '先描述目标和截止时间，序日会根据可用时段生成一份可编辑的计划。',
      icon: 'book',
      action: '开始规划一个目标',
      onAction: () => _open('05-assistant'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    final session = c.planningSession(_sessionId);
    if (_editableSession && session?.stage == 'confirmed') {
      final result = session!.resultEntity;
      final exists = result == null
          ? c.draft(session.draftId) != null
          : c.hasPlanningResult(result);
      return SeraScaffold(
        title: '已完成的输入',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SeraNote(
              exists ? '这次输入已保存' : '保存的事项已删除',
              body: exists
                  ? session.title.isEmpty
                        ? session.prompt
                        : session.title
                  : '可以开始新的输入。',
              icon: exists ? 'check' : 'warning',
            ),
            if (exists) ...[
              const SizedBox(height: 16),
              SeraButton(
                '查看已保存事项',
                onPressed: () => result == null
                    ? _open('08-plan', draftId: session.draftId)
                    : _openResult(result),
              ),
            ],
            const SizedBox(height: 12),
            SeraButton(
              '开始新的输入',
              variant: 'secondary',
              onPressed: () => _open('05-assistant', fresh: true),
            ),
          ],
        ),
      );
    }
    final page = switch (widget.id) {
      '01-welcome' => _welcome(),
      '02-preferences' => _onboardingPreferences(),
      '03-connect' => _connect(),
      '05-assistant' => _assistant(c),
      '06-clarify' => _clarify(c),
      '07-generating' => _generating(c),
      '08-plan' => _plan(c),
      '11-applied' => _applied(c),
      '22-replan' => _replan(c, confirm: false),
      '23-replan-diff' => _replan(c, confirm: true),
      '34-history' => _history(c),
      '37-empty-today' => const TodayScreen(),
      '38-empty-goals' => const GoalsScreen(),
      '39-ai-error' => _generationError(c),
      '40-offline' => _offline(c),
      '41-calendar-permission' => _permission(),
      '42-partial-sync' => _partialSync(c),
      '44-discard' => _discard(c),
      '48-stale-plan' => _stale(c),
      '49-loading' => _loading(c),
      '50-voice' => _voice(),
      '51-writing' => _writing(c),
      '52-adjusted' => _adjusted(c),
      '53-undo-conflict' => _undoConflict(c),
      '54-notification-permission' => _notificationPermission(c),
      '55-draft-saved' => _saved(c),
      _ => _noDraft(),
    };
    if (const {
      '11-applied',
      '52-adjusted',
      '55-draft-saved',
    }.contains(widget.id)) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leaveForOrigin();
        },
        child: page,
      );
    }
    if (widget.id == '08-plan' &&
        _draft(c) != null &&
        _draft(c)?.status != 'committed') {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _open('44-discard', draftId: _draft(c)?.id);
        },
        child: page,
      );
    }
    return _editableSession
        ? PopScope(
            canPop: _allowSessionPop,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _saveAndBack();
            },
            child: page,
          )
        : page;
  }

  Widget _welcome() => SeraScaffold(
    title: '开始',
    showBack: false,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SeraIntro('把想做的事，\n安排进生活。', subtitle: '从一句想法，到每天踏实的一小步。'),
      ],
    ),
    footer: _footer(
      '开始安排我的一天',
      () => _open('02-preferences'),
      secondary: '先体验一下',
      onSecondary: () => _go('04-today'),
    ),
  );

  Widget _onboardingPreferences() => SeraScaffold(
    title: '你的节奏',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SeraIntro('设置可安排的时间', eyebrow: '第 1 步，共 2 步'),
        const SeraSection('哪些日子可以安排？'),
        SeraWeekdayPicker(
          selected: _preferences.weekdays,
          onChanged: (days) => setState(
            () => _preferences = _preferences.copyWith(weekdays: days),
          ),
        ),
        const SeraSection('一天里的专注时段'),
        SeraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _copy('优先专注时段', size: 13),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => _pickTime(true),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        _minute(_preferences.startMinute),
                        style: const TextStyle(
                          fontSize: 24,
                          color: SeraColors.brand,
                        ),
                      ),
                    ),
                  ),
                  const Text('—', style: TextStyle(color: SeraColors.brand)),
                  Expanded(
                    child: TextButton(
                      onPressed: () => _pickTime(false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        _minute(_preferences.endMinute),
                        style: const TextStyle(
                          fontSize: 24,
                          color: SeraColors.brand,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _fields([
          SeraField('每日规划目标', '$_budget 分钟'),
          Slider(
            value: _budget.toDouble().clamp(15, 480),
            min: 15,
            max: 480,
            divisions: 93,
            label: '$_budget 分钟',
            onChanged: (v) => setState(() => _budget = v.round()),
          ),
          SeraField('事项之间留出', '${_preferences.bufferMinutes} 分钟缓冲'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in ({
                0,
                5,
                10,
                15,
                30,
                _preferences.bufferMinutes,
              }.toList()..sort()))
                ChoiceChip(
                  label: Text('$n 分钟'),
                  selected: _preferences.bufferMinutes == n,
                  onSelected: (_) => setState(
                    () =>
                        _preferences = _preferences.copyWith(bufferMinutes: n),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SeraField(
            '午间休息',
            '${_minute(_preferences.restStart)}–${_minute(_preferences.restEnd)}',
          ),
        ]),
      ],
    ),
    footer: _footer(
      '继续，连接已有日历',
      _c.busy
          ? null
          : () async {
              if (_preferences.weekdays.isEmpty) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('请至少选择一个可安排的日子。')));
                return;
              }
              await runAction(context, () async {
                await _c.savePreferences(
                  _preferences.copyWith(dailyBudget: _budget),
                );
                _input.dailyBudget = _budget;
                if (mounted) _open('03-connect');
              });
            },
      busy: _c.busy,
    ),
  );

  String _minute(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  Widget _connect() => buildPlatformScreen('03');

  Widget _chatUser(PlanningMessage message, {required bool original}) => Align(
    alignment: Alignment.centerRight,
    child: FractionallySizedBox(
      widthFactor: .88,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: SeraColors.mint,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          key: original ? const ValueKey('planning-original-message') : null,
          style: const TextStyle(
            fontSize: 15,
            height: 22 / 15,
            color: SeraColors.ink,
          ),
        ),
      ),
    ),
  );

  Widget _chatReply(
    PlanningMessage message, {
    required bool current,
    required bool waiting,
  }) {
    AiUnderstanding? result;
    if (message.understanding != null) {
      try {
        result = AiUnderstanding.fromJson(message.understanding!);
      } catch (_) {
        // Older or partial snapshots still retain their readable reply text.
      }
    }
    return Padding(
      padding: const EdgeInsets.only(right: 16, bottom: 16),
      child: SeraCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SeraIcon('spark', size: 18, color: SeraColors.brand),
                const SizedBox(width: 8),
                if (result != null)
                  SeraTag(switch (result.intent) {
                    'goal' => '目标规划',
                    'task' => '任务',
                    'event' => '固定事项',
                    _ => '回复',
                  }),
                const Spacer(),
                _copy(
                  current
                      ? (_understandingError == null ? '待核对' : '上次理解')
                      : '之前的建议',
                  size: 12,
                ),
              ],
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              SeraField(
                '规划时间',
                _understandingTimeLabel(result, useCurrentDeadline: current),
              ),
              if (current && result.intent == 'goal')
                SeraField('每日目标', '$_budget 分钟'),
              if (result.title.isNotEmpty) ...[
                const SizedBox(height: 12),
                _copy(
                  current && result.intent == 'goal'
                      ? _title.text
                      : result.title,
                  size: 17,
                  bold: true,
                  color: SeraColors.ink,
                ),
              ],
            ],
            if (message.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              _copy(message.text, color: SeraColors.ink),
            ],
            if (result != null &&
                result.outcome.isNotEmpty &&
                result.outcome != message.text) ...[
              const SizedBox(height: 8),
              _copy('预期结果', size: 12),
              _copy(result.outcome, size: 13),
            ],
            if (result != null && result.questions.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final question in result.questions) ...[
                _copy(question.question, color: SeraColors.ink),
                const SizedBox(height: 6),
              ],
            ],
            if (current &&
                result != null &&
                const ['goal', 'task', 'event'].contains(result.intent)) ...[
              const SizedBox(height: 16),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _supplement,
                builder: (_, value, _) {
                  final intent = result!.intent;
                  final direct = _canGenerateUnderstoodGoal;
                  final saveEvent = _canSaveUnderstoodEvent;
                  final disabled =
                      waiting ||
                      _c.busy ||
                      _submitting ||
                      intent == 'goal' && value.text.trim().isNotEmpty;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SeraButton(
                        saveEvent
                            ? '保存日程'
                            : direct
                            ? '生成计划'
                            : switch (intent) {
                                'goal' => '核对目标并规划',
                                'task' => '编辑任务',
                                _ => '编辑固定事项',
                              },
                        busy: _submitting,
                        onPressed: disabled
                            ? null
                            : saveEvent
                            ? _saveUnderstoodEvent
                            : direct
                            ? _generateUnderstoodGoal
                            : _acceptUnderstanding,
                      ),
                      if (direct || saveEvent)
                        Align(
                          alignment: Alignment.center,
                          child: TextButton(
                            onPressed: disabled ? null : _acceptUnderstanding,
                            child: Text(saveEvent ? '编辑固定事项' : '修改要求'),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (_understandingError != null) ...[
                const SizedBox(height: 8),
                _copy('补充尚未理解，继续时将使用上次结果。', size: 12),
              ],
              if (_eventSaveError != null && result.intent == 'event') ...[
                const SizedBox(height: 8),
                _copy(_eventSaveError!, size: 13, color: SeraColors.red),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _assistant(SeraController c) {
    final waiting = _understandingPending || c.understanding;
    final canResume =
        _understandingRequestId != null && _understandingInput != null;
    final latestReply = _messages
        .where((message) => message.role == 'assistant')
        .lastOrNull;
    return SeraScaffold(
      title: 'AI 助手',
      onBack: _saveAndBack,
      actions: [
        IconButton(
          tooltip: '规划记录',
          onPressed: waiting || c.busy
              ? null
              : () => _saveAndOpen('34-history'),
          icon: const SeraIcon('clock'),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          popUpAnimationStyle: SeraMotion.dialogStyle(context),
          enabled: !waiting && !c.busy,
          icon: const SeraIcon('more'),
          onSelected: (action) {
            switch (action) {
              case 'edit':
                _editOriginalInput();
              case 'task':
                _openSessionEditor('task', manual: true);
              case 'event':
                _openSessionEditor('event', manual: true);
              case 'goal':
                _manualGoal();
              case 'new':
                runAction(context, () async {
                  await _persistSession();
                  if (mounted && _isCurrentRoute) {
                    Router.neglect(
                      context,
                      () => context.replace(
                        Uri(
                          path: '/05',
                          queryParameters: {
                            'new': '1',
                            if (_planningOrigin case final String origin)
                              'from': origin,
                          },
                        ).toString(),
                      ),
                    );
                  }
                });
            }
          },
          itemBuilder: (_) => [
            if (_prompt.text.trim().isNotEmpty)
              const PopupMenuItem(
                key: ValueKey('planning-edit-original'),
                value: 'edit',
                child: Text('修改原文'),
              ),
            const PopupMenuItem(value: 'task', child: Text('添加任务')),
            const PopupMenuItem(value: 'event', child: Text('添加日程')),
            const PopupMenuItem(value: 'goal', child: Text('创建目标')),
            if (_messages.isNotEmpty || _prompt.text.trim().isNotEmpty)
              const PopupMenuItem(value: 'new', child: Text('新对话')),
          ],
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_messages.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 20),
              child: Text(
                _planningOrigin == 'goals' ? '规划目标' : '有什么需要帮你安排？',
                style: const TextStyle(fontSize: 16, color: SeraColors.muted),
              ),
            ),
          for (var i = 0; i < _messages.length; i++)
            if (_messages[i].role == 'user')
              _chatUser(_messages[i], original: i == 0)
            else
              _chatReply(
                _messages[i],
                current:
                    identical(_messages[i], latestReply) &&
                    _understanding != null,
                waiting: waiting,
              ),
          if (waiting) ...[
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: SeraCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TickerMode(
                      enabled: !SeraMotion.reduced(context),
                      child: const LinearProgressIndicator(
                        minHeight: 2,
                        color: SeraColors.brand,
                        backgroundColor: SeraColors.line,
                        semanticsLabel: '正在理解',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _copy(
                      c.understandingStage.isEmpty
                          ? '正在理解你的输入'
                          : c.understandingStage,
                      size: 13,
                    ),
                    TextButton(
                      onPressed: _cancelUnderstanding,
                      child: const Text('取消理解'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_understandingError != null) ...[
            SeraNote(
              '理解尚未完成',
              body: _understandingError,
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
          ],
          if (!waiting &&
              _prompt.text.trim().isNotEmpty &&
              (_understanding == null || _understandingError != null))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: c.busy
                    ? null
                    : () => _understand(
                        resume: canResume,
                        clarify: _understanding != null,
                        supplement: true,
                      ),
                icon: const SeraIcon('send', size: 18),
                label: Text(
                  canResume
                      ? '继续理解'
                      : _understandingError != null
                      ? '重新理解'
                      : '理解这段输入',
                ),
              ),
            ),
          if (!waiting &&
              _understanding == null &&
              _understandingError == null &&
              !c.canUnderstandInput)
            _copy('AI 暂不可用，可在更多操作中自行创建。', size: 13),
          if (_sessionSaveError != null) ...[
            const SizedBox(height: 12),
            SeraNote(
              '输入还没有保存',
              body: _sessionSaveError,
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
          ],
          SizedBox(key: _chatEnd, height: 8),
        ],
      ),
      footer: _ChatComposer(
        controller: _supplement,
        waiting: waiting || c.busy,
        hasMessages: _messages.isNotEmpty,
        initialHint: _planningOrigin == 'goals' ? '说说你想达成的目标…' : '写下想做的事…',
        onSend: _sendChatMessage,
        onVoice: () => _saveAndOpen('50-voice'),
      ),
    );
  }

  String _instantLabel(DateTime value) {
    final date = inTimeZone(value, _c.data.preferences.timeZone);
    return '${formatDate(date)} ${formatTime(date)}';
  }

  String _understandingTimeLabel(
    AiUnderstanding result, {
    bool useCurrentDeadline = true,
  }) {
    final zone = _c.data.preferences.timeZone;
    final start = result.start == null ? null : inTimeZone(result.start!, zone);
    final end = result.end == null ? null : inTimeZone(result.end!, zone);
    final fields = <String>[];
    if (start != null && end != null) {
      final sameDay = calendarDateString(start) == calendarDateString(end);
      fields.add(
        sameDay
            ? '${formatDate(start)} ${formatRange(start, end)}'
            : '${_instantLabel(start)} — ${_instantLabel(end)}',
      );
    } else if (start != null) {
      fields.add('${_instantLabel(start)} 起，结束未确定');
    } else if (end != null) {
      fields.add('开始未确定，至 ${_instantLabel(end)}');
    }
    final deadline = useCurrentDeadline ? _deadline : result.deadline;
    if (const ['goal', 'task'].contains(result.intent) && deadline != null) {
      final dateOnly = useCurrentDeadline
          ? _deadlineIsDateOnly
          : result.deadlineIsDateOnly;
      fields.add(
        '截至 ${dateOnly ? '${formatDate(inTimeZone(deadline, zone))}（当天结束前）' : _instantLabel(deadline)}',
      );
    }
    return fields.isEmpty ? '未确定' : fields.join('\n');
  }

  Widget _clarify(SeraController c) => SeraScaffold(
    title: '确认目标',
    onBack: _saveAndBack,
    body: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SeraInput(
            label: '目标名称',
            controller: _title,
            validator: (v) => (v?.trim().isEmpty ?? true) ? '请填写一个目标名称。' : null,
          ),
          _fields([
            InkWell(
              onTap: _pickDeadline,
              child: SeraField(
                '目标截止',
                _deadlineLabel,
                trailing: const SeraIcon('chevron', size: 16),
              ),
            ),
            if (_deadline != null)
              Row(
                children: [
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: const Text(
                        '只限定日期',
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _deadlineIsDateOnly,
                      onChanged: (value) {
                        setState(() => _deadlineIsDateOnly = value ?? false);
                        _queueSessionSave();
                      },
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _deadline = null;
                        _deadlineIsDateOnly = false;
                      });
                      _queueSessionSave();
                    },
                    child: const Text('清除'),
                  ),
                ],
              ),
            SeraField('每天可投入', '$_budget 分钟'),
            if (_budget > c.data.preferences.dailyBudget)
              _copy('日常规划参考：${c.data.preferences.dailyBudget} 分钟', size: 13),
            Slider(
              value: _budget.toDouble().clamp(15, 480),
              min: 15,
              max: 480,
              divisions: 93,
              label: '$_budget 分钟',
              onChanged: (v) {
                setState(() => _budget = v.round());
                _queueSessionSave();
              },
            ),
          ]),
          const SizedBox(height: 12),
          if (_deadline == null)
            const SeraNote('截止日期由你决定', body: '请选择截止日期，再安排时间；也可以返回助手补充。'),
          SeraInput(
            label: '还有哪些要求？',
            controller: _notes,
            minLines: 2,
            maxLines: 5,
          ),
          if (_sessionSaveError != null) ...[
            const SizedBox(height: 12),
            SeraNote(
              '输入还没有保存',
              body: _sessionSaveError,
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
          ],
        ],
      ),
    ),
    footer: _footer(
      '生成可执行的计划',
      c.busy || _submitting ? null : () => _generate(),
      busy: _submitting || c.busy,
    ),
  );

  Widget _generating(SeraController c) {
    final draft = _draft(c);
    final refinement = _sessionTargetTaskId != null;
    final target = c.task(_sessionTargetTaskId);
    final unavailable = refinement && (target == null || !target.active);
    final changed =
        refinement &&
        _sessionBaseTaskRevision != null &&
        target?.revision != _sessionBaseTaskRevision;
    return SeraScaffold(
      title: '正在规划',
      onBack: _cancelGeneration,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _steps(1),
          const SizedBox(height: 24),
          Center(
            child: SizedBox(
              width: 56,
              height: 56,
              child: c.busy
                  ? const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: SeraColors.brand,
                      backgroundColor: SeraColors.mint,
                    )
                  : const SeraIcon('spark', size: 48, color: SeraColors.brand),
            ),
          ),
          const SizedBox(height: 24),
          _successCopy(
            _input.title.isEmpty ? '正在生成草案' : _input.title,
            c.busy
                ? c.generationStage
                : unavailable
                ? '原任务已经不存在或已经结束，请先查看当前任务。'
                : changed
                ? '任务内容有变化，请核对后重新生成建议。'
                : _sessionRequestId != null
                ? '可以继续上次的规划，查看生成结果。'
                : '确认目标后，即可继续生成计划。',
          ),
          const SizedBox(height: 16),
          _copy('生成后可编辑，确认后才创建任务。', size: 13, align: TextAlign.center),
        ],
      ),
      footer: c.busy
          ? SeraButton('取消这次生成', variant: 'quiet', onPressed: _cancelGeneration)
          : _footer(
              unavailable
                  ? target == null
                        ? '返回任务列表'
                        : '查看当前任务'
                  : changed
                  ? '按当前任务重新生成'
                  : draft != null
                  ? '查看这次的计划草案'
                  : _sessionRequestId != null
                  ? '继续这次生成'
                  : refinement
                  ? '重新生成拆解建议'
                  : '返回确认目标',
              () async {
                if (unavailable) {
                  target == null ? _go('17') : _go('18', taskId: target.id);
                } else if (changed) {
                  await _generate(validate: false);
                } else if (draft != null) {
                  await _persistSession(stage: 'draft', draftId: draft.id);
                  if (mounted) {
                    _go(
                      draft.needsPlanningConfirmation
                          ? '39-ai-error'
                          : '08-plan',
                      draftId: draft.id,
                    );
                  }
                } else if (_sessionRequestId != null) {
                  await _generate(validate: false, resume: true);
                } else if (refinement) {
                  await _generate(validate: false);
                } else {
                  _open('06-clarify');
                }
              },
            ),
    );
  }

  void _openDraftMenu(String draftId, String taskId) {
    _draftMenuOwners.clear();
    if (!_isCurrentRoute) return;
    final auth = context.read<AuthRepository?>();
    _draftMenuOwners[(draftId, taskId)] = _DraftMenuOwner(
      draftId: draftId,
      taskId: taskId,
      controller: _c,
      accountId: _c.accountId,
      sessionId: _sessionId,
      route: ModalRoute.of(context),
      auth: auth,
      authSession: auth?.session,
    );
  }

  void _selectDraftMenu(String draftId, String taskId, String action) {
    final owner = _draftMenuOwners.remove((draftId, taskId));
    if (owner == null ||
        !_isCurrentRoute ||
        owner.route != ModalRoute.of(context) ||
        owner.route?.isCurrent != true ||
        !identical(owner.controller, _c) ||
        owner.accountId != _c.accountId ||
        owner.sessionId != _sessionId) {
      return;
    }
    final auth = context.read<AuthRepository?>();
    if (!identical(auth, owner.auth) ||
        auth?.session?.user.id != owner.authSession?.user.id ||
        auth?.session?.sessionId != owner.authSession?.sessionId ||
        auth?.session?.token != owner.authSession?.token) {
      return;
    }
    final current = owner.controller.draft(owner.draftId);
    if (current == null || current.status != 'draft') return;
    final ids = current.items.map((item) => item.task.id).toList();
    final index = ids.indexOf(owner.taskId);
    if (index < 0) return;
    if (action == 'edit') {
      _open('09-edit-plan-task', draftId: owner.draftId, taskId: owner.taskId);
      return;
    }
    final target = switch (action) {
      'up' => index - 1,
      'down' => index + 1,
      _ => -1,
    };
    if (target < 0 || target >= ids.length) return;
    ids.removeAt(index);
    ids.insert(target, owner.taskId);
    runAction(
      context,
      () => owner.controller.reorderDraftItems(owner.draftId, ids),
      success: '任务顺序已更新',
    );
  }

  String _draftTaskTitle(PlanDraft draft, SeraTask task) {
    final prefix = '${draft.goal.title} · ';
    final title = task.title;
    if (title.startsWith(prefix) &&
        title.substring(prefix.length).trim().isNotEmpty) {
      return title.substring(prefix.length).trim();
    }
    return title;
  }

  Widget _phaseHeader(PlanDraft draft, String phase) {
    final tasks = draft.items
        .where((item) => item.task.phase == phase)
        .map((item) => item.task);
    final starts = tasks.map((task) => task.notBefore).nonNulls.toList()
      ..sort();
    final ends = tasks.map((task) => task.deadline).nonNulls.toList()..sort();
    final zone = _c.data.preferences.timeZone;
    String label(DateTime value) {
      final day = inTimeZone(value, zone);
      return '${day.year == _c.today.year ? '' : '${day.year}年'}${formatDate(day)}';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _copy(phase, size: 15, bold: true, color: SeraColors.ink),
          if (starts.isNotEmpty && ends.isNotEmpty) ...[
            const SizedBox(height: 4),
            _copy('${label(starts.first)} — ${label(ends.last)}', size: 13),
          ],
        ],
      ),
    );
  }

  Widget _draftItems(PlanDraft draft, {bool editable = true}) => Column(
    children: [
      for (var i = 0; i < draft.items.length; i++) ...[
        if (draft.items[i].task.phase.trim().isNotEmpty &&
            (i == 0 ||
                draft.items[i - 1].task.phase != draft.items[i].task.phase))
          _phaseHeader(draft, draft.items[i].task.phase),
        InkWell(
          key: ValueKey('draft-row:${draft.id}:${draft.items[i].task.id}'),
          onTap: editable
              ? () => _open(
                  '09-edit-plan-task',
                  draftId: draft.id,
                  taskId: draft.items[i].task.id,
                )
              : () => _open('18-task-detail', taskId: draft.items[i].task.id),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: SeraColors.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 15),
                  child: Text(
                    '${i + 1}'.padLeft(2, '0'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: SeraColors.brand,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _copy(
                        _draftTaskTitle(draft, draft.items[i].task),
                        size: 16,
                        color: SeraColors.ink,
                        bold: true,
                      ),
                      const SizedBox(height: 6),
                      _copy(
                        draft.items[i].entry == null
                            ? '${formatMinutes(draft.items[i].task.estimatedMinutes)} · 待安排'
                            : formatEntryRange(
                                draft.items[i].entry!,
                                showDate: true,
                              ),
                        size: 13,
                      ),
                      if (draft.items[i].blocks.length > 1)
                        _copy(
                          '分 ${draft.items[i].blocks.length} 次安排',
                          size: 12,
                          color: SeraColors.brand,
                        ),
                      if (draft.items[i].blocks.length > 1 ||
                          (draft.items[i].entry != null &&
                              draft.items[i].entry!.minutes !=
                                  draft.items[i].task.estimatedMinutes))
                        _copy(
                          '预计 ${formatMinutes(draft.items[i].task.estimatedMinutes)}',
                          size: 13,
                        ),
                      if (draft.items[i].task.notes.trim().isNotEmpty)
                        _copy(draft.items[i].task.notes.trim(), size: 13),
                      if (draft.targetTaskId != null) ...[
                        const SizedBox(height: 10),
                        for (final check in draft.items[i].task.checklist)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: SeraIcon(
                                    'check',
                                    size: 14,
                                    color: SeraColors.brand,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _copy(
                                    check,
                                    size: 13,
                                    color: SeraColors.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                if (editable)
                  PopupMenuButton<String>(
                    key: ValueKey(
                      'draft-menu:${draft.id}:${draft.items[i].task.id}',
                    ),
                    popUpAnimationStyle: SeraMotion.dialogStyle(context),
                    tooltip: '调整这项任务',
                    icon: const SeraIcon('more', size: 18),
                    onOpened: () =>
                        _openDraftMenu(draft.id, draft.items[i].task.id),
                    onCanceled: () => _draftMenuOwners.remove((
                      draft.id,
                      draft.items[i].task.id,
                    )),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑任务')),
                      if (i > 0)
                        const PopupMenuItem(value: 'up', child: Text('向前一步')),
                      if (i < draft.items.length - 1)
                        const PopupMenuItem(value: 'down', child: Text('向后一步')),
                    ],
                    onSelected: (value) => _selectDraftMenu(
                      draft.id,
                      draft.items[i].task.id,
                      value,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ],
  );

  DateTime? get _planningDeadline => _deadline == null
      ? null
      : _deadlineIsDateOnly
      ? atMinute(_deadline!, 1439)
      : _deadline;

  String get _deadlineLabel => _deadline == null
      ? '尚未设置截止日期'
      : _deadlineIsDateOnly
      ? '${formatDate(_deadline!)}（当天结束前）'
      : '${formatDate(_deadline!)} ${formatTime(_deadline!)}';

  Widget _plan(SeraController c) {
    final draft = _draft(c);
    if (draft == null) return _noDraft();
    final committed = draft.status == 'committed';
    final pending = draft.targetTaskId == null
        ? draft.unscheduledItems.length
        : 0;
    final count = draft.items.length;
    final saving = _openingCommit || c.busy;
    return SeraScaffold(
      title: draft.targetTaskId != null ? '调整任务执行步骤' : '计划草案',
      onBack: committed ? null : () => _open('44-discard', draftId: draft.id),
      actions: committed
          ? []
          : [
              TextButton(
                onPressed: saving
                    ? null
                    : () => _saveAndOpenDraftHistory(draft),
                child: const Text('保存草案'),
              ),
            ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _steps(1),
          _copy(draft.goal.title, size: 24, bold: true, color: SeraColors.ink),
          const SizedBox(height: 4),
          _copy(
            '${formatDate(draft.goal.deadline)} ${formatTime(draft.goal.deadline)} 前完成',
            size: 12,
          ),
          if (committed) ...[const SizedBox(height: 8), const SeraTag('已确认创建')],
          const SizedBox(height: 14),
          _copy(
            committed
                ? '$count 项任务 · 预计 ${draft.totalMinutes} 分钟${pending == 0 ? '' : ' · $pending 项待安排'}'
                : draft.targetTaskId != null
                ? '更新这项任务的步骤，所属目标和已有安排不变。'
                : '${draft.targetGoalId == null ? '创建 1 个目标、$count 项任务' : '更新原目标计划，包含 $count 项任务'} · ${draft.items.fold<int>(0, (sum, x) => sum + x.blocks.length)} 段日程安排${pending == 0 ? '' : ' · $pending 项待安排'}',
            size: 15,
          ),
          if (!committed && draft.targetTaskId == null) ...[
            const SizedBox(height: 4),
            _copy('预计用时 ${formatMinutes(draft.totalMinutes)}', size: 13),
          ],
          SeraSection(
            '任务清单',
            action: draft.items.isEmpty
                ? null
                : committed
                ? '查看任务'
                : '编辑',
            onAction: draft.items.isEmpty
                ? null
                : () => committed
                      ? _open(
                          '18-task-detail',
                          taskId: draft.items.first.task.id,
                        )
                      : _open(
                          '09-edit-plan-task',
                          draftId: draft.id,
                          taskId: draft.items.first.task.id,
                        ),
          ),
          _draftItems(draft, editable: !committed),
          if (!committed && draft.targetTaskId == null) ...[
            const SizedBox(height: 12),
            SeraButton(
              '按最新日程重新检查',
              variant: 'secondary',
              icon: 'refresh',
              onPressed: c.busy
                  ? null
                  : () => runAction(
                      context,
                      () => c.revalidateDraft(draft.id),
                      success: '已重新检查并保留你的编辑',
                    ),
            ),
          ],
        ],
      ),
      footer: _footer(
        committed
            ? pending > 0
                  ? '查看目标清单'
                  : '查看已创建的日程'
            : draft.targetTaskId != null
            ? '确认更新执行步骤'
            : draft.targetGoalId != null
            ? '确认更新目标计划'
            : pending > 0
            ? '确认保存 $count 项任务'
            : '确认创建 $count 项任务与安排',
        draft.items.isEmpty || saving
            ? null
            : () {
                if (committed) {
                  pending > 0 ? _goToGoal(draft) : _go('12-calendar-day');
                } else {
                  _confirmAndSaveDraft(draft);
                }
              },
        busy: saving,
      ),
    );
  }

  void _confirmAndSaveDraft(PlanDraft draft) {
    if (!_isCurrentRoute || _openingCommit || _c.busy) return;
    setState(() => _openingCommit = true);
    unawaited(_open('51-writing', draftId: draft.id));
    // Guard repeated activation until navigation is rendered. The writing
    // route may be replaced by a conflict screen, so its push Future need not
    // settle when rechecking restores this draft. Route ownership and the
    // controller's busy state guard the operation after this first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _openingCommit = false);
    });
  }

  Future<void> _saveAndOpenDraftHistory(PlanDraft draft) async {
    final c = _c;
    final session = _sessionId;
    await runAction(context, () async {
      await _persistSession(stage: 'draft', draftId: draft.id);
      if (mounted &&
          _isCurrentRoute &&
          identical(_c, c) &&
          c.accountId == _accountId &&
          _sessionId == session) {
        final destination = _planningOrigin == null
            ? '/34-history'
            : _planningReturnLocation;
        final messenger = ScaffoldMessenger.of(context);
        finishSeraFlow(context, fallback: destination);
        messenger.showSnackBar(const SnackBar(content: Text('草案已保存')));
      }
    });
  }

  Widget _applied(SeraController c) {
    final draft = _draft(c);
    if (draft == null) return _noDraft();
    final first = draft.items.isEmpty ? null : draft.items.first;
    final committed = draft.status == 'committed';
    final pending = draft.targetTaskId == null
        ? draft.unscheduledItems.length
        : 0;
    final scheduled = draft.items
        .where((item) => item.blocks.isNotEmpty)
        .length;
    return SeraScaffold(
      title: committed
          ? draft.targetTaskId != null
                ? '执行步骤已更新'
                : pending > 0
                ? '计划已保存'
                : '已安排'
          : '等待确认',
      onBack: _leaveForOrigin,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol(committed ? 'check' : 'clock'),
          _successCopy(
            committed
                ? pending > 0
                      ? '任务已保存'
                      : '安排已保存'
                : '草案待确认',
            draft.targetTaskId != null && committed
                ? '原任务的执行步骤已更新。'
                : committed
                ? pending > 0
                      ? '${draft.items.length} 项任务 · $scheduled 项已安排 · $pending 项待安排'
                      : '${draft.items.length} 项任务 · 预计 ${draft.totalMinutes} 分钟'
                : '尚未创建任务，请先检查并确认安排。',
          ),
          _fields([
            SeraField(
              '目标截止',
              '${formatDate(draft.goal.deadline)} ${formatTime(draft.goal.deadline)}',
            ),
          ]),
          if (committed) ...[
            const SizedBox(height: 20),
            SeraButton(
              '撤销最近一次操作',
              variant: 'quiet',
              icon: 'undo',
              onPressed: c.busy
                  ? null
                  : () async {
                      await runAction(context, () async {
                        final undone = await _c.undoLast();
                        if (!mounted) return;
                        if (undone) {
                          _go('34-history');
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('没有可以撤销的操作。')),
                          );
                        }
                      });
                    },
            ),
          ],
        ],
      ),
      footer: _footer(
        committed
            ? pending > 0
                  ? '查看目标清单'
                  : '查看日程'
            : '查看草案',
        () {
          if (committed) {
            if (pending > 0) {
              _goToGoal(draft);
              return;
            }
            if (first?.entry != null) c.setSelectedDate(first!.entry!.start);
            _go('12-calendar-day');
          } else {
            _open('08-plan', draftId: draft.id);
          }
        },
        secondary: _planningReturnLabel,
        onSecondary: _leaveForOrigin,
      ),
    );
  }

  void _goToGoal(PlanDraft draft) {
    if (!_isCurrentRoute) return;
    Router.neglect(context, () {
      context.go(
        Uri(
          path: '/21',
          queryParameters: {'goalId': draft.targetGoalId ?? draft.goal.id},
        ).toString(),
      );
    });
  }

  DateTime? _replanDay(SeraController c) {
    final query = GoRouterState.of(context).uri.queryParameters;
    if (query['scope'] == 'today') return c.today;
    final raw = query['date'];
    if (raw == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      return null;
    }
    final value = DateTime.tryParse(raw);
    return value == null || calendarDateString(value) != raw
        ? null
        : inTimeZone(value, c.data.preferences.timeZone, wallClock: true);
  }

  CalendarEntry? _replanEntry(SeraController c, SeraTask task) {
    final query = GoRouterState.of(context).uri.queryParameters;
    final id = query['entryId'] ?? _selectedReplanEntryId;
    if (id != null) {
      return c.data.entries
          .where((entry) => entry.id == id && entry.taskId == task.id)
          .firstOrNull;
    }
    final day = _replanDay(c);
    if (day != null) {
      return c
          .entriesOn(day)
          .where((entry) => entry.taskId == task.id)
          .firstOrNull;
    }
    return c.entryForTask(task.id);
  }

  void _openReplanStep(
    String id,
    SeraTask task,
    CalendarEntry? entry, {
    bool replace = false,
    String? changeId,
  }) {
    if (!_isCurrentRoute) return;
    final current = GoRouterState.of(context).uri.queryParameters;
    final target = Uri(
      path: '/$id',
      queryParameters: {
        'taskId': task.id,
        if (entry != null) 'entryId': entry.id,
        'changeId': ?changeId,
        if (current['scope'] == 'today') 'scope': 'today',
        if (current['date'] != null) 'date': current['date']!,
      },
    ).toString();
    if (replace) {
      Router.neglect(context, () => context.replace(target));
    } else {
      Router.neglect(context, () => context.push(target));
    }
  }

  void _finishReplan(SeraTask task, String changeId, {String? entryId}) {
    if (!_isCurrentRoute) return;
    final controller = _c;
    final accountId = controller.accountId;
    final auth = context.read<AuthRepository?>();
    final authSession = auth?.session;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final entry = entryId == null
        ? controller.entryForTask(task.id)
        : controller.entry(entryId);
    if (findSeraFlowReturn(context) == null && entry != null) {
      controller.setSelectedDate(
        inTimeZone(entry.start, controller.data.preferences.timeZone),
      );
    }
    finishSeraFlow(
      context,
      fallback: Uri(
        path: '/12',
        queryParameters: entry == null ? null : {'focusEntryId': entry.id},
      ).toString(),
    );
    var undoPending = false;
    bool ownsWorkspace() =>
        messenger.mounted &&
        identical(messenger.context.read<SeraController>(), controller) &&
        controller.accountId == accountId &&
        identical(messenger.context.read<AuthRepository?>(), auth) &&
        identical(auth?.session, authSession);

    messenger.showSnackBar(
      SnackBar(
        content: const Text('安排已调整'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            if (undoPending || !ownsWorkspace()) return;
            undoPending = true;
            final undoUri = router.state.uri;
            try {
              final undone = await controller.undoReplan(changeId);
              if (!ownsWorkspace()) return;
              messenger.showSnackBar(
                SnackBar(content: Text(undone ? '已撤销这次调整' : '这次调整已撤销')),
              );
            } catch (error) {
              if (!ownsWorkspace()) return;
              if (router.state.uri == undoUri) {
                router.push(
                  Uri(
                    path: '/53',
                    queryParameters: {'taskId': task.id},
                  ).toString(),
                );
              } else {
                messenger.showSnackBar(SnackBar(content: Text('$error')));
              }
            } finally {
              undoPending = false;
            }
          },
        ),
      ),
    );
  }

  CalendarEntry? _suggestion(
    SeraController c,
    SeraTask task,
    CalendarEntry? current,
  ) {
    final from = current == null
        ? c.today
        : current.start.add(
            Duration(minutes: c.data.preferences.bufferMinutes),
          );
    return c.findAvailableSlot(task.id, from: from, entryId: current?.id);
  }

  Widget _replan(SeraController c, {required bool confirm}) {
    final day = _replanDay(c);
    final query = GoRouterState.of(context).uri.queryParameters;
    if (widget.taskId == null &&
        day == null &&
        (query.containsKey('date') || query.containsKey('scope'))) {
      return SeraScaffold(
        title: '请选择日程日期',
        body: SeraEmpty(
          '日期无效',
          '请返回日程重新选择。',
          action: '查看日程',
          onAction: () => _go('12-calendar-day'),
        ),
      );
    }
    final scoped = widget.taskId == null && day != null;
    final candidates = day == null
        ? <CalendarEntry>[]
        : c
              .entriesOn(day)
              .where(
                (entry) =>
                    entry.taskId != null &&
                    c.task(entry.taskId)?.active == true,
              )
              .toList();
    final chosen = candidates
        .where((entry) => entry.id == _selectedReplanEntryId)
        .firstOrNull;
    if (scoped && candidates.length > 1 && chosen == null) {
      return SeraScaffold(
        title: '选择要调整的安排',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(formatDate(day)),
            for (final entry in candidates)
              SeraSettingRow(
                c.task(entry.taskId)!.title,
                subtitle: formatRange(entry.start, entry.end),
                icon: 'calendar',
                onTap: () => setState(() {
                  _selectedReplanEntryId = entry.id;
                }),
              ),
          ],
        ),
      );
    }
    final task = scoped
        ? c.task((chosen ?? candidates.firstOrNull)?.taskId)
        : _task(c);
    if (task == null) {
      return SeraScaffold(
        title: '调整建议',
        body: SeraEmpty(
          scoped ? '这一天没有可调整的任务安排' : '还没有需要调整的任务',
          scoped ? '可以查看日程或添加任务。' : '先创建一项任务，再根据真实可用时间调整安排。',
          icon: 'calendar',
          action: '添加任务',
          onAction: () => _open('19-new-task'),
        ),
      );
    }
    final current = _replanEntry(c, task);
    if (GoRouterState.of(context).uri.queryParameters['entryId'] != null &&
        current == null) {
      return SeraScaffold(
        title: '原安排已变化',
        body: SeraEmpty(
          '这段安排已被删除',
          '请返回日程重新选择。',
          action: '查看日程',
          onAction: () => _go('12-calendar-day'),
        ),
      );
    }
    final suggestion = _suggestion(c, task, current);
    final multipleBlocks = c.entriesForTask(task.id).length > 1;
    final conflicts = current == null
        ? <CalendarEntry>[]
        : [...c.data.entries, ...c.data.externalBusyEntries]
              .where(
                (e) =>
                    e.id != current.id &&
                    e.start.isBefore(current.end) &&
                    e.end.isAfter(current.start),
              )
              .toList();
    final previous = current == null
        ? '尚未安排'
        : '${formatDate(current.start)} ${formatRange(current.start, current.end)}';
    if (suggestion == null) {
      return SeraScaffold(
        title: '暂无可用时段',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _copy(task.title, size: 24, bold: true, color: SeraColors.ink),
            const SizedBox(height: 8),
            _copy('当前安排 · $previous', size: 13),
            const SizedBox(height: 24),
            _copy('按目前的可用时段和每天可投入时间，截止前无法安排这项任务。', color: SeraColors.amber),
            if (conflicts.isNotEmpty) ...[
              SeraSection('当前重叠 · ${conflicts.length} 项'),
              _fields([
                for (final entry in conflicts)
                  _row(
                    entry.title,
                    formatEntryRange(entry, showDate: true),
                    'calendar',
                  ),
              ]),
            ],
          ],
        ),
        footer: _footer(
          '修改规划偏好',
          () => _open('31-ai-preferences'),
          secondary: '手动调整任务',
          onSecondary: () => _open('09-edit-plan-task', taskId: task.id),
        ),
      );
    }
    return SeraScaffold(
      title: confirm ? '确认这次调整' : '调整建议',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _copy(task.title, size: 24, bold: true, color: SeraColors.ink),
          const SizedBox(height: 8),
          _copy(
            multipleBlocks ? '只调整选中的这段安排，其他安排不变。' : '只调整这项任务的时间。',
            size: 13,
          ),
          if (!confirm && conflicts.isNotEmpty) ...[
            SeraSection('当前重叠 · ${conflicts.length} 项'),
            _fields([
              for (final entry in conflicts)
                _row(
                  entry.title,
                  '${formatEntryRange(entry, showDate: true)} · ${entry.isExternal
                      ? '其他日历的安排'
                      : entry.locked
                      ? '固定时间'
                      : '已有安排'}',
                  'calendar',
                ),
            ]),
          ],
          const SizedBox(height: 24),
          SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _copy('原计划', size: 13),
                Text(
                  previous,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: SeraColors.muted,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: 16),
                _copy('调整后', size: 13),
                const SizedBox(height: 4),
                _copy(
                  formatEntryRange(suggestion, showDate: true),
                  size: 18,
                  bold: true,
                  color: SeraColors.brand,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _fields([
            if (task.deadline != null)
              SeraField(
                '任务截止',
                task.dueAt == null
                    ? '${formatDate(task.deadline!)}（当天结束前）'
                    : '${formatDate(task.dueAt!)} ${formatTime(task.dueAt!)}',
              ),
            SeraField(
              '提醒',
              task.reminderMinutes < 0
                  ? '未设置'
                  : '${formatTime(suggestion.start.subtract(Duration(minutes: task.reminderMinutes)))} · 提前 ${task.reminderMinutes} 分钟',
            ),
          ]),
          const SizedBox(height: 16),
          _copy('确认后更新日程。', size: 13),
        ],
      ),
      footer: _footer(
        confirm ? '确认调整 1 项任务' : '查看变更并确认',
        c.busy
            ? null
            : () async {
                if (!confirm) {
                  _openReplanStep('23-replan-diff', task, current);
                  return;
                }
                await runAction(context, () async {
                  final controller = _c;
                  final accountId = controller.accountId;
                  final changeId = await controller.applyReplan(
                    task.id,
                    suggestion.start,
                    entryId: current?.id,
                    expectedEntryRevision: current?.revision,
                  );
                  if (mounted &&
                      _isCurrentRoute &&
                      identical(_c, controller) &&
                      controller.accountId == accountId) {
                    _finishReplan(task, changeId, entryId: current?.id);
                  }
                });
              },
        secondary: confirm ? '返回修改' : '手动调整时间',
        onSecondary: () => confirm
            ? _openReplanStep('22-replan', task, current, replace: true)
            : _open('09-edit-plan-task', taskId: task.id),
        busy: c.busy,
      ),
    );
  }

  String _sessionStatus(SeraController c, PlanningSession session) {
    final result = session.resultEntity;
    if (result != null) {
      return c.hasPlanningResult(result)
          ? result.kind == 'task'
                ? '任务已保存'
                : '日程已保存'
          : '原事项已删除';
    }
    return switch (session.stage) {
      'confirmed' => '已确认',
      'understanding' when session.understandingRequestId != null => '理解待继续',
      'understood' => '等待核对',
      'generating' when session.aiRequestId != null => '生成待继续',
      'draft' => '草案已生成',
      _ => '输入已保留',
    };
  }

  void _openHistorySession(SeraController c, PlanningSession session) {
    if (session.resultEntity != null) {
      _openResult(session.resultEntity!);
    } else if (session.draftId != null && c.draft(session.draftId) != null) {
      _open(
        '08-plan',
        draftId: session.draftId,
        sessionId: session.id,
        from: 'history',
      );
    } else {
      _open(
        session.targetTaskId != null ||
                (session.stage == 'generating' && session.aiRequestId != null)
            ? '07-generating'
            : const ['clarify', 'failed', 'canceled'].contains(session.stage)
            ? '06-clarify'
            : '05-assistant',
        sessionId: session.id,
        from: 'history',
      );
    }
  }

  Widget _history(SeraController c) {
    final owner = (c, c.accountId);
    if (_historyOwner != owner) {
      _historyOwner = owner;
      _historyTab = 'sessions';
    }
    return SeraScaffold(
      title: '规划记录',
      actions: [
        IconButton(
          tooltip: '清除规划记录',
          icon: const SeraIcon('trash'),
          onPressed: () => _clearHistory(c),
        ),
      ],
      footer: SeraButton(
        '新对话',
        onPressed: () => _open('05-assistant', fresh: true, from: 'history'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            key: const ValueKey('planning-history-tabs'),
            expandedInsets: EdgeInsets.zero,
            segments: const [
              ButtonSegment(value: 'sessions', label: Text('对话')),
              ButtonSegment(value: 'drafts', label: Text('草案')),
              ButtonSegment(value: 'operations', label: Text('操作')),
            ],
            selected: {_historyTab},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _historyTab = selection.first);
            },
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(0, 48),
              selectedBackgroundColor: SeraColors.brand,
              selectedForegroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          if (_historyTab == 'sessions') ...[
            SeraSection('对话 · ${c.data.planningSessions.length}'),
            if (c.data.planningSessions.isEmpty)
              const SeraEmpty('还没有对话记录', '', icon: 'mail')
            else
              for (final session in ([
                ...c.data.planningSessions,
              ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))))
                _row(
                  session.title.isNotEmpty
                      ? session.title
                      : session.prompt.isNotEmpty
                      ? session.prompt
                      : session.composerDraft.isNotEmpty
                      ? session.composerDraft
                      : '未命名输入',
                  '${formatDate(session.updatedAt)} ${formatTime(session.updatedAt)} · ${_sessionStatus(c, session)}',
                  'mail',
                  onTap: () => _openHistorySession(c, session),
                ),
          ] else if (_historyTab == 'drafts') ...[
            SeraSection('草案 · ${c.data.drafts.length} 份'),
            if (c.data.drafts.isEmpty)
              const SeraEmpty('还没有保存的草案', '', icon: 'book')
            else
              for (final draft in c.data.drafts.reversed)
                _row(
                  draft.goal.title,
                  '${draft.items.length} 项任务 · ${draft.status == 'committed' ? '已确认创建' : '草案，等待确认'}',
                  'book',
                  onTap: () =>
                      _open('08-plan', draftId: draft.id, from: 'history'),
                ),
          ] else ...[
            const SeraSection('最近操作'),
            if (c.data.history.isEmpty)
              const SeraEmpty('还没有操作记录', '', icon: 'clock')
            else
              for (final record in c.data.history.reversed.take(20))
                _row(
                  record.label,
                  '${formatDate(record.at)} ${formatTime(record.at)}${record.undone ? ' · 已撤销' : ''}',
                  'clock',
                  onTap: () => _showChange(record),
                ),
          ],
        ],
      ),
    );
  }

  Future<void> _clearHistory(SeraController c) async {
    final clear = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        title: const Text('清除规划记录？'),
        content: const Text('将清除对话输入和尚未确认的草案。已经创建的目标、任务和日程会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留记录'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (clear == true && mounted) {
      await runAction(context, c.clearPlanningHistory, success: '规划记录已清除');
    }
  }

  String _historyChangeSummary(dynamic value, String timeZone) {
    if (value is! Map) return _syncSummary(value);
    final localized = Map<dynamic, dynamic>.from(value);
    for (final key in ['deadline', 'start', 'end']) {
      final calendarDate = value['allDay'] == true ? value['${key}Date'] : null;
      final date = readZoned(calendarDate ?? value[key], timeZone);
      if (date != null) {
        localized[key] = calendarDate == null
            ? '${formatDate(date)} ${formatTime(date)}'
            : formatDate(date);
      }
    }
    return _syncSummary(localized);
  }

  Future<void> _showChange(ChangeRecord record) async {
    final controller = _c;
    final accountId = controller.accountId;
    final ownerRoute = ModalRoute.of(context);
    var undoPending = false;
    String? undoError;
    final changes = <(String, dynamic, dynamic)>[];
    for (final pair in [('tasks', '任务'), ('entries', '日程'), ('goals', '目标')]) {
      final old = {
        for (final item
            in (record.before[pair.$1] as List? ?? []).whereType<Map>())
          '${item['id']}': item,
      };
      final current = {
        for (final item
            in (record.after[pair.$1] as List? ?? []).whereType<Map>())
          '${item['id']}': item,
      };
      for (final id in {...old.keys, ...current.keys}) {
        if (jsonEncode(old[id]) != jsonEncode(current[id])) {
          changes.add((pair.$2, old[id], current[id]));
        }
      }
    }
    await showDialog<void>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateDialog) => ListenableBuilder(
          listenable: controller,
          builder: (_, _) {
            bool ownsDialog() =>
                mounted &&
                ctx.mounted &&
                identical(_c, controller) &&
                _c.accountId == accountId &&
                ownerRoute?.isActive == true;
            final current = controller.data.history
                .where((item) => item.id == record.id)
                .firstOrNull;
            final canUndo =
                ownsDialog() &&
                current?.label == '调整任务时间' &&
                current?.undone == false &&
                controller.canUndoReplan(record.id);
            final timeZone = controller.data.preferences.timeZone;
            final recordedAt = inTimeZone(record.at, timeZone);
            return AlertDialog(
              title: Text(record.label),
              content: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 440,
                  maxHeight: 420,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (undoError != null) ...[
                        Text(
                          undoError!,
                          style: const TextStyle(color: SeraColors.amber),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _copy(
                        '${formatDate(recordedAt)} ${formatTime(recordedAt)}${current?.undone == true ? ' · 已撤销' : ''}',
                        size: 12,
                      ),
                      if (current?.label == '调整任务时间' &&
                          current?.undone == false &&
                          !canUndo &&
                          ownsDialog())
                        _copy(
                          controller.replanUndoConflict(record.id) ?? '',
                          size: 13,
                          color: SeraColors.amber,
                        ),
                      if (changes.isEmpty) _copy('这次操作更新了偏好、输入或其他记录。'),
                      for (final change in changes) ...[
                        const SizedBox(height: 18),
                        _copy(
                          change.$1,
                          size: 15,
                          bold: true,
                          color: SeraColors.ink,
                        ),
                        _copy('操作前', size: 12, color: SeraColors.brand),
                        _copy(
                          _historyChangeSummary(change.$2, timeZone),
                          size: 13,
                        ),
                        const SizedBox(height: 10),
                        _copy('操作后', size: 12, color: SeraColors.brand),
                        _copy(
                          _historyChangeSummary(change.$3, timeZone),
                          size: 13,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
                if (canUndo)
                  TextButton(
                    onPressed: undoPending || controller.busy
                        ? null
                        : () async {
                            if (undoPending ||
                                !ownsDialog() ||
                                ModalRoute.of(ctx)?.isCurrent != true) {
                              return;
                            }
                            updateDialog(() {
                              undoPending = true;
                              undoError = null;
                            });
                            try {
                              final undone = await controller.undoReplan(
                                record.id,
                              );
                              if (ctx.mounted && ownsDialog()) {
                                if (undone &&
                                    ModalRoute.of(ctx)?.isCurrent == true) {
                                  Navigator.pop(ctx);
                                } else if (!undone) {
                                  updateDialog(
                                    () => undoError = '这次调整已无法撤销，请重新打开记录。',
                                  );
                                }
                              }
                            } catch (error) {
                              if (ownsDialog()) {
                                updateDialog(
                                  () => undoError = error is RepositoryException
                                      ? error.message
                                      : '撤销未完成，请重试。',
                                );
                              }
                            } finally {
                              if (ownsDialog()) {
                                updateDialog(() => undoPending = false);
                              }
                            }
                          },
                    child: const Text('撤销这次调整'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _generationError(SeraController c) {
    final candidate =
        widget.draftId != null ||
            _sessionDraftId != null ||
            _sessionRequestId != null
        ? _draft(c)
        : null;
    if (candidate != null &&
        (candidate.capacityLimited || candidate.suggestedDailyBudget != null) &&
        !candidate.needsPlanningConfirmation) {
      return _plan(c);
    }
    if (candidate != null && candidate.needsPlanningConfirmation) {
      return SeraScaffold(
        title: 'AI 助手',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _copy(
              candidate.goal.title,
              size: 20,
              bold: true,
              color: SeraColors.ink,
            ),
            const SizedBox(height: 24),
            _copy(
              _planningNoticeTitle(candidate),
              size: 24,
              bold: true,
              color: SeraColors.ink,
            ),
            const SizedBox(height: 12),
            _copy(_planningNotice(candidate)),
            const SizedBox(height: 24),
            SeraButton(
              _planningContinueLabel(candidate),
              key: ValueKey(
                candidate.needsCapacityConfirmation
                    ? 'confirm-plan-capacity'
                    : 'confirm-plan-daily-budget',
              ),
              busy: c.busy || _submitting,
              onPressed: c.busy || _submitting
                  ? null
                  : () => runAction(context, () async {
                      await c.confirmDraftPlanningLimits(candidate.id);
                      if (mounted && _isCurrentRoute) {
                        _go('08-plan', draftId: candidate.id);
                      }
                    }),
            ),
            const SizedBox(height: 12),
            SeraButton(
              '修改要求',
              variant: 'quiet',
              onPressed: c.busy || _submitting ? null : _modifyGeneration,
            ),
          ],
        ),
      );
    }
    final refinement = _sessionTargetTaskId != null;
    final target = c.task(_sessionTargetTaskId);
    final unavailable = refinement && (target == null || !target.active);
    final changed =
        refinement &&
        _sessionBaseTaskRevision != null &&
        target?.revision != _sessionBaseTaskRevision;
    return SeraScaffold(
      title: 'AI 助手',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: SeraCard(
              color: SeraColors.mint,
              child: _copy(_input.prompt, color: SeraColors.ink),
            ),
          ),
          const SizedBox(height: 24),
          _copy('这次没能完成规划', size: 24, bold: true, color: SeraColors.ink),
          const SizedBox(height: 12),
          _copy('输入已保留，可以重试或调整要求。'),
          const SizedBox(height: 16),
          SeraDisclosure(
            title: '查看详情',
            children: [
              _copy(_generationFailure ?? c.error ?? '请检查目标截止与可用时间。'),
              const SizedBox(height: 12),
              SeraField('截止', _deadlineLabel),
              SeraField('每日目标', '$_budget 分钟'),
            ],
          ),
          const SizedBox(height: 24),
          _stack([
            if (!unavailable)
              SeraButton(
                changed
                    ? '按当前任务重新生成'
                    : _sessionRequestId != null
                    ? '继续这次生成'
                    : refinement
                    ? '重新生成拆解建议'
                    : '重新生成计划',
                busy: c.busy || _submitting,
                onPressed: c.busy || _submitting
                    ? null
                    : () => _generate(
                        validate: false,
                        resume: _sessionRequestId != null && !changed,
                      ),
              ),
            if (_sessionRequestId != null && !unavailable && !changed)
              SeraButton(
                refinement ? '重新生成拆解建议' : '重新生成一份计划',
                variant: 'secondary',
                onPressed: c.busy || _submitting
                    ? null
                    : () => _generate(validate: false),
              ),
            SeraButton(
              refinement
                  ? target == null
                        ? '返回任务列表'
                        : '返回任务查看'
                  : '修改要求后再试',
              variant: 'ghost',
              onPressed: refinement && target == null
                  ? () => _go('17')
                  : _modifyGeneration,
            ),
          ]),
        ],
      ),
    );
  }

  String _budgetNotice(PlanDraft draft) =>
      '部分日期需最多 ${draft.suggestedDailyBudget} 分钟，超过每日目标 ${draft.originalDailyBudget} 分钟。';

  String _planningNoticeTitle(PlanDraft draft) =>
      draft.needsCapacityConfirmation ? '部分任务待安排' : '需要多一点时间';

  String _planningContinueLabel(PlanDraft draft) =>
      draft.needsCapacityConfirmation ? '保留计划并继续' : '仍按此计划继续';

  String _planningNotice(PlanDraft draft) => [
    if (draft.needsBudgetConfirmation) _budgetNotice(draft),
    if (draft.needsCapacityConfirmation)
      '当前时段放不下全部任务，${draft.unscheduledItems.length} 项先保留为待安排。',
  ].join('\n');

  Widget _offline(SeraController c) {
    final conflict = c.syncConflict;
    return SeraScaffold(
      title: '保存与同步',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol(
            conflict != null
                ? 'warning'
                : c.isOffline
                ? 'wifi-off'
                : 'check',
            warning: conflict != null,
          ),
          _successCopy(
            conflict != null
                ? '有不同的修改需要你确认'
                : c.isOffline
                ? '离线 · ${c.pendingSyncCount} 项待同步'
                : c.pendingSyncCount > 0
                ? '在线 · ${c.pendingSyncCount} 项待同步'
                : '当前已保存',
            conflict != null
                ? '这台设备和云端有不同的修改，请核对后选择要保留的内容。'
                : c.isOffline
                ? '离线时可以查看和修改已保存的内容，联网后再同步。AI 规划和语音识别需要联网。'
                : c.pendingSyncCount > 0
                ? '修改已保存在这台设备上，可以重新同步。'
                : '当前没有待同步的修改。',
          ),
          _fields([SeraField('已保存的任务', '${c.data.tasks.length} 项')]),
          if (conflict != null) ...[
            const SeraSection('核对两边的修改'),
            ..._conflictCards(c, conflict),
            const SizedBox(height: 16),
            SeraButton(
              '保留这台设备的修改',
              variant: 'secondary',
              onPressed: c.busy ? null : () => _resolveSync(c, true),
            ),
            const SizedBox(height: 10),
            SeraButton(
              '采用云端内容',
              variant: 'ghost',
              onPressed: c.busy ? null : () => _resolveSync(c, false),
            ),
          ],
          const SizedBox(height: 24),
          SeraButton(
            '重新连接并同步',
            busy: c.busy,
            onPressed: c.busy ? null : () => runAction(context, c.retrySync),
          ),
          const SizedBox(height: 10),
          SeraButton(
            '继续查看任务',
            variant: 'ghost',
            onPressed: () => _go('17-tasks'),
          ),
          SeraButton(
            '导出数据备份',
            variant: 'quiet',
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
    );
  }

  List<Widget> _conflictCards(SeraController c, Json conflict) {
    final changes = conflict['conflicts'] is List
        ? conflict['conflicts'] as List
        : <dynamic>[];
    final local = c.data.toJson();
    if (changes.isEmpty) {
      return [
        const SeraNote('请选择要保留的内容', body: '云端内容有变化，请先备份，再选择保留这台设备的修改或云端内容。'),
      ];
    }
    return changes.whereType<Map>().map((change) {
      final type = '${change['entityType'] ?? ''}', id = change['entityId'];
      final collection = local[type];
      final value = collection is List
          ? collection.whereType<Map>().where((e) => e['id'] == id).firstOrNull
          : collection;
      final remote = change['serverValue'];
      final label = switch (type) {
        'tasks' => '任务',
        'entries' => '日程',
        'goals' => '目标',
        'drafts' => '计划草案',
        'preferences' => '规划偏好',
        _ => '保存的内容',
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: SeraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _copy(label, size: 16, bold: true, color: SeraColors.ink),
              const SizedBox(height: 12),
              _copy('这台设备', size: 12, color: SeraColors.brand, bold: true),
              _copy(
                _historyChangeSummary(value, c.data.preferences.timeZone),
                size: 13,
                color: SeraColors.ink,
              ),
              const Divider(height: 28),
              _copy('云端内容', size: 12, color: SeraColors.brand, bold: true),
              _copy(
                _historyChangeSummary(remote, c.data.preferences.timeZone),
                size: 13,
                color: SeraColors.ink,
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  String _syncSummary(dynamic value) {
    if (value == null) return '该内容已被删除。';
    if (value is! Map) return '$value';
    final lines = <String>[];
    for (final field in [
      ('title', '名称'),
      ('notes', '说明'),
      ('status', '状态'),
      ('deadline', '截止'),
      ('start', '开始'),
      ('end', '结束'),
      ('estimatedMinutes', '预计用时'),
      ('remainingMinutes', '剩余时间'),
    ]) {
      final data = value[field.$1];
      if (data == null || '$data'.isEmpty) continue;
      final display = switch (field.$1) {
        'status' => switch (data) {
          'todo' => '待办',
          'in_progress' || 'active' => '进行中',
          'blocked' => '遇到阻碍',
          'done' || 'completed' => '已完成',
          'canceled' => '已取消',
          'paused' => '已暂停',
          'archived' => '已归档',
          'draft' => '草案',
          'committed' => '已确认',
          _ => '$data',
        },
        'estimatedMinutes' || 'remainingMinutes' when data is num =>
          data < 0 ? '尚未记录' : formatMinutes(data.toInt()),
        _ => '$data',
      };
      lines.add('${field.$2}：$display');
    }
    return lines.isEmpty ? '此项设置有不同的修改。' : lines.join('\n');
  }

  Future<void> _resolveSync(SeraController c, bool keepLocal) async {
    final yes = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(keepLocal ? '保留这台设备的修改？' : '采用云端内容？'),
        content: Text(
          keepLocal
              ? '这台设备的修改将保存到云端。同一事项在云端的新改动会被替换，其他内容不变。'
              : '这台设备尚未同步的修改将被放弃，改用云端内容。此操作无法撤销，建议先导出备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续核对'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认处理'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await runAction(
        context,
        () => c.resolveSyncConflict(keepLocal: keepLocal),
      );
    }
  }

  Widget _permission() => buildPlatformScreen('41');

  Widget _partialSync(SeraController c) => buildPlatformScreen('42');

  Widget _discard(SeraController c) {
    final draft = _draft(c);
    if (draft == null) return _noDraft();
    return Stack(
      children: [
        ExcludeFocus(child: ExcludeSemantics(child: _plan(c))),
        ModalBarrier(
          color: SeraColors.ink.withValues(alpha: .35),
          dismissible: true,
          semanticsLabel: MaterialLocalizations.of(context)
              .modalBarrierDismissLabel,
          onDismiss: () => _go('08-plan', draftId: draft.id),
        ),
        Positioned.fill(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FocusScope(
              node: _discardFocus,
              autofocus: true,
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: '计划草案退出确认',
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 520),
                      padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 23),
                                  decoration: BoxDecoration(
                                    color: SeraColors.line,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              Semantics(
                                header: true,
                                child: const Text(
                                  '离开草案？',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _copy('草案已保留，之后可以继续编辑。'),
                              const SizedBox(height: 24),
                              _stack([
                                SeraButton(
                                  '保留草案并离开',
                                  onPressed: () =>
                                      _saveAndOpenDraftHistory(draft),
                                ),
                                SeraButton(
                                  '继续编辑',
                                  variant: 'ghost',
                                  onPressed: () =>
                                      _go('08-plan', draftId: draft.id),
                                ),
                                SeraButton(
                                  _planningReturnLabel,
                                  variant: 'quiet',
                                  onPressed: _leaveForOrigin,
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stale(SeraController c) {
    final draft = _draft(c);
    if (draft == null) return _noDraft();
    final stale = draft.validationRevision != c.data.revision;
    return SeraScaffold(
      title: '检查草案',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol('refresh', warning: true),
          _successCopy(
            stale ? '草案需要重新检查' : '草案可继续确认',
            stale
                ? '日程已有变化。原始目标和任务编辑已保留，重新检查后可继续确认。'
                : '原始目标和任务编辑已保留，也可以按最新安排重新检查。',
          ),
          SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _copy(
                  draft.goal.title,
                  size: 16,
                  color: SeraColors.ink,
                  bold: true,
                ),
                const SizedBox(height: 8),
                _copy(
                  '${draft.items.length} 项任务 · 预计 ${draft.totalMinutes} 分钟',
                  size: 13,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _stack([
            SeraButton(
              '保留编辑，重新检查安排',
              busy: c.busy || _submitting,
              onPressed: c.busy || _submitting
                  ? null
                  : () => runAction(context, () async {
                      await c.revalidateDraft(draft.id);
                      if (mounted) _go('08-plan', draftId: draft.id);
                    }),
            ),
            SeraButton(
              '返回草案继续查看',
              variant: 'ghost',
              onPressed: () => _open('08-plan', draftId: draft.id),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _loading(SeraController c) {
    if (!c.loading) return const TodayScreen();
    return SeraScaffold(
      title: '今日',
      showBack: false,
      navIndex: 0,
      body: Semantics(
        label: '正在读取今日安排',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: 100, child: _skeleton(16)),
            ),
            const SizedBox(height: 16),
            _skeleton(56),
            const SizedBox(height: 24),
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _skeleton(64),
              ),
          ],
        ),
      ),
    );
  }

  Widget _skeleton(double height) => Container(
    height: height,
    decoration: BoxDecoration(
      color: SeraColors.line.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(14),
    ),
  );

  Widget _voice() => const VoiceInputScreen();

  Widget _writing(SeraController c) {
    final draft = _draft(c);
    return SeraScaffold(
      title: '正在安排',
      showBack: !_submitting,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 42),
          Center(
            child: SizedBox(
              width: 56,
              height: 56,
              child: _writeError != null
                  ? const SeraIcon('warning', size: 48, color: SeraColors.amber)
                  : const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: SeraColors.brand,
                      backgroundColor: SeraColors.mint,
                    ),
            ),
          ),
          const SizedBox(height: 30),
          _successCopy(
            _writeError == null ? '正在保存任务与安排' : '还没有保存成功',
            _writeError ?? '',
          ),
          const SizedBox(height: 24),
          if (draft != null)
            SeraCard(
              color: SeraColors.mint,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _copy(
                    draft.goal.title,
                    size: 17,
                    color: SeraColors.ink,
                    bold: true,
                  ),
                  const SizedBox(height: 8),
                  _copy(
                    '${draft.items.length} 项任务 · ${formatMinutes(draft.totalMinutes)} · ${formatDate(draft.goal.deadline)} 截止',
                    size: 12,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 28),
          if (_writeError != null)
            _stack([
              SeraButton(
                '重新检查并保存',
                onPressed: c.busy || draft == null ? null : _commitDraft,
              ),
              SeraButton(
                '返回草案继续修改',
                variant: 'ghost',
                onPressed: () => _open('08-plan', draftId: draft?.id),
              ),
              if (draft != null)
                SeraButton(
                  '按最新安排更新草案',
                  variant: 'quiet',
                  onPressed: () => _open('48-stale-plan', draftId: draft.id),
                ),
            ]),
        ],
      ),
    );
  }

  Widget _adjusted(SeraController c) {
    final task = _task(c);
    final entry = task == null ? null : _replanEntry(c, task);
    final changeId = GoRouterState.of(context).uri.queryParameters['changeId'];
    final change = c.data.history.where((r) => r.id == changeId).firstOrNull;
    Map? savedEntry(Json snapshot) => (snapshot['entries'] as List? ?? const [])
        .whereType<Map>()
        .where((e) => e['id'] == entry?.id && e['taskId'] == task?.id)
        .firstOrNull;
    final after = change == null ? null : savedEntry(change.after);
    final matchesEntry =
        after != null &&
        jsonEncode(after) != jsonEncode(savedEntry(change!.before));
    final canUndo =
        change != null &&
        matchesEntry &&
        change.label == '调整任务时间' &&
        !change.undone &&
        c.canUndoReplan(change.id);
    return SeraScaffold(
      title: '调整完成',
      onBack: _leaveForOrigin,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol('check'),
          _successCopy('调整已保存', entry == null ? '可以在任务或日程中查看最新安排。' : ''),
          if (entry != null && task != null)
            SeraCard(
              color: SeraColors.mint,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _copy(
                    task.title,
                    size: 17,
                    color: SeraColors.ink,
                    bold: true,
                  ),
                  const SizedBox(height: 8),
                  _copy(
                    formatEntryRange(entry, showDate: true),
                    size: 18,
                    color: SeraColors.brand,
                    bold: true,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const SeraIcon('bell', size: 18),
                      const SizedBox(width: 9),
                      Expanded(
                        child: _copy(
                          task.reminderMinutes < 0
                              ? '这项任务未设置提醒'
                              : '提醒时间 ${formatTime(entry.start.subtract(Duration(minutes: task.reminderMinutes)))}',
                          size: 12,
                        ),
                      ),
                    ],
                  ),
                  if (task.dueAt != null) ...[
                    const SizedBox(height: 8),
                    _copy(
                      '任务截止 ${formatDate(task.dueAt!)} ${formatTime(task.dueAt!)}',
                      size: 13,
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (canUndo)
            SeraButton(
              '撤销最近一次调整',
              variant: 'quiet',
              icon: 'undo',
              busy: c.busy || _adjustmentUndoPending,
              onPressed: c.busy || _adjustmentUndoPending
                  ? null
                  : () async {
                      if (_adjustmentUndoPending || !_isCurrentRoute) return;
                      final accountId = c.accountId;
                      bool ownsPage() =>
                          mounted &&
                          identical(_c, c) &&
                          c.accountId == accountId;
                      if (!ownsPage()) return;
                      setState(() => _adjustmentUndoPending = true);
                      try {
                        final undone = await c.undoReplan(change.id);
                        if (!mounted || !ownsPage() || !_isCurrentRoute) return;
                        if (undone) {
                          _go('12-calendar-day');
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('没有可以撤销的操作。')),
                          );
                        }
                      } catch (_) {
                        if (ownsPage() && _isCurrentRoute) {
                          _open('53-undo-conflict', taskId: task?.id);
                        }
                      } finally {
                        if (ownsPage()) {
                          setState(() => _adjustmentUndoPending = false);
                        }
                      }
                    },
            ),
        ],
      ),
      footer: _footer(
        '查看更新后的日程',
        () => _go('12-calendar-day'),
        secondary: _planningReturnLabel,
        onSecondary: _leaveForOrigin,
      ),
    );
  }

  Widget _undoConflict(SeraController c) {
    final task = _task(c);
    final entry = task == null ? null : c.entryForTask(task.id);
    return SeraScaffold(
      title: '暂时无法撤销',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol('undo', warning: true),
          _copy(c.error ?? '这项安排后来有过修改。请核对当前安排，再决定保留或重新调整。'),
          const SizedBox(height: 24),
          SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _copy(
                  task?.title ?? '当前安排',
                  size: 18,
                  bold: true,
                  color: SeraColors.ink,
                ),
                const SizedBox(height: 18),
                _copy('当前保存的时间', size: 12),
                _copy(
                  entry == null
                      ? '尚未安排'
                      : '${formatDate(entry.start)} ${formatRange(entry.start, entry.end)}',
                  size: 21,
                  color: SeraColors.brand,
                  bold: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _stack([
            SeraButton(
              '保留当前安排',
              onPressed: () => _open(
                task == null ? '17-tasks' : '18-task-detail',
                taskId: task?.id,
              ),
            ),
            SeraButton(
              '重新检查可用时间',
              variant: 'ghost',
              onPressed: () => _open('22-replan', taskId: task?.id),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _notificationPermission(SeraController c) => buildPlatformScreen('54');

  Widget _saved(SeraController c) {
    final draft = _draft(c);
    if (draft == null) return _noDraft();
    final committed = draft.status == 'committed';
    return SeraScaffold(
      title: committed ? '计划已创建' : '草案已保存',
      onBack: _leaveForOrigin,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _symbol('check'),
          _successCopy(committed ? '计划已创建' : '草案已保存，尚未创建任务', ''),
          SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _copy(
                  draft.goal.title,
                  size: 16,
                  color: SeraColors.ink,
                  bold: true,
                ),
                const SizedBox(height: 8),
                _copy(
                  '${draft.items.length} 项任务 · 预计 ${draft.totalMinutes} 分钟',
                  size: 13,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _stack([
            SeraButton(
              '继续查看草案',
              onPressed: () => _go('08-plan', draftId: draft.id),
            ),
            SeraButton(
              _planningReturnLabel,
              variant: 'ghost',
              onPressed: _leaveForOrigin,
            ),
            SeraButton(
              '打开规划记录',
              variant: 'quiet',
              onPressed: () => _open('34-history'),
            ),
          ]),
        ],
      ),
    );
  }
}
