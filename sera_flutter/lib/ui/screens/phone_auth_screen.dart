import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../data/auth_repository.dart';
import '../../data/phone_auth_repository.dart';
import '../../data/workspace_repository.dart';
import '../core/sera_motion.dart';
import '../core/community_login_return.dart';
import '../core/sera_widgets.dart';

enum PhoneAuthMode { login, bindPhone, manageIdentity }

void _revealPhoneStatus(
  BuildContext context,
  GlobalKey key,
  AuthRepository auth,
  bool Function() current,
) {
  final owner = auth.sessionOwner;
  final route = ModalRoute.of(context);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted ||
        !current() ||
        owner != auth.sessionOwner ||
        !(route?.isCurrent ?? true)) {
      return;
    }
    final target = key.currentContext;
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

/// Can be pushed by the account screen without changing the shared router.
class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({
    super.key,
    this.mode = PhoneAuthMode.login,
    this.repository,
    this.token,
    this.onCompleted,
    this.onEmailLogin,
    this.onAuthenticated,
  });
  final PhoneAuthMode mode;
  final PhoneAuthRepository? repository;
  final String? token;
  final VoidCallback? onCompleted, onEmailLogin;
  final ValueChanged<bool>? onAuthenticated;

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  PhoneAuthRepository? _repository;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repository ??=
        widget.repository ??
        PhoneAuthRepository(auth: context.read<AuthRepository>());
  }

  void _emailLogin() {
    if (widget.onEmailLogin != null) {
      widget.onEmailLogin!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go(
        communityAuthLink(
          '/login',
          communityLoginReturn(
            GoRouter.maybeOf(context)?.state.uri.queryParameters['returnTo'],
          ),
        ),
      );
    }
  }

  void _completeBinding() {
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      context.go('/04');
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository!;
    final login = widget.mode == PhoneAuthMode.login;
    final returnTo = communityLoginReturn(
      GoRouter.maybeOf(context)?.state.uri.queryParameters['returnTo'],
    );
    return SeraScaffold(
      title: login
          ? '手机号登录'
          : widget.mode == PhoneAuthMode.bindPhone
          ? '绑定手机号'
          : '邮箱与密码',
      showBack: true,
      onBack: login ? () => context.go(returnTo ?? '/30') : widget.onCompleted,
      body: widget.mode == PhoneAuthMode.manageIdentity
          ? _IdentityManagement(repository: repository, token: widget.token)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PhoneCodePanel(
                  repository: repository,
                  purpose: login
                      ? PhoneChallengePurpose.login
                      : PhoneChallengePurpose.bindPhone,
                  onLogin: (result) {
                    if (widget.onAuthenticated != null) {
                      widget.onAuthenticated!(result.created);
                    } else {
                      context.go(returnTo ?? '/30');
                    }
                  },
                  onBound: _completeBinding,
                ),
                if (login) ...[
                  const SizedBox(height: 12),
                  SeraButton(
                    '使用邮箱或用户名登录',
                    variant: 'quiet',
                    onPressed: _emailLogin,
                  ),
                ],
              ],
            ),
    );
  }
}

/// Embed this before a passwordless account's sensitive operation. The callback
/// receives an opaque, memory-only proof; never render or persist its value.
class RecentPhoneVerification extends StatelessWidget {
  const RecentPhoneVerification({
    super.key,
    required this.repository,
    required this.onVerified,
  });
  final PhoneAuthRepository repository;
  final ValueChanged<PhoneSensitiveProof> onVerified;

  @override
  Widget build(BuildContext context) => _PhoneCodePanel(
    repository: repository,
    purpose: PhoneChallengePurpose.sensitive,
    onVerified: onVerified,
  );
}

class _PhoneCodePanel extends StatefulWidget {
  const _PhoneCodePanel({
    required this.repository,
    required this.purpose,
    this.onLogin,
    this.onBound,
    this.onVerified,
  });
  final PhoneAuthRepository repository;
  final PhoneChallengePurpose purpose;
  final ValueChanged<PhoneLoginResult>? onLogin;
  final VoidCallback? onBound;
  final ValueChanged<PhoneSensitiveProof>? onVerified;

