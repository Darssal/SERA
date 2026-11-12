import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../data/auth_repository.dart';
import '../data/offline_repository.dart';
import '../data/device_workspace_repository.dart';
import '../data/repositories.dart';
import '../platform/platform_services.dart';
import '../platform/network_wakeups.dart';
import '../ui/core/sera_theme.dart';
import '../ui/core/community_login_return.dart';
import 'platform_coordinator.dart';
import 'sera_controller.dart';
import 'device_cloud_sync.dart';

class SeraRoot extends StatefulWidget {
  const SeraRoot({super.key, required this.apiBaseUrl, this.demoDate});
  final String apiBaseUrl;
  final DateTime? demoDate;
  @override
  State<SeraRoot> createState() => _SeraRootState();
}

class _SeraRootState extends State<SeraRoot> with WidgetsBindingObserver {
  late final AuthRepository _auth = AuthRepository(
    apiBaseUrl: widget.apiBaseUrl,
    onPeerAccountChange: () => unawaited(_releasePeerMicrophone()),
  );
  SeraController? _controller;
  PlatformCoordinator? _platform;
  OfflineWorkspaceRepository? _repository;
  late final _device = DeviceWorkspaceRepository(apiBaseUrl: widget.apiBaseUrl);
  DeviceCloudSync? _deviceCloud;
  String? _identity;
  int _epoch = 0;
  Future<void> _switchTail = Future.value();
  bool _starting = true;
  bool _restoringAccount = true;
  String? _startupError;
  String? _initialLocation;
  String? _restorationLocation;
  String? _sessionInitialLocation;
  String? _communityLoginReturn;
  String? _adminSessionLocation;
  Timer? _syncTimer;
  StreamSubscription<void>? _networkSubscription;
  bool _syncRunning = false;
  bool _reconnectPending = false;
  Future<void> _releasePeerMicrophone() async {
    try {
      await platformServices.cancelRecording();
    } catch (_) {}
    try {
      await platformServices.stopAudioStream(cancel: true);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _initialLocation = kIsWeb && Uri.base.fragment.startsWith('/')
        ? Uri.base.fragment
        : null;
    _restorationLocation = _initialLocation;
    WidgetsBinding.instance.addObserver(this);
    _networkSubscription = networkRestored.listen(
      (_) => unawaited(_synchronize(afterReconnect: true)),
    );
    _auth.addListener(_authChanged);
    _initialize();
  }

  Future<void> _initialize() async {
    // Local records are usable while account restoration checks the network.
    _starting = false;
    _authChanged();
    try {
      await _auth.initialize();
    } catch (_) {
      // Account recovery must not block access to records on this device.
    }
    if (!mounted) return;
    _restoringAccount = false;
    _restorationLocation = null;
    _authChanged();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _synchronize(),
    );
  }

  String get _sessionIdentity => _auth.signedIn
      ? '${_auth.session!.user.id}:${_auth.session!.sessionId}'
      : DeviceWorkspaceRepository.scope;
  void _authChanged() {
    if (_starting || _auth.followingPeerAccount) return;
    final identity = _sessionIdentity;
    if (identity == _identity) return;
    _identity = identity;
    final importDevice = !_restoringAccount && _auth.signedIn;
    // Capture before the queued switch and the outgoing router can change.
    final loginReturn = importDevice
        ? _communityLoginReturn
        : _adminSessionLocation;
    final restorationLocation = _restoringAccount && _auth.signedIn
        ? _restorationLocation
        : null;
    _communityLoginReturn = null;
    _switchTail = _switchTail
        .then(
          (_) => _switchAccount(
            identity,
            importDevice: importDevice,
            loginReturn: loginReturn,
            restorationLocation: restorationLocation,
          ),
        )
        .catchError((Object error) {
          if (mounted && identity == _sessionIdentity) {
            setState(() => _startupError = '记录暂时无法打开，请检查本机存储后重试。');
          }
        });
  }

