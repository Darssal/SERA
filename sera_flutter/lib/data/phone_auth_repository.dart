import '../domain/models.dart';
import 'auth_repository.dart';
import 'workspace_repository.dart';

enum PhoneChallengePurpose {
  login('login'),
  bindPhone('bind_phone'),
  sensitive('sensitive');

  const PhoneChallengePurpose(this.apiValue);
  final String apiValue;
}

/// The server is authoritative about availability, delivery and throttling.
class PhoneAuthCapabilities {
  const PhoneAuthCapabilities({
    required this.enabled,
    required this.message,
    this.codeLength = 6,
    this.cooldownSeconds = 60,
  });
  final bool enabled;
  final String message;
  final int codeLength, cooldownSeconds;

  factory PhoneAuthCapabilities.fromJson(Json body) {
    final enabled = body['enabled'];
    final message = body['message'];
    final codeLength = body['codeLength'] ?? 6;
    final cooldown = body['cooldownSeconds'] ?? 60;
    if (enabled is! bool ||
        message is! String ||
        message.trim().isEmpty ||
        codeLength is! int ||
        codeLength < 4 ||
        codeLength > 8 ||
        cooldown is! int ||
        cooldown < 1 ||
        cooldown > 3600) {
      throw const RepositoryException('短信服务状态无效，请稍后重试或使用邮箱登录。');
    }
    return PhoneAuthCapabilities(
      enabled: enabled,
      message: message,
      codeLength: codeLength,
      cooldownSeconds: cooldown,
    );
  }
}

class PhoneChallenge {
  const PhoneChallenge._({
    required this.id,
    required this.phone,
    required this.maskedPhone,
    required this.purpose,
    required this.expiresAt,
    required this.resendAt,
    required this.message,
    required this.deliveryStatus,
    required this.owner,
  });
  final String id, phone, maskedPhone, message, deliveryStatus;
  final PhoneChallengePurpose purpose;
  final DateTime expiresAt, resendAt;
  final Object owner;
}

/// Kept in memory only. A proof is deliberately consumed before its request so
/// an ambiguous network failure cannot cause the UI to reuse it.
class PhoneSensitiveProof {
  PhoneSensitiveProof._(this._value, this.expiresAt, this._owner);
  final String _value;
  final Object _owner;
  final DateTime expiresAt;
  bool _consumed = false;
  bool get consumed => _consumed;

  String consume(AuthRepository auth, DateTime now) {
    if (_consumed || _owner != auth.sessionOwner || !expiresAt.isAfter(now)) {
      throw const RepositoryException('本次手机号验证已失效，请重新验证后操作。');
    }
    _consumed = true;
    return _value;
  }
}

class PhoneLoginResult {
  const PhoneLoginResult({required this.created});
  final bool created;
}

enum PhoneIdentityChange { phoneBinding, emailBinding, password }

/// A confirmed write whose identity read may be retried without its one-use
/// credentials. The receipt remains in memory and belongs to one live session.
class PhoneIdentityRefreshPending extends RepositoryException {
  const PhoneIdentityRefreshPending._(this._owner, this.change, [this._phone])
    : super('操作已完成，账户状态尚未刷新。');
  final Object _owner;
  final PhoneIdentityChange change;
  final String? _phone;
}

class PhoneBindingRefreshPending extends PhoneIdentityRefreshPending {
  const PhoneBindingRefreshPending._(Object owner, String phone)
    : super._(owner, PhoneIdentityChange.phoneBinding, phone);
}