  @override
  State<_PhoneCodePanel> createState() => _PhoneCodePanelState();
}

class _PhoneCodePanelState extends State<_PhoneCodePanel> {
  final _errorKey = GlobalKey();
  final _noticeKey = GlobalKey();
  final _pendingKey = GlobalKey();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  PhoneAuthCapabilities? _capabilities;
  PhoneChallenge? _challenge;
  PhoneBindingRefreshPending? _bindingPending;
  DateTime? _retryAt;
  Timer? _timer;
  late Object _owner;
  String? _error, _notice;
  bool _checking = false, _sending = false, _verifying = false;
  bool _consent = false, _verified = false, _acceptingLogin = false;
  bool _obscurePassword = true;
  bool _bindingCompletionDelivered = false;
  String? _phoneIdentity;
  int _generation = 0;

  AuthRepository get _auth => widget.repository.auth;
  bool get _login => widget.purpose == PhoneChallengePurpose.login;
  bool get _sensitive => widget.purpose == PhoneChallengePurpose.sensitive;
  bool get _busy => _sending || _verifying;
  int get _codeLength => _capabilities?.codeLength ?? 6;
  bool get _validPhone {
    try {
      PhoneAuthRepository.normalizePhone(_phone.text);
      return true;
    } on RepositoryException {
      return false;
    }
  }

  bool get _challengeExpired =>
      _challenge != null &&
      !_challenge!.expiresAt.isAfter(widget.repository.now);
  bool get _canSend =>
      _capabilities?.enabled == true &&
      !_checking &&
      !_busy &&
      _remaining == 0 &&
      _validPhone &&
      (!_requiresPassword || _password.text.isNotEmpty);
  bool get _canVerify =>
      _challenge != null &&
      !_challengeExpired &&
      !_busy &&
      RegExp('^\\d{$_codeLength}\$').hasMatch(_code.text.trim());
  bool get _requiresPassword =>
      widget.purpose == PhoneChallengePurpose.bindPhone &&
      (_auth.session?.user.hasPassword ?? true);
  int get _remaining {
    final milliseconds =
        _retryAt?.difference(widget.repository.now).inMilliseconds ?? 0;
    return milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
  }

