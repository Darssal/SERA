import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/sera_controller.dart';
import '../../data/auth_repository.dart';
import '../../domain/models.dart';
import '../screens/voice_screens.dart';
import 'sera_motion.dart';
import 'sera_widgets.dart';

/// Voice-first capture for Today, with AI planning as the primary next step.
/// Keep input in this page's State until the resulting operation is confirmed.
class SeraCaptureEntry extends StatefulWidget {
  const SeraCaptureEntry({super.key, this.origin = 'tasks'});

  final String origin;

  @override
  State<SeraCaptureEntry> createState() => _SeraCaptureEntryState();
}

class _SeraCaptureEntryState extends State<SeraCaptureEntry> {
  final _prompt = TextEditingController();
  bool _opening = false;
  bool _sheetOpen = false;

  bool _sameOwner(
    SeraController controller,
    String account,
    AuthRepository? auth,
    AuthSession? session,
  ) =>
      mounted &&
      identical(context.read<SeraController>(), controller) &&
      controller.accountId == account &&
      identical(context.read<AuthRepository?>(), auth) &&
      auth?.session?.user.id == session?.user.id &&
      auth?.session?.sessionId == session?.sessionId &&
      auth?.session?.token == session?.token;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_opening || _sheetOpen) return;
    final c = context.read<SeraController>();
    final account = c.accountId;
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    _sheetOpen = true;
    var voiceMode = true;
    String? action;
    try {
      action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: SeraMotion.sheetStyle(context),
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, updateSheet) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '说说你的安排',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  if (voiceMode)
                    VoiceInputScreen(
                      embedded: true,
                      holdToTalk: true,
                      initialText: _prompt.text,
                      onTextChanged: (text) {
                        if (_sameOwner(c, account, auth, session)) {
                          _prompt.text = text;
                        }
                      },
                      onConfirmed: (text) {
                        if (!_sameOwner(c, account, auth, session)) return;
                        _prompt.text = text;
                        Navigator.pop(sheetContext, 'ai');
                      },
                    )
                  else ...[
                    TextField(
                      key: const ValueKey('capture-text-input'),
                      controller: _prompt,
                      autofocus: true,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: '要做什么？'),
                    ),
                    const SizedBox(height: 16),
                    SeraButton(
                      '让 AI 安排',
                      icon: 'spark',
                      onPressed: () => Navigator.pop(sheetContext, 'ai'),
                    ),
                    const SizedBox(height: 8),
                    SeraButton(
                      '手动添加任务',
                      variant: 'quiet',
                      onPressed: () => Navigator.pop(sheetContext, 'task'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        updateSheet(() => voiceMode = !voiceMode);
                      },
                      icon: Icon(
                        voiceMode ? Icons.keyboard_outlined : Icons.mic_none,
                        size: 20,
                      ),
                      label: Text(voiceMode ? '文字输入' : '语音输入'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      _sheetOpen = false;
    }
    if (action == null ||
        !mounted ||
        !_sameOwner(c, account, auth, session) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await _plan(manual: action == 'task');
  }

  Future<void> _plan({required bool manual}) async {
    if (_opening) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_prompt.text.trim().isEmpty) {
      await context.push(
        manual ? '/19?mode=todo' : '/05?new=1&from=${widget.origin}',
      );
      return;
    }
    final c = context.read<SeraController>();
    final account = c.accountId;
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final route = ModalRoute.of(context);
    final id = c.newId('planning');
    setState(() => _opening = true);
    try {
      await c.savePlanningSession(
        PlanningSession(
          id: id,
          prompt: _prompt.text.trim(),
          dailyBudget: c.data.preferences.dailyBudget,
          updatedAt: DateTime.now(),
        ),
      );
      if (!mounted ||
          !_sameOwner(c, account, auth, session) ||
          route?.isCurrent != true) {
        return;
      }
      await context.push(
        Uri(
          path: manual ? '/19' : '/05',
          queryParameters: {
            'sessionId': id,
            'from': widget.origin,
            if (manual) 'mode': 'todo',
            if (manual) 'manual': '1' else 'submit': '1',
          },
        ).toString(),
      );
      if (_sameOwner(c, account, auth, session) &&
          route?.isCurrent == true &&
          c.planningSession(id)?.stage == 'confirmed') {
        _prompt.clear();
      }
    } catch (error) {
      if (mounted &&
          _sameOwner(c, account, auth, session) &&
          route?.isCurrent == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => SeraCard(
    padding: EdgeInsets.zero,
    child: ListTile(
      // Preserve automation links to the former home capture control.
      key: const ValueKey('today-capture'),
      leading: const SeraIcon('mic', size: 20),
      title: const Text('交给 AI 安排', style: TextStyle(fontSize: 15)),
      trailing: _opening
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const SeraIcon('spark', size: 20),
      onTap: _opening ? null : _capture,
    ),
  );
}
