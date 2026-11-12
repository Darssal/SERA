import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/auth_repository.dart';
import '../../data/device_workspace_repository.dart';
import '../../application/sera_controller.dart';
import '../../platform/platform_services.dart';
import '../core/sera_widgets.dart';

class VoiceInputScreen extends StatefulWidget {
  const VoiceInputScreen({
    super.key,
    this.connect,
    this.embedded = false,
    this.holdToTalk = false,
    this.initialText = '',
    this.onTextChanged,
    this.onConfirmed,
  });
  final WebSocketChannel Function(Uri uri)? connect;
  final bool embedded, holdToTalk;
  final String initialText;
  final ValueChanged<String>? onTextChanged, onConfirmed;
  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

enum _VoiceStage { idle, recording, recognizing, ready, failed }

class _VoiceInputScreenState extends State<VoiceInputScreen>
    with WidgetsBindingObserver {
  late final _text = TextEditingController(text: widget.initialText);
  late String _lastReportedText = widget.initialText;
  final _watch = Stopwatch();
  Timer? _ticker;
  RecordedAudio? _audio;
  AuthRepository? _auth;
  DeviceWorkspaceRepository? _device;
  _VoiceStage _stage = _VoiceStage.idle;
  String? _error;
  bool _starting = false;
  bool _realtime = true;
  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _audioStream;
  StreamSubscription<dynamic>? _socketStream;
  Completer<String>? _finalTranscript;
  String _partial = '';
  int _operation = 0;
  bool _leaving = false;
  bool _holdActive = false, _receivedAudio = false, _streamStarted = false;
  bool _scopeInitialized = false;
  Object? _scope;
  String _recordingBase = '';

  Object _currentScope() {
    final auth = context.read<AuthRepository?>();
    final controller = context.read<SeraController?>();
    return (auth, auth?.session, controller, controller?.accountId);
  }

  bool _current(int operation, Object scope) =>
      mounted &&
      operation == _operation &&
      _currentScope() == scope &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(_textChanged);
  }

