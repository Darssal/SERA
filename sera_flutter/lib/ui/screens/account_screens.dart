import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../data/auth_repository.dart';
import '../../data/phone_auth_repository.dart';
import '../../data/repositories.dart';
import '../../application/sera_controller.dart';
import '../../domain/models.dart';
import '../../platform/platform_services.dart';
import '../core/sera_motion.dart';
import '../core/community_login_return.dart';
import '../core/sera_widgets.dart';
import 'phone_auth_screen.dart';

Widget buildAccountScreen(String id, {String? token}) {
  if (const [
    'phone-login',
    'bind-phone',
    'phone-identity',
    'phone-email',
  ].contains(id)) {
    return PhoneAuthScreen(
      mode: id == 'phone-login'
          ? PhoneAuthMode.login
          : id == 'bind-phone'
          ? PhoneAuthMode.bindPhone
          : PhoneAuthMode.manageIdentity,
      token: token,
    );
  }
  return AccountScreen(mode: id, token: token);
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.mode, this.token});
  final String mode;
  final String? token;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _form = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _token = TextEditingController();
  final _errorKey = GlobalKey();
  final _noticeKey = GlobalKey();
  bool _obscure = true, _busy = false;
  String? _error, _export, _notice;
  Workspace? _legacyLocal, _legacyRemote;
  bool _legacyRead = false;
  AuthMailDelivery? _delivery;
  DevelopmentVerificationMailbox? _mailbox;
  Object? _recoveryOwner;
  int _recoveryGeneration = 0;
  PhoneSensitiveProof? _deletePhoneProof;
  int _deleteProofEpoch = 0;
  bool _confirmingDelete = false;

  void _revealStatus() {
    final auth = context.read<AuthRepository>();
    final owner = auth.sessionOwner;
    final generation = _recoveryGeneration;
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _recoveryGeneration ||
          owner != auth.sessionOwner ||
          !(route?.isCurrent ?? true)) {
        return;
      }
      final target = (_error != null ? _errorKey : _noticeKey).currentContext;
      if (target == null || !target.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          duration: SeraMotion.scrollDuration(context),
          alignment: 0.1,
        ),
      );
    });
  }

  void _revealFirstInvalidField() {
    final route = ModalRoute.of(context);
    final auth = context.read<AuthRepository>();
    final owner = auth.sessionOwner;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          owner != auth.sessionOwner ||
          !(route?.isCurrent ?? true)) {
        return;
      }
      BuildContext? invalid;
      void visit(Element element) {
        if (invalid != null) return;
        if (element is StatefulElement &&
            element.state is FormFieldState &&
            (element.state as FormFieldState).hasError) {
          invalid = element;
        } else {
          element.visitChildElements(visit);
        }
      }

      _form.currentContext?.visitChildElements(visit);
      final target = invalid;
      if (target != null && target.mounted) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: SeraMotion.scrollDuration(context),
            alignment: 0.1,
          ),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _token.text = widget.token ?? '';
  }

  @override
  void didUpdateWidget(covariant AccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode || oldWidget.token != widget.token) {
      _recoveryGeneration++;
      _token.text = widget.token ?? '';
      _notice = null;
      _error = null;
      _delivery = null;
      _mailbox = null;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _identifier.dispose();
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) {
      _revealFirstInvalidField();
      return;
    }
    final auth = context.read<AuthRepository>();
    final route = ModalRoute.of(context);
    final generation = _recoveryGeneration;
    final returnTo = communityLoginReturn(
      GoRouter.maybeOf(context)?.state.uri.queryParameters['returnTo'],
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.mode == 'register') {
        await auth.register(
          username: _username.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
        );
      } else {
        await auth.login(
          identifier: _identifier.text.trim(),
          password: _password.text,
        );
      }
      if (mounted &&
          generation == _recoveryGeneration &&
          (route?.isCurrent ?? true)) {
        _password.clear();
        _confirmPassword.clear();
        // Signing in is an optional action from My. The root also retains
        // this destination when replacing the local workspace controller.
        context.go(returnTo ?? '/30');
      }
    } catch (error) {
      if (mounted && generation == _recoveryGeneration) {
        setState(() => _error = '$error');
        _revealStatus();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _passwordField(
    String label,
    TextEditingController controller, {
    bool confirm = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 8),
      TextFormField(
        controller: controller,
        obscureText: _obscure,
        autofillHints: [
          widget.mode == 'register' || widget.mode == 'reset-password'
              ? AutofillHints.newPassword
              : AutofillHints.password,
        ],
        keyboardType: TextInputType.visiblePassword,
        enableSuggestions: false,
        autocorrect: false,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: confirm ? '再输入一次密码' : '输入密码',
          suffixIcon: IconButton(
            tooltip: _obscure ? '显示密码' : '隐藏密码',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
            ),
          ),
        ),
        validator: (value) {
          if (confirm) return value != _password.text ? '两次输入的密码不一致。' : null;
          if (value == null || value.isEmpty) return '请输入密码。';
          if ((widget.mode == 'register' || widget.mode == 'reset-password') &&
              (value.length < 10 || value.length > 128)) {
            return '密码需要 10–128 个字符。';
          }
          return null;
        },
      ),
      const SizedBox(height: 18),
    ],
  );

  Widget _authForm(AuthRepository auth) {
    final register = widget.mode == 'register';
    final returnTo = communityLoginReturn(
      GoRouter.maybeOf(context)?.state.uri.queryParameters['returnTo'],
    );
    return SeraScaffold(
      title: register ? '创建账户' : '登录并同步',
      onBack: () => context.go(returnTo ?? '/30'),
      body: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              if (!register &&
                  auth.lastSessionExitReason == 'password_reset') ...[
                const SeraNote(
                  '密码已重置',
                  body: '请使用新密码登录。之前登录的设备也需要重新登录，任务和计划会保留。',
                  icon: 'check',
                ),
                const SizedBox(height: 16),
              ],
              if (register) ...[
                SeraInput(
                  label: '用户名',
                  controller: _username,
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    return RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]{3,40}$')
                            .hasMatch(text)
                        ? null
                        : '用户名需要 3–40 个中文、字母、数字、下划线或连字符。';
                  },
                ),
                SeraInput(
                  label: '电子邮箱',
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) =>
                      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                          .hasMatch(value?.trim() ?? '')
                      ? null
                      : '请输入有效的电子邮箱。',
                ),
              ] else
                SeraInput(
                  label: '邮箱或用户名',
                  controller: _identifier,
                  validator: (value) =>
                      value?.trim().isEmpty ?? true ? '请输入邮箱或用户名。' : null,
                ),
              _passwordField('密码', _password),
              if (register)
                _passwordField('确认密码', _confirmPassword, confirm: true),
              if (_error != null || auth.error != null) ...[
                Semantics(
                  key: _errorKey,
                  liveRegion: true,
                  child: SeraNote(
                    '暂时没有完成',
                    body: _error ?? auth.error,
                    color: SeraColors.red,
                    background: SeraColors.redBg,
                    icon: 'warning',
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (auth.logoutWarning != null) ...[
                SeraNote(
                  '已在此设备退出',
                  body: auth.logoutWarning,
                  color: SeraColors.amber,
                  background: SeraColors.amberBg,
                  icon: 'shield',
                ),
                const SizedBox(height: 16),
              ],
              SeraButton(
                register ? '创建账户并开始' : '登录',
                onPressed: _busy || auth.loading ? null : _submit,
                busy: _busy || auth.loading,
              ),
              const SizedBox(height: 12),
              SeraButton(
                register ? '已有账户，去登录' : '还没有账户，去注册',
                variant: 'quiet',
                onPressed: _busy
                    ? null
                    : () => context.go(
                        communityAuthLink(
                          register ? '/login' : '/register',
                          returnTo,
                        ),
                      ),
              ),
              if (!register)
                SeraButton(
                  '使用手机号验证码登录',
                  variant: 'quiet',
                  onPressed: _busy
                      ? null
                      : () => context.push(
                          communityAuthLink('/phone-login', returnTo),
                        ),
                ),
              if (!register)
                SeraButton(
                  '忘记密码',
                  variant: 'quiet',
                  onPressed: _busy
                      ? null
                      : () => context.push(
                          communityAuthLink('/forgot-password', returnTo),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportAccount() async {
    if (_busy || _confirmingDelete) return;
    final auth = context.read<AuthRepository>();
    final owner = auth.sessionOwner;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await auth.exportAccount();
      if (mounted && owner == auth.sessionOwner) {
        setState(
          () => _export = const JsonEncoder.withIndent('  ').convert(data),
        );
      }
    } catch (error) {
      if (mounted && owner == auth.sessionOwner) {
        setState(() => _error = '$error');
        _revealStatus();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final auth = context.read<AuthRepository>();
    final hasPassword = auth.session?.user.hasPassword != false;
    final proof = _deletePhoneProof;
    if (_busy) return;
    if (hasPassword && _password.text.isEmpty ||
        !hasPassword &&
            (proof == null ||
                proof.consumed ||
                !proof.expiresAt.isAfter(DateTime.now()))) {
      setState(
        () => _error = hasPassword ? '删除账户前，请输入当前密码。' : '删除账户前，请重新验证当前绑定手机号。',
      );
      _revealStatus();
      return;
    }
    final owner = auth.sessionOwner;
    final accountId = auth.session?.user.id;
    final route = ModalRoute.of(context);
    if (_confirmingDelete) return;
    _confirmingDelete = true;
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('删除账户和全部数据？'),
        content: const Text('账户和其中的任务、目标、日程等记录都会删除，无法恢复。请先备份需要保留的内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留账户'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认删除', style: TextStyle(color: SeraColors.red)),
          ),
        ],
      ),
    );
    _confirmingDelete = false;
    if (confirmed != true ||
        !mounted ||
        owner != auth.sessionOwner ||
        !(route?.isCurrent ?? true)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.deleteAccount(
        _password.text,
        phoneProof: hasPassword
            ? null
            : PhoneAuthRepository(auth: auth).consumeForAccountDeletion(proof!),
      );
      if (!mounted) return;
      _password.clear();
      if (!auth.signedIn &&
          auth.deletedUserId == accountId &&
          (route?.isCurrent ?? true)) {
        context.go('/30');
      }
    } catch (error) {
      if (mounted && owner == auth.sessionOwner) {
        setState(() => _error = '$error');
        _revealStatus();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deletePhoneProof = null;
          _deleteProofEpoch++;
        });
      }
    }
  }

  Future<void> _readLegacy() async {
    if (_busy) return;
    final auth = context.read<AuthRepository>();
    final owner = auth.sessionOwner;
    setState(() {
      _busy = true;
      _error = null;
    });
    final errors = <String>[];
    Workspace? local, remote;
    try {
      local = await LocalWorkspaceRepository().load();
    } catch (error) {
      errors.add('此设备：$error');
    }
    if (!mounted || owner != auth.sessionOwner) return;
    try {
      remote = await auth.readLegacyGuest();
    } catch (error) {
      errors.add('旧版云端记录：$error');
    }
    if (mounted && owner == auth.sessionOwner) {
      setState(() {
        _legacyLocal = local;
        _legacyRemote = remote;
        _legacyRead = true;
        _busy = false;
        _error = errors.isEmpty ? null : errors.join('\n');
      });
      if (_error != null) _revealStatus();
    }
  }

  Future<void> _importLegacy(Workspace value, String source) async {
    final auth = context.read<AuthRepository>();
    final c = context.read<SeraController?>();
    if (c == null || _busy) return;
    final account = auth.session?.user.id;
    final owner = auth.sessionOwner;
    final route = ModalRoute.of(context);
    final yes = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('用旧版记录替换当前内容？'),
        content: Text(
          '来源：$source\n将导入 ${value.tasks.length} 项任务、${value.goals.length} 个目标和 ${value.entries.length} 项安排。\n\n账户「${auth.session?.user.username ?? ''}」当前的 ${c.data.tasks.length} 项任务、${c.data.goals.length} 个目标和 ${c.data.entries.length} 项安排将被替换。建议先保存备份。原来的旧版记录会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认替换并导入'),
          ),
        ],
      ),
    );
    if (yes != true ||
        !mounted ||
        owner != auth.sessionOwner ||
        !(route?.isCurrent ?? true)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.importGuest(value, expectedRevision: c.data.revision);
      if (!mounted ||
          owner != auth.sessionOwner ||
          account != auth.session?.user.id ||
          !identical(c, context.read<SeraController?>())) {
        return;
      }
      await c.refresh();
      if (mounted && owner == auth.sessionOwner) {
        setState(() => _notice = '旧版记录已导入当前账户，原来的记录仍然保留。');
        _revealStatus();
      }
    } catch (error) {
      if (mounted && owner == auth.sessionOwner) {
        setState(() => _error = '$error');
        _revealStatus();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _legacyPreview(Workspace value, String source) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: SeraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            source,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            '${value.tasks.length} 项任务 · ${value.goals.length} 个目标 · ${value.entries.length} 项安排',
            style: const TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
          const SizedBox(height: 10),
          for (final task in value.tasks.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(task.title, style: const TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 10),
          SeraButton(
            '预览并导入$source',
            variant: 'ghost',
            onPressed: _busy ? null : () => _importLegacy(value, source),
          ),
        ],
      ),
    ),
  );

  Widget _accountAction(String label, {VoidCallback? onPressed}) => ListTile(
    contentPadding: EdgeInsets.zero,
    minTileHeight: 56,
    title: Text(label, style: const TextStyle(fontSize: 15)),
    trailing: const SeraIcon('chevron', size: 18, color: SeraColors.muted),
    onTap: onPressed,
    enabled: onPressed != null,
  );

  Widget _account(AuthRepository auth) {
    final session = auth.session;
    final sessionOwner = auth.sessionOwner;
    if (session == null) {
      return SeraScaffold(
        title: '账户',
        onBack: () => context.go('/30'),
        body: SeraEmpty(
          '还没有登录',
          '记录已保存在此设备。',
          icon: 'user',
          action: '登录并同步',
          onAction: () => context.go('/login'),
        ),
      );
    }
    return SeraScaffold(
      title: '账户与安全',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SeraField('用户名', session.user.username),
          SeraField(
            '邮箱',
            session.user.email.isEmpty ? '尚未绑定' : session.user.email,
          ),
          if (session.user.email.isNotEmpty)
            SeraField('邮箱验证', session.user.emailVerified ? '已验证' : '待验证'),
          SeraField('手机号', session.user.phone ?? '尚未绑定'),
          SeraField('账户密码', session.user.hasPassword ? '已设置' : '尚未设置'),
          SeraField(
            '登录有效期',
            '${formatDate(session.expiresAt.toLocal())} ${formatTime(session.expiresAt.toLocal())}',
          ),
          if (session.user.email.isNotEmpty && !session.user.emailVerified) ...[
            const SizedBox(height: 16),
            _accountAction(
              '验证电子邮箱',
              onPressed: () => context.push('/verify-email'),
            ),
          ],
          const SizedBox(height: 16),
          if (session.user.phone == null)
            _accountAction(
              '绑定手机号',
              onPressed: _busy ? null : () => context.push('/bind-phone'),
            )
          else
            _accountAction(
              '邮箱与密码',
              onPressed: _busy ? null : () => context.push('/phone-identity'),
            ),
          _accountAction('准备账户备份', onPressed: _busy ? null : _exportAccount),
          if (_export != null) ...[
            const SizedBox(height: 16),
            SeraCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '备份内容已就绪',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '可保存为 JSON 文件，或复制完整内容。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: SeraColors.muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SeraButton(
                    '保存备份',
                    icon: 'download',
                    onPressed: () async {
                      await runAction(
                        context,
                        () => platformServices.downloadText(
                          _export!,
                          filename:
                              'sera-account-${DateTime.now().millisecondsSinceEpoch}.json',
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  SeraButton(
                    '复制内容',
                    variant: 'quiet',
                    onPressed: () async {
                      final owner = auth.sessionOwner;
                      await Clipboard.setData(ClipboardData(text: _export!));
                      if (mounted && owner == auth.sessionOwner) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('备份内容已复制。')),
                        );
                      }
                    },
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('查看备份内容', style: TextStyle(fontSize: 13)),
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            _export!,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          SeraDisclosure(
            title: '导入旧版记录',
            summary: '先查看内容，再决定是否导入',
            children: [
              const Text(
                '查找此设备和旧版云端保存的记录。确认导入会替换当前账户中的内容。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.8,
                  color: SeraColors.muted,
                ),
              ),
              const SizedBox(height: 12),
              SeraButton(
                '查找旧版记录',
                variant: 'ghost',
                busy: _busy,
                onPressed: _busy ? null : _readLegacy,
              ),
              if (_legacyRead && _legacyLocal == null && _legacyRemote == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    '没有找到旧版记录。',
                    style: TextStyle(fontSize: 13, color: SeraColors.muted),
                  ),
                ),
              if (_legacyLocal != null)
                _legacyPreview(_legacyLocal!, '此设备的旧版记录'),
              if (_legacyRemote != null)
                _legacyPreview(_legacyRemote!, '旧版云端记录'),
            ],
          ),
          if (_notice != null) ...[
            const SizedBox(height: 12),
            Semantics(
              key: _noticeKey,
              liveRegion: true,
              child: SeraNote('已完成', body: _notice, icon: 'check'),
            ),
          ],
          const SizedBox(height: 20),
          _accountAction(
            '退出登录',
            onPressed: _busy
                ? null
                : () async {
                    final route = ModalRoute.of(context);
                    setState(() {
                      _busy = true;
                      _error = null;
                    });
                    try {
                      await auth.logout();
                      if (mounted &&
                          !auth.signedIn &&
                          (route?.isCurrent ?? true)) {
                        context.go('/30');
                      }
                    } catch (error) {
                      if (mounted && sessionOwner == auth.sessionOwner) {
                        setState(() => _error = '$error');
                        _revealStatus();
                      }
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          const SizedBox(height: 20),
          SeraDisclosure(
            title: '删除账户与数据',
            summary: session.user.hasPassword
                ? '需要当前密码，确认后无法恢复'
                : '需要验证当前手机号，确认后无法恢复',
            children: [
              SeraNote(
                '先保留需要的数据',
                body: session.user.hasPassword
                    ? '账户删除后无法恢复。此操作需要当前密码并再次确认。'
                    : '账户删除后无法恢复。请重新验证当前绑定手机号，再次确认后删除。',
                icon: 'shield',
                color: SeraColors.amber,
                background: SeraColors.amberBg,
              ),
              const SizedBox(height: 20),
              if (session.user.hasPassword)
                _passwordField('当前密码', _password)
              else ...[
                RecentPhoneVerification(
                  key: ValueKey('delete-phone-proof-$_deleteProofEpoch'),
                  repository: PhoneAuthRepository(auth: auth),
                  onVerified: (proof) {
                    if (mounted && sessionOwner == auth.sessionOwner) {
                      setState(() => _deletePhoneProof = proof);
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
              SeraButton(
                '删除账户与数据',
                variant: 'danger',
                onPressed: _busy ? null : _deleteAccount,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              key: _errorKey,
              liveRegion: true,
              child: SeraNote(
                '操作没有完成',
                body: _error,
                color: SeraColors.red,
                background: SeraColors.redBg,
                icon: 'warning',
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();
    return switch (widget.mode) {
      'account' => _account(auth),
      'verify-email' ||
      'forgot-password' ||
      'reset-password' => _recovery(auth),
      _ => _authForm(auth),
    };
  }

  Future<void> _recoveryAction(
    Future<String> Function(bool Function() current) action, {
    bool signsOut = false,
  }) async {
    if (_busy) return;
    final auth = context.read<AuthRepository>();
    final owner = _recoveryIdentity(auth);
    final generation = ++_recoveryGeneration;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _recoveryOwner = owner;
    });
    bool current() =>
        mounted &&
        generation == _recoveryGeneration &&
        (_recoveryIdentity(auth) == owner || (signsOut && !auth.signedIn));
    try {
      final message = await action(current);
      if (current()) {
        setState(() {
          _notice = message;
          _recoveryOwner = _recoveryIdentity(auth);
        });
        _revealStatus();
      }
    } catch (error) {
      if (current()) {
        setState(() => _error = '$error');
        _revealStatus();
      }
    } finally {
      if (mounted && generation == _recoveryGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Object? _recoveryIdentity(AuthRepository auth) => auth.session == null
      ? null
      : (auth.session!.user.id, auth.session!.sessionId);

  Future<void> _sendVerification(AuthRepository auth) =>
      _recoveryAction((current) async {
        final owner = _recoveryIdentity(auth);
        final generation = _recoveryGeneration;
        // A resend may revoke the old action before delivery fails.
        setState(() => _mailbox = null);
        final delivery = await auth.requestEmailVerification();
        if (!mounted ||
            generation != _recoveryGeneration ||
            _recoveryIdentity(auth) != owner) {
          return '';
        }
        setState(() {
          _delivery = delivery;
          _mailbox = null;
        });
        if (delivery.status == 'already_verified') {
          await auth.refreshCurrentUser();
        }
        if (delivery.developmentPreview) {
          final mailbox = await auth.developmentVerificationMailbox();
          if (mounted &&
              generation == _recoveryGeneration &&
              _recoveryIdentity(auth) == owner) {
            setState(() => _mailbox = mailbox);
          }
        }
        return delivery.message;
      });

  Future<void> _readDevelopmentMail(AuthRepository auth) =>
      _recoveryAction((current) async {
        final owner = _recoveryIdentity(auth);
        final generation = _recoveryGeneration;
        final mailbox = await auth.developmentVerificationMailbox();
        if (mounted &&
            generation == _recoveryGeneration &&
            _recoveryIdentity(auth) == owner) {
          setState(() => _mailbox = mailbox);
        }
        return mailbox.message;
      });

  Future<void> _confirmVerification(AuthRepository auth, String token) =>
      _recoveryAction((current) async {
        await auth.confirmEmailVerification(token);
        if (current()) {
          setState(() {
            _mailbox = null;
            _token.clear();
          });
        }
        return auth.signedIn ? '邮箱验证成功。' : '邮箱已验证，请登录账户查看。';
      });

  Widget _developmentMail(
    DevelopmentVerificationMail mail,
    AuthRepository auth,
  ) => SeraCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          mail.subject,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        const Text(
          '这是一封测试邮件，只保存在当前服务中，没有发送到你的邮箱。',
          style: TextStyle(fontSize: 13, height: 1.7),
        ),
        const SizedBox(height: 10),
        Text(
          '有效期至 ${formatDate(mail.expiresAt.toLocal())} ${formatTime(mail.expiresAt.toLocal())}',
          style: const TextStyle(fontSize: 12, color: SeraColors.muted),
        ),
        const SizedBox(height: 10),
        SelectableText(
          mail.verificationUrl,
          style: const TextStyle(fontSize: 12, height: 1.7),
        ),
        const SizedBox(height: 12),
        SeraButton(
          '使用此链接验证邮箱',
          busy: _busy,
          onPressed: _busy
              ? null
              : () => _confirmVerification(auth, mail.token),
        ),
      ],
    ),
  );

  Widget _recovery(AuthRepository auth) {
    final returnTo = communityLoginReturn(
      GoRouter.maybeOf(context)?.state.uri.queryParameters['returnTo'],
    );
    final verify = widget.mode == 'verify-email';
    final reset = widget.mode == 'reset-password';
    final sameOwner = _recoveryOwner == _recoveryIdentity(auth);
    final mailbox = sameOwner ? _mailbox : null;
    final verified = verify && auth.session?.user.emailVerified == true;
    return SeraScaffold(
      title: verify
          ? '验证邮箱'
          : reset
          ? '设置新密码'
          : '找回密码',
      body: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (verify && auth.signedIn)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(auth.session!.user.email),
              ),
            if (reset)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('保存后请使用新密码登录。'),
              ),
            if (!verify && !reset)
              SeraInput(
                label: '注册邮箱',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                validator: (v) =>
                    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                        .hasMatch(v?.trim() ?? '')
                    ? null
                    : '请输入有效的电子邮箱。',
              ),
            if (verify) ...[
              if (verified)
                const SeraNote('邮箱已验证', body: '当前账户的邮箱已完成验证。', icon: 'check'),
              if (!verified && auth.signedIn)
                SeraButton(
                  !sameOwner || _delivery == null ? '发送验证邮件' : '重新发送验证邮件',
                  variant: 'secondary',
                  busy: _busy,
                  onPressed: _busy || !auth.signedIn
                      ? null
                      : () => _sendVerification(auth),
                ),
              if (!verified && auth.signedIn) ...[
                const SizedBox(height: 12),
                SeraButton(
                  '刷新验证状态',
                  variant: 'quiet',
                  onPressed: _busy
                      ? null
                      : () => _recoveryAction((current) async {
                          await auth.refreshCurrentUser();
                          return auth.session?.user.emailVerified == true
                              ? '邮箱验证成功。'
                              : '邮箱尚未验证。请使用最新邮件中的链接；链接失效时可重新发送。';
                        }),
                ),
              ],
              if (!verified &&
                  auth.signedIn &&
                  sameOwner &&
                  (_delivery?.developmentPreview == true ||
                      mailbox != null)) ...[
                const SizedBox(height: 12),
                if (mailbox?.mail != null)
                  _developmentMail(mailbox!.mail!, auth)
                else
                  SeraDisclosure(
                    title: '测试验证邮件',
                    summary: '仅测试环境可用，查看当前账户的验证邮件',
                    children: [
                      const Text(
                        '测试邮件不会发送到你的邮箱，这里只能查看邮箱验证邮件。',
                        style: TextStyle(fontSize: 13, height: 1.7),
                      ),
                      const SizedBox(height: 12),
                      SeraButton(
                        '查看测试验证邮件',
                        variant: 'secondary',
                        onPressed: _busy
                            ? null
                            : () => _readDevelopmentMail(auth),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 20),
            ],
            if ((verify && !verified) || reset) ...[
              SeraInput(
                label: verify ? '邮件中的验证链接' : '邮件中的重置链接',
                controller: _token,
                minLines: 2,
                maxLines: 4,
                validator: (v) =>
                    v?.trim().isEmpty ?? true ? '请粘贴邮件中的完整链接。' : null,
              ),
            ],
            if (reset) ...[
              _passwordField('新密码', _password),
              _passwordField('确认新密码', _confirmPassword, confirm: true),
            ],
            if (!verified)
              SeraButton(
                verify
                    ? '确认验证邮箱'
                    : reset
                    ? '保存新密码'
                    : '发送重置邮件',
                busy: _busy,
                onPressed: _busy
                    ? null
                    : () {
                        if (!(_form.currentState?.validate() ?? false)) {
                          _revealFirstInvalidField();
                          return;
                        }
                        if (verify) {
                          _confirmVerification(auth, _token.text.trim());
                        } else if (reset) {
                          _recoveryAction((current) async {
                            await auth.resetPassword(
                              token: _token.text.trim(),
                              password: _password.text,
                            );
                            if (current()) {
                              _password.clear();
                              _confirmPassword.clear();
                              _token.clear();
                            }
                            return '新密码已保存，请使用新密码登录。';
                          }, signsOut: true);
                        } else {
                          _recoveryAction((current) async {
                            final delivery = await auth.requestPasswordReset(
                              _email.text.trim(),
                            );
                            if (current()) setState(() => _delivery = delivery);
                            return delivery.message;
                          });
                        }
                      },
              ),
            if (!verify && !reset) ...[
              const SizedBox(height: 12),
              SeraButton(
                '已有重置邮件',
                variant: 'quiet',
                onPressed: () => context.push(
                  communityAuthLink('/reset-password', returnTo),
                ),
              ),
            ],
            if (!verify &&
                !reset &&
                sameOwner &&
                _delivery?.isLocal == true) ...[
              const SizedBox(height: 16),
              const SeraNote(
                '测试邮件模式',
                body: '当前为测试邮件模式，邮件不会发送到你的邮箱。请联系应用管理员取得重置链接，或开启邮件发送后重试。',
                color: SeraColors.amber,
                background: SeraColors.amberBg,
              ),
            ],
            if (sameOwner && _notice != null) ...[
              const SizedBox(height: 20),
              Semantics(
                key: _noticeKey,
                liveRegion: true,
                child: SeraNote('处理结果', body: _notice, icon: 'check'),
              ),
            ],
            if (sameOwner && _error != null) ...[
              const SizedBox(height: 20),
              Semantics(
                key: _errorKey,
                liveRegion: true,
                child: SeraNote(
                  '暂时没有完成',
                  body: _error,
                  color: SeraColors.red,
                  background: SeraColors.redBg,
                  icon: 'warning',
                ),
              ),
            ],
            const SizedBox(height: 12),
            SeraButton(
              verify && auth.signedIn ? '返回账户' : '返回登录',
              variant: 'quiet',
              onPressed: () => context.go(
                verify && auth.signedIn
                    ? '/account'
                    : communityAuthLink('/login', returnTo),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