  Future<void> _switchAccount(
    String identity, {
    bool importDevice = false,
    String? loginReturn,
    String? restorationLocation,
  }) async {
    if (!mounted || identity != _sessionIdentity) return;
    // This runs in the queued microtask, before the old router is detached.
    // Do not let a view-focus event traverse controls from the outgoing account.
    final focus = FocusManager.instance;
    focus.primaryFocus?.unfocus();
    focus.rootScope.requestScopeFocus();
    focus.applyFocusChangesIfNeeded();
    final epoch = ++_epoch;
    final previous = _repository;
    final wasDevice = _controller?.accountId == DeviceWorkspaceRepository.scope;
    final changingSession = _controller != null;
    _controller?.dispose();
    _platform?.dispose();
    _deviceCloud?.dispose();
    setState(() {
      _startupError = null;
      _sessionInitialLocation =
          communityLoginReturn(loginReturn) ??
          restorationLocation ??
          _initialLocation ??
          (changingSession ? '/30' : null);
      _initialLocation = null;
      _controller = null;
      _repository = null;
      _platform = null;
      _deviceCloud = null;
    });
    _auth.cancelTranscription();
    try {
      await platformServices.cancelRecording();
      await platformServices.stopAudioStream(cancel: true);
    } catch (_) {}
    final deletedId = _auth.deletedUserId;
    if (deletedId != null) await _device.forgetCloudReceipt(deletedId);
    if (previous != null && _auth.deletedUserId == previous.accountId) {
      try {
        await platformServices.syncCalendarEntries([], deleteMissing: true);
        await platformServices.cancelNotifications();
      } catch (_) {}
      await previous.purge();
    } else {
      await previous?.dispose();
    }
    if (!mounted || epoch != _epoch || identity != _sessionIdentity) return;
    final session = _auth.session;
    final signedIn = _auth.signedIn;
    final scope = signedIn ? session!.user.id : DeviceWorkspaceRepository.scope;
    await platformServices.setAccountScope(scope);
    if (!mounted || epoch != _epoch || identity != _sessionIdentity) return;
    if (!signedIn) {
      final coordinator = PlatformCoordinator(auth: _auth, accountId: scope);
      setState(() {
        _platform = coordinator;
        _controller = SeraController(
          repository: _device,
          today: widget.demoDate,
          accountId: scope,
          seedDemo: false,
          onWorkspaceSaved: coordinator.reconcile,
          onBeforePlanning: coordinator.readBusySnapshot,
        );
      });
      return;
    }
    final boundToken = session!.token;
    final boundCsrf = session.csrfToken;
    final remote = HttpWorkspaceRepository(
      baseUrl: widget.apiBaseUrl,
      tokenProvider: () => boundToken,
      csrfProvider: () => boundCsrf,
      onUnauthorized: () async {
        if (_sessionIdentity == identity) await _auth.invalidateSession();
      },
    );
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: scope,
    );
    final coordinator = PlatformCoordinator(auth: _auth, accountId: scope);
    final controller = SeraController(
      repository: repository,
      today: widget.demoDate,
      accountId: scope,
      seedDemo: false,
      onWorkspaceSaved: coordinator.reconcile,
      onBeforePlanning: coordinator.readBusySnapshot,
    );
    final transfer = DeviceCloudSync(
      device: _device,
      controller: controller,
      auth: _auth,
      isCurrent: () =>
          mounted && epoch == _epoch && identity == _sessionIdentity,
    );
    setState(() {
      _repository = repository;
      _platform = coordinator;
      _controller = controller;
      _deviceCloud = transfer;
    });
    if (wasDevice && importDevice) {
      unawaited(
        controller
            .initialize()
            .then((_) => transfer.synchronize())
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _synchronize({bool afterReconnect = false}) async {
    if (!mounted || _starting || _auth.followingPeerAccount) {
      return;
    }
    if (_syncRunning) {
      _reconnectPending |= afterReconnect;
      return;
    }
    _authChanged();
    final c = _controller, r = _repository;
    if (c == null || r == null || (!afterReconnect && (c.busy || c.loading))) {
      return;
    }
    _syncRunning = true;
    try {
      // Reconnection queues behind an in-flight local save in the controller.
      // Its account-bound repository and disposal checks reject stale work.
      await c.refresh();
    } catch (_) {
      // The existing status and periodic retry remain available on failure.
    } finally {
      _syncRunning = false;
      if (_reconnectPending) {
        _reconnectPending = false;
        unawaited(_synchronize(afterReconnect: true));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_synchronize());
  }

  @override
  void dispose() {
    _epoch++;
    _syncTimer?.cancel();
    unawaited(_networkSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_authChanged);
    _controller?.dispose();
    _platform?.dispose();
    _deviceCloud?.dispose();
    unawaited(_repository?.dispose());
    unawaited(_device.dispose());
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_startupError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: seraTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_startupError!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      setState(() => _startupError = null);
                      _identity = null;
                      _authChanged();
                    },
                    child: const Text('重试打开'),
                  ),
                  if (_auth.signedIn)
                    TextButton(
                      onPressed: () => _auth.logout(),
                      child: const Text('退出账户'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_starting || controller == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: seraTheme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        if (_platform != null) ChangeNotifierProvider.value(value: _platform!),
        if (_deviceCloud != null)
          ChangeNotifierProvider.value(value: _deviceCloud!),
      ],
      child: SeraApp(
        key: ValueKey(_identity),
        initialLocation: _sessionInitialLocation,
        controller: controller,
        auth: _auth,
        onLocationChanged: (uri) {
          _communityLoginReturn = communityLoginReturn(
            uri.queryParameters['returnTo'],
          );
          final destination = communityLoginReturn(uri.path);
          _adminSessionLocation =
              destination != null && destination.startsWith('/admin')
              ? destination
              : (_communityLoginReturn?.startsWith('/admin') == true
                    ? _communityLoginReturn
                    : null);
          // Initial credential restoration may complete after the device view
          // is usable. Keep the user's latest route during that one bootstrap.
          if (_restoringAccount) _restorationLocation = uri.toString();
        },
      ),
    );
  }
}