/// All traffic uses AuthRepository's bound requests. This preserves native
/// secure storage, Web HttpOnly cookies/CSRF and stale-session rejection.
class PhoneAuthRepository {
  PhoneAuthRepository({required this.auth, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final AuthRepository auth;
  final DateTime Function() _now;
  DateTime get now => _now();

  static String normalizePhone(String input) {
    var value = input.trim().replaceAll(RegExp(r'[\s\-]'), '');
    if (value.startsWith('+86')) value = value.substring(3);
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(value)) {
      throw const RepositoryException('请输入有效的中国大陆 11 位手机号码。');
    }
    return value;
  }

  Future<PhoneAuthCapabilities> capabilities() async =>
      PhoneAuthCapabilities.fromJson(
        await auth.authenticatedRequest(
          'GET',
          '/api/v1/auth/phone/capabilities',
        ),
      );

  Future<PhoneChallenge> requestChallenge({
    required String phone,
    required PhoneChallengePurpose purpose,
    String? currentPassword,
  }) async {
    final normalized = normalizePhone(phone);
    final owner = auth.sessionOwner;
    if (purpose != PhoneChallengePurpose.login && !auth.signedIn) {
      throw const RepositoryException('请先登录当前账户，再验证手机号。');
    }
    final body = await auth.authenticatedRequest(
      'POST',
      '/api/v1/auth/phone/challenge',
      data: {
        'phone': normalized,
        'purpose': purpose.apiValue,
        'currentPassword': ?currentPassword,
      },
    );
    _requireOwner(owner);
    final id = body['challengeId'];
    final maskedPhone = body['maskedPhone'];
    final message = body['message'];
    final deliveryStatus = body['deliveryStatus'];
    final expiresAt = _date(body['expiresAt']);
    final resendAt = _date(body['resendAt']);
    if (id is! String ||
        id.isEmpty ||
        maskedPhone is! String ||
        maskedPhone.isEmpty ||
        message is! String ||
        message.isEmpty ||
        !const ['submitted', 'unknown'].contains(deliveryStatus) ||
        expiresAt == null ||
        !expiresAt.isAfter(_now()) ||
        resendAt == null) {
      throw const RepositoryException('短信服务未确认有效的发送结果，请稍后重试。');
    }
    return PhoneChallenge._(
      id: id,
      phone: normalized,
      maskedPhone: maskedPhone,
      purpose: purpose,
      expiresAt: expiresAt,
      resendAt: resendAt,
      message: message,
      deliveryStatus: deliveryStatus as String,
      owner: owner,
    );
  }

  Future<PhoneLoginResult> login({
    required PhoneChallenge challenge,
    required String code,
    required bool acceptRegistration,
    bool Function()? isCurrent,
  }) async {
    _requireChallenge(challenge, PhoneChallengePurpose.login, code);
    final body = await auth.authenticateSession(
      '/api/v1/auth/phone/login',
      expectedOwner: challenge.owner,
      isCurrent: isCurrent,
      data: {
        'challengeId': challenge.id,
        'code': code.trim(),
        'acceptRegistration': acceptRegistration,
      },
    );
    return PhoneLoginResult(created: body['created'] == true);
  }

  Future<void> bindPhone({
    required PhoneChallenge challenge,
    required String code,
    String? currentPassword,
    bool Function()? isCurrent,
  }) async {
    _requireChallenge(challenge, PhoneChallengePurpose.bindPhone, code);
    _requireCurrent(challenge.owner, isCurrent);
    final body = await auth.authenticatedRequest(
      'POST',
      '/api/v1/auth/phone/bind',
      data: {
        'challengeId': challenge.id,
        'code': code.trim(),
        'currentPassword': ?currentPassword,
      },
    );
    _requireOwner(challenge.owner);
    if (body['bound'] != true) {
      throw const RepositoryException('服务端尚未确认手机号绑定，请刷新账户状态。');
    }
    final receipt = PhoneBindingRefreshPending._(
      challenge.owner,
      challenge.phone,
    );
    await _finishIdentityChange(receipt, isCurrent: isCurrent);
  }

  Future<void> refreshBoundPhone(
    PhoneBindingRefreshPending receipt, {
    bool Function()? isCurrent,
  }) => refreshIdentity(receipt, isCurrent: isCurrent);

  Future<void> refreshIdentity(
    PhoneIdentityRefreshPending receipt, {
    bool Function()? isCurrent,
  }) async {
    _requireCurrent(receipt._owner, isCurrent);
    await auth.refreshCurrentUser();
    _requireCurrent(receipt._owner, isCurrent);
    final user = auth.session?.user;
    final confirmed =
        user != null &&
        (switch (receipt.change) {
          PhoneIdentityChange.phoneBinding => user.phone == receipt._phone,
          PhoneIdentityChange.emailBinding =>
            user.email.isNotEmpty && user.emailVerified,
          PhoneIdentityChange.password => user.hasPassword,
        });
    if (!auth.signedIn || !confirmed) {
      throw const RepositoryException('账户状态尚未同步，请稍后重新刷新。');
    }
  }

  Future<void> _finishIdentityChange(
    PhoneIdentityRefreshPending receipt, {
    bool Function()? isCurrent,
  }) async {
    try {
      await refreshIdentity(receipt, isCurrent: isCurrent);
    } catch (_) {
      _requireOwner(receipt._owner);
      throw receipt;
    }
  }

  Future<PhoneSensitiveProof> verifySensitive({
    required PhoneChallenge challenge,
    required String code,
  }) async {
    _requireChallenge(challenge, PhoneChallengePurpose.sensitive, code);
    final body = await auth.authenticatedRequest(
      'POST',
      '/api/v1/auth/phone/verify-sensitive',
      data: {'challengeId': challenge.id, 'code': code.trim()},
    );
    _requireOwner(challenge.owner);
    final value = body['phoneProof'];
    final seconds = body['expiresIn'];
    if (value is! String ||
        value.isEmpty ||
        seconds is! int ||
        seconds < 1 ||
        seconds > 600) {
      throw const RepositoryException('服务端未确认手机号验证，请重新验证。');
    }
    return PhoneSensitiveProof._(
      value,
      _now().add(Duration(seconds: seconds)),
      challenge.owner,
    );
  }

  Future<AuthMailDelivery> requestEmailBinding({
    required String email,
    required PhoneSensitiveProof proof,
    String? currentPassword,
  }) async {
    final value = email.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      throw const RepositoryException('请输入有效的电子邮箱。');
    }
    final ticket = proof.consume(auth, _now());
    return AuthMailDelivery.fromJson(
      await auth.authenticatedRequest(
        'POST',
        '/api/v1/auth/email/bind/request',
        data: {
          'email': value,
          'phoneProof': ticket,
          'currentPassword': ?currentPassword,
        },
      ),
    );
  }