  @override
  void initState() {
    super.initState();
    _owner = _auth.sessionOwner;
    if (_sensitive) _phone.text = _auth.session?.user.phone ?? '';
    _phoneIdentity = _normalizedPhone();
    _auth.addListener(_accountChanged);
    _phone.addListener(_phoneChanged);
    _code.addListener(_inputChanged);
    _password.addListener(_inputChanged);
    // This panel is also built inside the account page's Provider consumer.
    // Starting AuthRepository's notifying request during that build would
    // mark its ancestor dirty. Wait until the initial frame has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkCapabilities());
    });
  }

  void _accountChanged() {
    final owner = _auth.sessionOwner;
    if (owner == _owner) return;
    _owner = owner;
    // authenticateSession is responsible for rejecting an external account
    // switch. Its own successful login also changes this owner.
    if (_acceptingLogin) return;
    _generation++;
    _code.clear();
    _password.clear();
    if (_sensitive) _phone.text = _auth.session?.user.phone ?? '';
    if (mounted) {
      setState(() {
        _challenge = null;
        _bindingPending = null;
        _obscurePassword = true;
        _verified = false;
        _consent = false;
        _bindingCompletionDelivered = false;
        _sending = false;
        _verifying = false;
        _checking = false;
        _notice = null;
        _error = '登录状态已变化，请重新验证手机号。';
      });
      _reveal(_errorKey);
      unawaited(_checkCapabilities(clearError: false));
    }
  }

  void _phoneChanged() {
    if (!mounted) return;
    final normalized = _normalizedPhone();
    setState(() {
      if (normalized != _phoneIdentity) {
        _consent = false;
        _error = null;
        _phoneIdentity = normalized;
      }
      if (_challenge != null && normalized != _challenge!.phone) {
        _challenge = null;
        _code.clear();
        _notice = null;
      }
    });
  }

  String? _normalizedPhone() {
    try {
      return PhoneAuthRepository.normalizePhone(_phone.text);
    } on RepositoryException {
      return null;
    }
  }

  void _reveal(GlobalKey key) {
    final generation = _generation;
    _revealPhoneStatus(
      context,
      key,
      _auth,
      () => mounted && generation == _generation,
    );
  }

  void _completeBoundPage() {
    if (_bindingCompletionDelivered ||
        _auth.sessionOwner != _owner ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    setState(() => _bindingCompletionDelivered = true);
    widget.onBound?.call();
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkCapabilities({bool clearError = true}) async {
    if (_checking) return;
    final generation = _generation;
    setState(() {
      _checking = true;
      if (clearError) _error = null;
    });
    try {
      final result = await widget.repository.capabilities();
      if (!mounted || generation != _generation) return;
      setState(() => _capabilities = result);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
        _reveal(_errorKey);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _checking = false);
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          (_remaining == 0 && (_challenge == null || _challengeExpired))) {
        timer.cancel();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _send() async {
    if (!_canSend) return;
    try {
      PhoneAuthRepository.normalizePhone(_phone.text);
      if (_requiresPassword && _password.text.isEmpty) {
        throw const RepositoryException('绑定手机号前，请输入当前账户密码。');
      }
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    final generation = _generation;
    setState(() {
      _sending = true;
      _error = null;
      _notice = null;
      _verified = false;
      _challenge = null;
      _code.clear();
      // Also wait after an ambiguous provider/network error. Only an explicit
      // user action after the cooldown can send again.
      _retryAt = widget.repository.now.add(
        Duration(seconds: _capabilities!.cooldownSeconds),
      );
    });
    _startTimer();
    try {
      final challenge = await widget.repository.requestChallenge(
        phone: _phone.text,
        purpose: widget.purpose,
        currentPassword: _requiresPassword ? _password.text : null,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _challenge = challenge;
        _retryAt = challenge.resendAt;
        _code.clear();
        _notice = challenge.message;
      });
      _startTimer();
      _reveal(_noticeKey);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          // A new attempt may have invalidated the old server challenge.
          _challenge = null;
          _error = '$error\n如果没有收到短信，请等倒计时结束后重新获取。';
        });
        _reveal(_errorKey);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    if (!_canVerify || challenge == null) return;
    final generation = _generation;
    final route = ModalRoute.of(context);
    setState(() {
      _verifying = true;
      _acceptingLogin = _login;
      _error = null;
    });
    try {
      if (_login) {
        final result = await widget.repository.login(
          challenge: challenge,
          code: _code.text,
          acceptRegistration: _consent,
          isCurrent: () =>
              mounted &&
              generation == _generation &&
              (route?.isCurrent ?? true),
        );
        if (!mounted ||
            generation != _generation ||
            !(route?.isCurrent ?? true)) {
          return;
        }
        _code.clear();
        _password.clear();
        widget.onLogin?.call(result);
      } else if (_sensitive) {
        final proof = await widget.repository.verifySensitive(
          challenge: challenge,
          code: _code.text,
        );
        if (!mounted || generation != _generation) {
          return;
        }
        setState(() {
          _verified = true;
          _challenge = null;
          _notice = '手机号已验证。请在 5 分钟内完成本次操作。';
          _code.clear();
        });
        widget.onVerified?.call(proof);
        if (mounted) _reveal(_noticeKey);
      } else {
        await widget.repository.bindPhone(
          challenge: challenge,
          code: _code.text,
          currentPassword: _requiresPassword ? _password.text : null,
          isCurrent: () => mounted && generation == _generation,
        );
        if (!mounted || generation != _generation) {
          return;
        }
        setState(() {
          _verified = true;
          _challenge = null;
          _notice = '手机号已绑定，已继续使用当前账户。';
          _password.clear();
          _code.clear();
        });
        _completeBoundPage();
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is PhoneBindingRefreshPending ? null : '$error';
          if (error is PhoneBindingRefreshPending) {
            _bindingPending = error;
            _challenge = null;
            _notice = null;
            _code.clear();
            _password.clear();
          }
          if (_auth.sessionOwner != challenge.owner) {
            _challenge = null;
            _code.clear();
            _password.clear();
          }
        });
        _reveal(error is PhoneBindingRefreshPending ? _pendingKey : _errorKey);
      }
    } finally {
      _acceptingLogin = false;
      if (mounted && generation == _generation) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _refreshBinding() async {
    final receipt = _bindingPending;
    if (_busy || receipt == null) return;
    final generation = _generation;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.repository.refreshBoundPhone(
        receipt,
        isCurrent: () => mounted && generation == _generation,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _bindingPending = null;
        _verified = true;
        _notice = '手机号已绑定，已继续使用当前账户。';
      });
      _completeBoundPage();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
        _reveal(_errorKey);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _verifying = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _auth.removeListener(_accountChanged);
    _phone.removeListener(_phoneChanged);
    _code.removeListener(_inputChanged);
    _password.removeListener(_inputChanged);
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities;
    final available = capabilities?.enabled == true;
    final alreadyBound =
        widget.purpose == PhoneChallengePurpose.bindPhone &&
        (_auth.session?.user.phone?.isNotEmpty ?? false);
    if (!_login && !_auth.signedIn) {
      return const SeraNote('请先登录账户', body: '验证操作只能用于当前登录账户。', icon: 'shield');
    }
    if (alreadyBound && !_verified && _bindingPending == null) {
      return const SeraNote('当前账户已绑定手机号', body: '暂不支持更换已绑定号码。', icon: 'shield');
    }
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_checking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (capabilities != null && !available) ...[
            SeraNote(
              '短信登录暂未启用',
              body: capabilities.message,
              icon: 'shield',
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
            const SizedBox(height: 16),
          ],
          if (!available)
            SeraButton(
              '重新检查短信服务',
              variant: 'ghost',
              busy: _checking,
              onPressed: _checking ? null : _checkCapabilities,
            ),
          if (!_verified && _bindingPending == null) ...[
            const SizedBox(height: 12),
            const Text('中国大陆手机号（+86）'),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('phone-number'),
              controller: _phone,
              enabled: !_busy,
              readOnly: _sensitive,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumberNational],
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) {
                if (value == null || value.trim().isEmpty) return null;
                try {
                  PhoneAuthRepository.normalizePhone(value);
                  return null;
                } on RepositoryException {
                  return '请输入有效的中国大陆 11 位手机号码。';
                }
              },
              decoration: const InputDecoration(hintText: '输入 11 位手机号码'),
            ),
            if (_requiresPassword) ...[
              const SizedBox(height: 16),
              const Text('当前账户密码'),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('phone-current-password'),
                controller: _password,
                enabled: !_busy,
                obscureText: _obscurePassword,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  hintText: '验证当前账户身份',
                  suffixIcon: IconButton(
                    key: const ValueKey('phone-current-password-visibility'),
                    tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SeraButton(
              _remaining > 0
                  ? '$_remaining 秒后可重新获取'
                  : _challenge == null
                  ? '获取短信验证码'
                  : '重新获取验证码',
              variant: 'secondary',
              busy: _sending,
              onPressed: _canSend ? _send : null,
            ),
            if (_challenge != null) ...[
              const SizedBox(height: 16),
              Text('接收号码：${_challenge!.maskedPhone}'),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('phone-code'),
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(_codeLength),
                ],
                decoration: InputDecoration(
                  hintText: '输入 $_codeLength 位验证码',
                  helperText: _challengeExpired ? '本次验证码已过期，请手动重新获取。' : null,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '重发后旧验证码失效，请勿泄露。',
                style: TextStyle(fontSize: 12, color: SeraColors.muted),
              ),
            ],
            if (_login) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _consent,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _consent = value == true),
                title: const Text(
                  '同意为未注册号码创建 SERA 账户',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text('已有账户请先登录后绑定手机号。'),
              ),
            ],
            const SizedBox(height: 16),
            SeraButton(
              _login
                  ? '验证并登录'
                  : _sensitive
                  ? '验证当前手机号'
                  : '确认绑定手机号',
              variant: _sensitive ? 'secondary' : 'primary',
              busy: _verifying,
              onPressed: _canVerify ? _verify : null,
            ),
          ],
          if (_bindingPending != null) ...[
            const SizedBox(height: 16),
            Semantics(
              key: _pendingKey,
              liveRegion: true,
              child: const Text('手机号已绑定，请刷新账户状态。'),
            ),
            const SizedBox(height: 12),
            SeraButton(
              '刷新账户并继续',
              key: const ValueKey('phone-refresh-binding'),
              busy: _verifying,
              onPressed: _busy ? null : _refreshBinding,
            ),
          ],
          if (_verified &&
              !_login &&
              !_sensitive &&
              !_bindingCompletionDelivered)
            SeraButton('继续', onPressed: _completeBoundPage),
          if (_notice != null) ...[
            const SizedBox(height: 16),
            Semantics(
              key: _noticeKey,
              liveRegion: true,
              child: SeraNote(
                _verified
                    ? '验证已完成'
                    : _challenge?.deliveryStatus == 'unknown'
                    ? '暂时无法确认短信是否发出'
                    : '已请求发送短信',
                body: _notice,
                icon: _challenge?.deliveryStatus == 'unknown'
                    ? 'warning'
                    : 'check',
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              key: _errorKey,
              liveRegion: true,
              child: SeraNote(
                '暂时没有完成',
                body: _error,
                icon: 'warning',
                color: SeraColors.red,
                background: SeraColors.redBg,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _IdentityAction { email, password }

class _IdentityManagement extends StatefulWidget {
  const _IdentityManagement({required this.repository, this.token});
  final PhoneAuthRepository repository;
  final String? token;

  @override
  State<_IdentityManagement> createState() => _IdentityManagementState();
}

class _IdentityManagementState extends State<_IdentityManagement> {
  final _errorKey = GlobalKey();
  final _noticeKey = GlobalKey();
  final _pendingKey = GlobalKey();
  final _email = TextEditingController();
  final _token = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _visibleSecrets = <String>{};
  _IdentityAction _action = _IdentityAction.email;
  PhoneSensitiveProof? _proof;
  PhoneIdentityRefreshPending? _identityPending;
  String? _pendingNotice;
  AuthMailDelivery? _delivery;
  String? _error, _notice;
  bool _busy = false;
  int _generation = 0, _verificationEpoch = 0;
  late Object _owner;

  AuthRepository get _auth => widget.repository.auth;

  void _reveal(GlobalKey key) {
    final generation = _generation;
    _revealPhoneStatus(
      context,
      key,
      _auth,
      () => mounted && generation == _generation,
    );
  }

  void _keepPending(PhoneIdentityRefreshPending receipt, String notice) {
    _identityPending = receipt;
    _pendingNotice = notice;
    _proof = null;
    _delivery = null;
    _token.clear();
    _password.clear();
    _confirm.clear();
    _visibleSecrets.clear();
    _error = null;
    _notice = null;
    _verificationEpoch++;
  }

  @override
  void initState() {
    super.initState();
    _owner = _auth.sessionOwner;
    _token.text = widget.token ?? '';
    if (_auth.session?.user.email.isNotEmpty == true) {
      _action = _IdentityAction.password;
    }
    _auth.addListener(_accountChanged);
  }

  @override
  void didUpdateWidget(covariant _IdentityManagement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) {
      _generation++;
      _token.text = widget.token ?? '';
      _busy = false;
      _notice = null;
      _error = null;
    }
  }

  void _accountChanged() {
    if (_auth.sessionOwner == _owner) return;
    _owner = _auth.sessionOwner;
    _generation++;
    _password.clear();
    _confirm.clear();
    _visibleSecrets.clear();
    _token.clear();
    _email.clear();
    if (mounted) {
      setState(() {
        _proof = null;
        _identityPending = null;
        _pendingNotice = null;
        _delivery = null;
        _notice = null;
        _busy = false;
        _verificationEpoch++;
        _error = '登录状态已变化，请重新打开账户安全页面。';
      });
    }
  }

  Future<void> _submitIdentity() async {
    if (_busy || _identityPending != null) return;
    final proof = _proof;
    if (proof == null ||
        proof.consumed ||
        !proof.expiresAt.isAfter(widget.repository.now)) {
      setState(() {
        _proof = null;
        _verificationEpoch++;
        _error = '请先验证当前手机号，再完成本次操作。';
      });
      _reveal(_errorKey);
      return;
    }
    if (_action == _IdentityAction.password &&
        _password.text != _confirm.text) {
      setState(() => _error = '两次输入的密码不一致。');
      _reveal(_errorKey);
      return;
    }
    final generation = _generation;
    final owner = _auth.sessionOwner;
    final hadPassword = _auth.session?.user.hasPassword == true;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_action == _IdentityAction.email) {
        final delivery = await widget.repository.requestEmailBinding(
          email: _email.text,
          proof: proof,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _delivery = delivery;
          _notice = delivery.message;
        });
      } else {
        await widget.repository.setPassword(
          password: _password.text,
          proof: proof,
          isCurrent: () => mounted && generation == _generation,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _notice = hadPassword ? '密码已重设，其他登录已退出。' : '密码已设置，其他登录已退出。';
          _password.clear();
          _confirm.clear();
          _visibleSecrets.clear();
        });
      }
      _reveal(_noticeKey);
    } catch (error) {
      if (mounted && generation == _generation && owner == _auth.sessionOwner) {
        setState(() {
          if (error is PhoneIdentityRefreshPending) {
            _keepPending(
              error,
              hadPassword ? '密码已重设，其他登录已退出。' : '密码已设置，其他登录已退出。',
            );
          } else {
            _error = '$error';
          }
        });
        _reveal(error is PhoneIdentityRefreshPending ? _pendingKey : _errorKey);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          if (proof.consumed) {
            _proof = null;
            _verificationEpoch++;
          }
        });
      }
    }
  }

  Future<void> _confirmEmail() async {
    if (_busy || _identityPending != null) return;
    final generation = _generation;
    final owner = _auth.sessionOwner;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.confirmEmailBinding(
        _token.text,
        isCurrent: () => mounted && generation == _generation,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _token.clear();
          _notice = '电子邮箱已绑定并验证，账户状态已刷新。';
          _delivery = null;
        });
        _reveal(_noticeKey);
      }
    } catch (error) {
      if (mounted && generation == _generation && owner == _auth.sessionOwner) {
        setState(() {
          if (error is PhoneIdentityRefreshPending) {
            _keepPending(error, '电子邮箱已绑定并验证。');
          } else {
            _error = '$error';
          }
        });
        _reveal(error is PhoneIdentityRefreshPending ? _pendingKey : _errorKey);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _refreshIdentity() async {
    final receipt = _identityPending;
    if (_busy || receipt == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.refreshIdentity(
        receipt,
        isCurrent: () => mounted && generation == _generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _identityPending = null;
        _notice = _pendingNotice;
        _pendingNotice = null;
      });
      _reveal(_noticeKey);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
        _reveal(_errorKey);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _auth.removeListener(_accountChanged);
    _email.dispose();
    _token.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Widget _secret(
    String label,
    TextEditingController controller,
    String key, {
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey(key),
          controller: controller,
          enabled: !_busy,
          obscureText: !_visibleSecrets.contains(key),
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            helperText: helper,
            suffixIcon: IconButton(
              key: ValueKey('$key-visibility'),
              tooltip: _visibleSecrets.contains(key) ? '隐藏密码' : '显示密码',
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      if (!_visibleSecrets.remove(key)) {
                        _visibleSecrets.add(key);
                      }
                    }),
              icon: Icon(
                _visibleSecrets.contains(key)
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final user = _auth.session?.user;
    if (user == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SeraNote(
            '请先登录账户',
            body: '请先登录原账户，再粘贴本次绑定邮件链接。',
            icon: 'shield',
          ),
          const SizedBox(height: 16),
          SeraButton('登录原账户', onPressed: () => context.go('/login')),
        ],
      );
    }
    final canBindEmail = user.email.isEmpty;
    final canSetPassword = user.phone?.isNotEmpty == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SeraField('手机号', user.phone ?? '尚未绑定'),
        SeraField('邮箱', user.email.isEmpty ? '尚未绑定' : user.email),
        SeraField('密码', user.hasPassword ? '已设置' : '尚未设置'),
        if (_identityPending != null) ...[
          const SizedBox(height: 16),
          Semantics(
            key: _pendingKey,
            liveRegion: true,
            child: Text('${_pendingNotice ?? '操作已完成。'}请刷新账户状态。'),
          ),
          const SizedBox(height: 12),
          SeraButton(
            '刷新账户状态',
            key: const ValueKey('identity-refresh'),
            busy: _busy,
            onPressed: _busy ? null : _refreshIdentity,
          ),
        ],
        if (_identityPending == null && (canBindEmail || canSetPassword)) ...[
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('绑定邮箱'),
                selected: _action == _IdentityAction.email,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _action = _IdentityAction.email;
                        _proof = null;
                        _verificationEpoch++;
                        _error = null;
                      }),
              ),
              ChoiceChip(
                label: Text(user.hasPassword ? '重设密码' : '设置密码'),
                selected: _action == _IdentityAction.password,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _action = _IdentityAction.password;
                        _proof = null;
                        _verificationEpoch++;
                        _error = null;
                      }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_action == _IdentityAction.email && !canBindEmail)
            const SeraNote(
              '当前账户已有邮箱',
              body: '暂不支持更换已绑定邮箱。邮箱还未验证时，可在账户页完成验证。',
              icon: 'shield',
            )
          else if (_action == _IdentityAction.password && !canSetPassword)
            const SeraNote(
              '当前账户尚未绑定手机号',
              body: '请先绑定手机号，或使用现有邮箱找回密码。',
              icon: 'shield',
            )
          else ...[
            if (_proof == null)
              RecentPhoneVerification(
                key: ValueKey('identity-verification-$_verificationEpoch'),
                repository: widget.repository,
                onVerified: (proof) => setState(() {
                  _proof = proof;
                  _error = null;
                }),
              )
            else
              const SeraNote(
                '手机号已验证',
                body: '请在 5 分钟内完成下面这一个操作。',
                icon: 'check',
              ),
            const SizedBox(height: 20),
            if (_action == _IdentityAction.email) ...[
              SeraInput(
                label: '待绑定电子邮箱',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
              ),
            ] else ...[
              _secret(
                '新密码',
                _password,
                'identity-new-password',
                helper: '10–128 个字符',
              ),
              _secret('确认新密码', _confirm, 'identity-confirm-password'),
            ],
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _token,
              builder: (context, value, child) => SeraButton(
                _action == _IdentityAction.email
                    ? '发送绑定邮箱邮件'
                    : user.hasPassword
                    ? '重设账户密码'
                    : '设置账户密码',
                variant:
                    _action == _IdentityAction.email &&
                        (value.text.isNotEmpty || _delivery != null)
                    ? 'secondary'
                    : 'primary',
                busy: _busy,
                onPressed: _busy ? null : _submitIdentity,
              ),
            ),
          ],
        ],
        if (_identityPending == null &&
            _action == _IdentityAction.email &&
            (canBindEmail || _token.text.isNotEmpty || _delivery != null)) ...[
          const SizedBox(height: 24),
          SeraDisclosure(
            title: '确认邮箱绑定',
            summary: '已有邮件链接时，粘贴后确认',
            initiallyExpanded: _token.text.isNotEmpty || _delivery != null,
            children: [
              const Text('保持原账户登录，粘贴本次绑定邮件链接。'),
              const SizedBox(height: 12),
              SeraInput(label: '邮件中的绑定链接', controller: _token),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _token,
                builder: (context, value, child) => SeraButton(
                  '确认绑定电子邮箱',
                  variant: value.text.trim().isEmpty ? 'secondary' : 'primary',
                  busy: _busy,
                  onPressed: _busy ? null : _confirmEmail,
                ),
              ),
            ],
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 16),
          Semantics(
            key: _noticeKey,
            liveRegion: true,
            child: SeraNote('操作结果', body: _notice, icon: 'check'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Semantics(
            key: _errorKey,
            liveRegion: true,
            child: SeraNote(
              '暂时没有完成',
              body: _error,
              icon: 'warning',
              color: SeraColors.red,
              background: SeraColors.redBg,
            ),
          ),
        ],
      ],
    );
  }
}