  void _textChanged() {
    if (_text.text == _lastReportedText) return;
    _lastReportedText = _text.text;
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      widget.onTextChanged?.call(_text.text);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (_starting ||
            _stage == _VoiceStage.recording ||
            _stage == _VoiceStage.recognizing)) {
      unawaited(_cancel());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.watch<AuthRepository?>();
    final repository = context.watch<SeraController?>()?.repository;
    _device = repository is DeviceWorkspaceRepository ? repository : null;
    final scope = _currentScope();
    final changed = _scopeInitialized && _scope != scope;
    final covered = ModalRoute.of(context)?.isCurrent != true;
    if (changed ||
        (covered &&
            (_starting ||
                _stage == _VoiceStage.recording ||
                _stage == _VoiceStage.recognizing))) {
      final operation = _operation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && operation == _operation) {
          unawaited(_cancel());
          if (changed) _text.clear();
        }
      });
    }
    _scope = scope;
    _scopeInitialized = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operation++;
    _ticker?.cancel();
    _watch.stop();
    unawaited(_releaseStream(cancel: true));
    if (_stage == _VoiceStage.recording || _starting) {
      unawaited(platformServices.cancelRecording().catchError((Object _) {}));
    }
    if (_stage == _VoiceStage.recognizing) _auth?.cancelTranscription();
    _device?.cancelTranscription();
    _text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting ||
        _stage == _VoiceStage.recording ||
        _stage == _VoiceStage.recognizing) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final auth = context.read<AuthRepository?>();
    if (auth?.signedIn != true && _device == null) {
      setState(() => _error = '语音服务暂不可用，请先连接服务或使用文字输入。');
      return;
    }
    _recordingBase = _text.text.trim();
    _receivedAudio = false;
    if (_realtime) {
      await _startRealtime(auth);
      return;
    }
    final operation = ++_operation;
    final owner = (auth?.session?.user.id, auth?.session?.sessionId);
    bool ownsRequest() =>
        mounted &&
        operation == _operation &&
        (auth?.session?.user.id, auth?.session?.sessionId) == owner;
    bool current() =>
        ownsRequest() && ModalRoute.of(context)?.isCurrent == true;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await platformServices.startRecording();
      if (!current()) {
        // A cancel/dispose already invalidates the native recording request.
        // Do not let its late completion stop a newer recording operation.
        if (operation == _operation &&
            (auth?.session?.user.id, auth?.session?.sessionId) == owner) {
          await platformServices.cancelRecording();
        }
        return;
      }
      _watch
        ..reset()
        ..start();
      _audio = null;
      setState(() => _stage = _VoiceStage.recording);
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        setState(() {});
        if (_watch.elapsedMilliseconds >= 59000) unawaited(_stopAndRecognize());
      });
    } catch (error) {
      if (current()) {
        setState(() {
          _error = '$error';
          _stage = _VoiceStage.failed;
        });
      }
    } finally {
      // Clearing this request's busy flag is safe while covered and makes the
      // original page usable again if the user returns to it.
      if (ownsRequest()) setState(() => _starting = false);
    }
  }

  Future<void> _stopAndRecognize() async {
    if (_stage != _VoiceStage.recording) return;
    if (_realtime) {
      await _finishRealtime();
      return;
    }
    final operation = _operation;
    final scope = _currentScope();
    _ticker?.cancel();
    _watch.stop();
    setState(() {
      _stage = _VoiceStage.recognizing;
      _error = null;
    });
    try {
      _audio = await platformServices.stopRecording();
      if (!_current(operation, scope)) return;
      await _recognize();
    } catch (error) {
      if (_current(operation, scope)) {
        setState(() {
          _error = '$error';
          _stage = _VoiceStage.failed;
        });
      }
    }
  }

  Future<void> _recognize() async {
    final audio = _audio;
    if (audio == null) return;
    final operation = ++_operation;
    final scope = _currentScope();
    _auth = context.read<AuthRepository?>();
    setState(() {
      _stage = _VoiceStage.recognizing;
      _error = null;
    });
    try {
      final text = _auth?.signedIn == true
          ? await _auth!.transcribeAudio(
              audio.bytes,
              filename: audio.fileName,
              mimeType: audio.mimeType,
              durationMilliseconds: audio.durationMilliseconds,
            )
          : await _device!.transcribeAudio(
              audio.bytes,
              filename: audio.fileName,
              mimeType: audio.mimeType,
              durationMilliseconds: audio.durationMilliseconds,
            );
      if (!_current(operation, scope)) return;
      _text.text = [
        _recordingBase,
        text.trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      setState(() => _stage = _VoiceStage.ready);
    } catch (error) {
      if (!_current(operation, scope)) return;
      setState(() {
        _error = '$error';
        _stage = _VoiceStage.failed;
      });
    }
  }

  Future<void> _cancel() async {
    _holdActive = false;
    final operation = ++_operation;
    _ticker?.cancel();
    _watch.stop();
    _auth?.cancelTranscription();
    _device?.cancelTranscription();
    if (mounted) {
      setState(() {
        _stage = _VoiceStage.idle;
        _starting = true;
      });
    }
    await _releaseStream(cancel: true);
    try {
      await platformServices.cancelRecording();
    } catch (_) {
      /* Stop/cancel may already have released the recording. */
    }
    if (!mounted || operation != _operation) return;
    _audio = null;
    setState(() {
      _stage = _VoiceStage.idle;
      _error = null;
      _starting = false;
    });
  }

  Future<void> _leave({bool home = false}) async {
    if (_leaving) return;
    final route = ModalRoute.of(context);
    final auth = context.read<AuthRepository?>();
    final owner = (auth?.session?.user.id, auth?.session?.sessionId);
    _leaving = true;
    try {
      await _cancel();
      if (!mounted ||
          route?.isCurrent != true ||
          (auth?.session?.user.id, auth?.session?.sessionId) != owner) {
        return;
      }
      if (home || !context.canPop()) {
        context.go('/04');
      } else {
        context.pop();
      }
    } finally {
      _leaving = false;
    }
  }

  Future<void> _releaseStream({required bool cancel}) async {
    // Detach everything before awaiting so old cleanup cannot close a new session.
    final channel = _channel;
    final audio = _audioStream;
    final socket = _socketStream;
    final finalText = _finalTranscript;
    final started = _streamStarted;
    _channel = null;
    _audioStream = null;
    _socketStream = null;
    _finalTranscript = null;
    _streamStarted = false;
    if (finalText != null && !finalText.isCompleted) finalText.complete('');
    try {
      if (cancel) channel?.sink.add(jsonEncode({'type': 'cancel'}));
    } catch (_) {}
    if (started) {
      try {
        await platformServices.stopAudioStream(cancel: cancel);
      } catch (_) {}
    }
    await audio?.cancel();
    // Detaching the listener and sending close are immediate. Their futures can
    // wait for the remote peer; microphone release must not leave the editor or
    // the next attempt blocked on a WebSocket close handshake.
    if (socket != null) unawaited(socket.cancel().catchError((Object _) {}));
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
  }

  Future<void> _startRealtime(AuthRepository? auth) async {
    final operation = ++_operation;
    final scope = _currentScope();
    setState(() {
      _starting = true;
      _error = null;
      _partial = '';
      _audio = null;
    });
    try {
      final ticket = auth?.signedIn == true
          ? await auth!.createAsrTicket()
          : await _device!.createAsrTicket();
      if (!_current(operation, scope)) return;
      final base = Uri.parse(ticket['websocketUrl'] as String);
      final uri = base.replace(
        queryParameters: {
          ...base.queryParameters,
          'ticket': '${ticket['ticket']}',
        },
      );
      final channel = (widget.connect ?? WebSocketChannel.connect)(uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (!_current(operation, scope)) {
        // This channel belongs to the old operation even if another has started.
        if (operation == _operation) {
          await _releaseStream(cancel: true);
        } else {
          try {
            await channel.sink.close();
          } catch (_) {}
        }
        return;
      }
      final finalText = Completer<String>();
      _finalTranscript = finalText;
      _socketStream = channel.stream.listen(
        (event) {
          if (!_current(operation, scope)) return;
          try {
            final message = jsonDecode(event as String) as Map<String, dynamic>;
            final type = message['type'];
            if (type == 'partial' || type == 'final') {
              final text = '${message['text'] ?? ''}';
              setState(() => _partial = text);
              if (type == 'final' && !finalText.isCompleted) {
                finalText.complete(text);
              }
            } else if (type == 'error') {
              unawaited(
                _liveFailure(
                  '${message['message'] ?? '语音识别暂时没有完成，请稍后重试。'}',
                  operation,
                ),
              );
            }
          } catch (_) {
            unawaited(_liveFailure('收到的识别结果无效，请重新录音。', operation));
          }
        },
        onError: (Object error) {
          if (_current(operation, scope)) {
            unawaited(_liveFailure('语音连接已中断，请检查网络后重试。', operation));
          }
        },
        onDone: () {
          if (_current(operation, scope) && _stage == _VoiceStage.recording) {
            unawaited(_liveFailure('语音连接已结束，请重新录音。', operation));
          }
        },
      );
      channel.sink.add(
        jsonEncode({
          'type': 'start',
          'sampleRate': 16000,
          'format': 's16le',
          'channels': 1,
        }),
      );
      _watch
        ..reset()
        ..start();
      setState(() => _stage = _VoiceStage.recording);
      _streamStarted = true;
      _audioStream = platformServices.startAudioStream().listen(
        (frame) {
          if (_current(operation, scope) && _stage == _VoiceStage.recording) {
            _receivedAudio = true;
            channel.sink.add(frame);
          }
        },
        onError: (Object error) {
          if (_current(operation, scope)) {
            unawaited(_liveFailure('$error', operation));
          }
        },
        onDone: () {
          if (_current(operation, scope) && _stage == _VoiceStage.recording) {
            unawaited(_finishRealtime());
          }
        },
      );
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!_current(operation, scope)) {
          if (mounted && operation == _operation) unawaited(_cancel());
          return;
        }
        setState(() {});
        if (_watch.elapsedMilliseconds >= 59000) unawaited(_finishRealtime());
      });
    } catch (error) {
      if (_current(operation, scope)) await _liveFailure('$error', operation);
    } finally {
      if (mounted && operation == _operation) setState(() => _starting = false);
    }
  }

  Future<void> _liveFailure(String error, int operation) async {
    if (!mounted || operation != _operation) return;
    final cleanup = ++_operation;
    _ticker?.cancel();
    _watch.stop();
    _holdActive = false;
    setState(() {
      _stage = _VoiceStage.failed;
      _error = error;
      _starting = true;
    });
    await _releaseStream(cancel: true);
    if (mounted && cleanup == _operation) setState(() => _starting = false);
  }

  Future<void> _finishRealtime() async {
    if (_stage != _VoiceStage.recording) return;
    final operation = _operation;
    final scope = _currentScope();
    final finalText = _finalTranscript;
    final channel = _channel;
    _holdActive = false;
    _ticker?.cancel();
    _watch.stop();
    setState(() {
      _stage = _VoiceStage.recognizing;
      _starting = true;
    });
    try {
      await platformServices.stopAudioStream();
      if (!_current(operation, scope)) return;
      await _audioStream?.cancel();
      _audioStream = null;
      if (!_current(operation, scope)) return;
      channel?.sink.add(jsonEncode({'type': 'finish'}));
      final text = await finalText!.future.timeout(const Duration(seconds: 30));
      if (!_current(operation, scope)) return;
      if (text.trim().isEmpty) {
        throw const FormatException('没有识别到清晰语音，可以重新录音或直接编辑文字。');
      }
      _text.text = [
        _recordingBase,
        text.trim(),
      ].where((s) => s.isNotEmpty).join('\n');
      setState(() => _stage = _VoiceStage.ready);
      await _releaseStream(cancel: false);
    } catch (error) {
      if (_current(operation, scope)) await _liveFailure('$error', operation);
    } finally {
      if (mounted && operation == _operation) setState(() => _starting = false);
    }
  }

  Future<void> _openSettings() async {
    await runAction(context, platformServices.openApplicationSettings);
  }

  void _holdStart(LongPressStartDetails _) {
    if (_starting ||
        _stage == _VoiceStage.recording ||
        _stage == _VoiceStage.recognizing) {
      return;
    }
    _holdActive = true;
    unawaited(_start());
  }

  void _holdEnd(LongPressEndDetails _) {
    if (!_holdActive) return;
    _holdActive = false;
    // A pending ticket, permission dialog or native start is canceled, never
    // allowed to turn into an unattended recording after the finger is lifted.
    if (_starting || (_realtime && !_receivedAudio)) {
      unawaited(_cancel());
    } else if (_stage == _VoiceStage.recording) {
      unawaited(_stopAndRecognize());
    }
  }

  void _holdCancel() {
    if (_holdActive) unawaited(_cancel());
  }

  void _toggleRecording() {
    if (_starting || _stage == _VoiceStage.recognizing) return;
    if (_stage == _VoiceStage.recording) {
      unawaited(_stopAndRecognize());
    } else {
      unawaited(_start());
    }
  }

  bool _confirmed = false;
  void _confirmText() {
    if (_confirmed ||
        _starting ||
        _stage == _VoiceStage.recording ||
        _stage == _VoiceStage.recognizing ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final text = _text.text.trim();
    if (text.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.onConfirmed case final callback?) {
      _confirmed = true;
      callback(text);
    } else {
      final from = GoRouterState.of(context).uri.queryParameters['from'];
      context.go(
        Uri(
          path: '/05',
          queryParameters: {
            'prompt': text,
            'from':
                const {
                  'today',
                  'tasks',
                  'goals',
                  'history',
                  'search',
                }.contains(from)
                ? from!
                : 'today',
          },
        ).toString(),
      );
    }
  }

  Widget _compactVoice() {
    final recording = _stage == _VoiceStage.recording;
    final recognizing = _stage == _VoiceStage.recognizing;
    final active = recording || recognizing || _starting;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          hint: widget.holdToTalk ? '长按说话，松开结束。也可点按或用键盘开始、停止。' : null,
          child: GestureDetector(
            onLongPressStart: widget.holdToTalk ? _holdStart : null,
            onLongPressEnd: widget.holdToTalk ? _holdEnd : null,
            onLongPressCancel: widget.holdToTalk ? _holdCancel : null,
            child: FilledButton.icon(
              key: const ValueKey('voice-hold-button'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 72)),
              onPressed: _starting || recognizing ? null : _toggleRecording,
              icon: Icon(recording ? Icons.stop_rounded : Icons.mic_rounded),
              label: Text(
                _starting && !recognizing
                    ? '正在连接…'
                    : recognizing
                    ? '正在整理文字…'
                    : recording
                    ? (_holdActive ? '松开结束' : '停止录音')
                    : widget.holdToTalk
                    ? '按住说话'
                    : '开始录音',
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          recording
              ? '已录音 ${_watch.elapsed.inSeconds} 秒 · 最长 60 秒'
              : _realtime
              ? '也可点按开始、再次点按结束'
              : '备用识别 · 录音结束后上传至云端转写',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: SeraColors.muted),
        ),
        if (recording || recognizing) ...[
          const SizedBox(height: 12),
          Text(
            _partial.isEmpty ? '正在听…' : _partial,
            key: const ValueKey('voice-partial'),
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ],
        if (active)
          TextButton(
            key: const ValueKey('voice-cancel'),
            onPressed: _cancel,
            child: const Text('取消录音'),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const ValueKey('voice-error'),
            style: const TextStyle(color: SeraColors.red, fontSize: 13),
          ),
          if (_error!.contains('权限') || _error!.contains('麦克风'))
            TextButton(
              onPressed: _openSettings,
              child: const Text('打开麦克风权限设置'),
            ),
          if (_realtime)
            TextButton(
              onPressed: _starting
                  ? null
                  : () => setState(() {
                      _realtime = false;
                      _error = null;
                    }),
              child: const Text('改用备用识别'),
            ),
        ],
        if (!active &&
            (_stage == _VoiceStage.ready || _text.text.isNotEmpty)) ...[
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('voice-confirmed-text'),
            controller: _text,
            minLines: 2,
            maxLines: 5,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: const InputDecoration(hintText: '识别后可在这里修改'),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (_, value, _) => SeraButton(
              '让 AI 安排',
              onPressed: value.text.trim().isEmpty || _confirmed
                  ? null
                  : _confirmText,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded || widget.holdToTalk) {
      final content = _compactVoice();
      return widget.embedded
          ? content
          : SeraScaffold(title: '语音输入', onBack: _leave, body: content);
    }
    final recording = _stage == _VoiceStage.recording;
    final recognizing = _stage == _VoiceStage.recognizing;
    final seconds = _watch.elapsed.inSeconds;
    final duration =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return SeraScaffold(
      title: '语音输入',
      onBack: _leave,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          if (!recording && !recognizing)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('边说边出字'),
                  selected: _realtime,
                  onSelected: _starting
                      ? null
                      : (_) => setState(() => _realtime = true),
                ),
                ChoiceChip(
                  label: const Text('录完后识别'),
                  selected: !_realtime,
                  onSelected: _starting
                      ? null
                      : (_) => setState(() => _realtime = false),
                ),
              ],
            ),
          if (recording || recognizing || _stage == _VoiceStage.ready)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Center(
                child: SeraTag(
                  recording
                      ? '正在录音'
                      : recognizing
                      ? '正在识别'
                      : '文字已识别',
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            recording
                ? '$duration / 01:00'
                : recognizing
                ? '录音已结束，正在识别文字…'
                : '单次最多 60 秒，识别后可以继续编辑。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
          const SizedBox(height: 24),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: recording ? SeraColors.brand : SeraColors.mint,
                borderRadius: BorderRadius.circular(30),
              ),
              child: recognizing
                  ? const Padding(
                      padding: EdgeInsets.all(25),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Center(
                      child: SeraIcon(
                        recording ? 'mic' : 'spark',
                        size: 34,
                        color: recording ? Colors.white : SeraColors.brand,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 24),
          if (_realtime && recording) ...[
            SeraCard(
              child: Text(
                _partial.isEmpty ? '开始说话后，文字会出现在这里…' : _partial,
                style: const TextStyle(fontSize: 15, height: 1.8),
              ),
            ),
            const SizedBox(height: 20),
          ],
          if (recording)
            SeraButton(
              _realtime ? '说好了，确认文字' : '完成录音，识别文字',
              icon: 'stop',
              onPressed: _stopAndRecognize,
            )
          else if (recognizing) ...[
            SeraButton('正在识别，请稍候', busy: true),
            const SizedBox(height: 12),
            SeraButton('取消识别', variant: 'quiet', onPressed: _cancel),
          ] else ...[
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _text,
              builder: (context, value, child) => SeraButton(
                _audio == null ? '开始录音' : '重新录一段',
                variant: value.text.trim().isEmpty ? 'primary' : 'secondary',
                icon: 'mic',
                busy: _starting,
                onPressed: _starting ? null : _start,
              ),
            ),
            if (_audio != null && _stage == _VoiceStage.failed) ...[
              const SizedBox(height: 12),
              SeraButton(
                '重新识别这段录音',
                variant: 'secondary',
                onPressed: _recognize,
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 20),
            SeraNote(
              '这次还没有完成',
              body: _error,
              color: SeraColors.amber,
              background: SeraColors.amberBg,
              icon: 'warning',
            ),
            const SizedBox(height: 8),
            if (_error!.contains('权限') || _error!.contains('麦克风'))
              SeraButton(
                '打开麦克风权限设置',
                variant: 'quiet',
                onPressed: _openSettings,
              ),
          ],
          if (!recording && !recognizing) ...[
            const SizedBox(height: 24),
            Text(
              _stage == _VoiceStage.ready ? '检查识别文字' : '计划文字',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _text,
              minLines: 4,
              maxLines: 8,
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: const InputDecoration(hintText: '输入你的计划'),
            ),
            const SizedBox(height: 16),
            SeraButton(
              '使用这段文字继续',
              variant: 'secondary',
              onPressed: () {
                final text = _text.text.trim();
                if (text.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请先录音识别或输入计划。')));
                  return;
                }
                context.go(
                  Uri(
                    path: '/05',
                    queryParameters: {
                      'prompt': text,
                      'from':
                          const {
                            'today',
                            'tasks',
                            'goals',
                            'history',
                            'search',
                          }.contains(
                            GoRouterState.of(context)
                                .uri
                                .queryParameters['from'],
                          )
                          ? GoRouterState.of(context)
                                .uri
                                .queryParameters['from']!
                          : 'today',
                    },
                  ).toString(),
                );
              },
            ),
          ],
          const SizedBox(height: 18),
          Text(
            recording
                ? '取消后会停止录音。'
                : _realtime
                ? '录音时会上传声音并识别文字；确认文字前不会创建任务。'
                : '录音结束后会上传识别；确认文字前不会创建任务。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: SeraColors.muted,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 8),
          SeraButton(
            recording ? '取消录音' : '返回今天',
            variant: 'quiet',
            onPressed: () => _leave(home: true),
          ),
        ],
      ),
    );
  }
}