  Future<void> confirmEmailBinding(
    String tokenOrLink, {
    bool Function()? isCurrent,
  }) async {
    var token = tokenOrLink.trim();
    if (token.contains('://')) {
      final uri = Uri.tryParse(token);
      final action = uri == null ? null : Uri.tryParse(uri.fragment);
      final tokens = action?.queryParametersAll['token'];
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          action?.path != '/phone-email' ||
          tokens == null ||
          tokens.length != 1) {
        throw const RepositoryException('请粘贴绑定邮箱邮件中的完整链接或有效凭证。');
      }
      token = tokens.single;
    }
    if (token.isEmpty) {
      throw const RepositoryException('请粘贴绑定邮箱邮件中的完整链接或有效凭证。');
    }
    final owner = auth.sessionOwner;
    _requireCurrent(owner, isCurrent);
    final body = await auth.authenticatedRequest(
      'POST',
      '/api/v1/auth/email/bind/confirm',
      data: {'token': token},
    );
    _requireOwner(owner);
    if (body['verified'] != true) {
      throw const RepositoryException('服务端尚未确认邮箱绑定，请刷新账户状态。');
    }
    await _finishIdentityChange(
      PhoneIdentityRefreshPending._(owner, PhoneIdentityChange.emailBinding),
      isCurrent: isCurrent,
    );
  }

  Future<void> setPassword({
    required String password,
    required PhoneSensitiveProof proof,
    bool Function()? isCurrent,
  }) async {
    final owner = auth.sessionOwner;
    _requireCurrent(owner, isCurrent);
    if (password.length < 10 || password.length > 128) {
      throw const RepositoryException('密码需要 10–128 个字符。');
    }
    final ticket = proof.consume(auth, _now());
    final body = await auth.authenticatedRequest(
      'POST',
      '/api/v1/auth/password/set',
      data: {'password': password, 'phoneProof': ticket},
    );
    _requireOwner(owner);
    if (body['passwordSet'] != true && body['updated'] != true) {
      throw const RepositoryException('服务端尚未确认密码设置，请刷新账户状态。');
    }
    await _finishIdentityChange(
      PhoneIdentityRefreshPending._(owner, PhoneIdentityChange.password),
      isCurrent: isCurrent,
    );
  }

  /// Lets the existing account owner keep its deletion lifecycle and local data
  /// cleanup. The caller must immediately pass this value to deleteAccount.
  String consumeForAccountDeletion(PhoneSensitiveProof proof) =>
      proof.consume(auth, _now());

  void _requireChallenge(
    PhoneChallenge challenge,
    PhoneChallengePurpose purpose,
    String code,
  ) {
    _requireOwner(challenge.owner);
    if (challenge.purpose != purpose || !challenge.expiresAt.isAfter(_now())) {
      throw const RepositoryException('验证码已失效，请重新获取。');
    }
    if (!RegExp(r'^\d{4,8}$').hasMatch(code.trim())) {
      throw const RepositoryException('请输入短信中的数字验证码。');
    }
  }

  void _requireOwner(Object owner) {
    if (owner != auth.sessionOwner) {
      throw const RepositoryException('账号会话已变化，请重新验证手机号。');
    }
  }

  void _requireCurrent(Object owner, bool Function()? isCurrent) {
    _requireOwner(owner);
    if (isCurrent?.call() == false) {
      throw const RepositoryException('已离开本次操作，请在账户页查看最新状态。');
    }
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
