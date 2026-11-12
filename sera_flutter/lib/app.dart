import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'application/sera_controller.dart';
import 'application/community_controller.dart';
import 'data/auth_repository.dart';
import 'data/workspace_repository.dart';
import 'platform/platform_services.dart';

import 'ui/core/screen_names.dart';
import 'ui/core/community_login_return.dart';
import 'ui/core/sera_motion.dart';
import 'ui/core/sera_widgets.dart';
import 'ui/screens/account_screens.dart';
import 'ui/screens/admin_screens.dart';
import 'ui/screens/community_screens.dart';
import 'ui/screens/main_screens.dart';
import 'ui/screens/planning_screens.dart';
import 'ui/screens/task_screens.dart';

class SeraApp extends StatefulWidget {
  const SeraApp({
    super.key,
    required this.controller,
    this.initialLocation,
    this.auth,
    this.communityController,
    this.onLocationChanged,
  });
  final SeraController controller;
  final String? initialLocation;
  final AuthRepository? auth;
  final CommunityController? communityController;
  final ValueChanged<Uri>? onLocationChanged;
  @override
  State<SeraApp> createState() => _SeraAppState();
}

class _SeraAppState extends State<SeraApp> {
  late final _community =
      widget.communityController ?? CommunityController(auth: widget.auth);
  StreamSubscription<String>? _notificationSubscription;
  final _startupRouteRefresh = ValueNotifier(false);
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _adminConsoleKey = GlobalKey<AdminConsoleScreenState>();
  late final _feedbackObserver = _SeraPageFeedbackObserver(
    _messengerKey,
    () => _router.state.uri,
  );
  late final _onSyncPage = ValueNotifier<bool>(
    _syncLocation(_router.routeInformationProvider.value.uri.path),
  );
  late final _onAdminPage = ValueNotifier<bool>(
    _adminLocation(_router.routeInformationProvider.value.uri.path),
  );
  bool _syncPageRefreshScheduled = false;

  bool _syncLocation(String path) =>
      path.split('/').last.split('-').first == '40';

  bool _adminLocation(String path) =>
      path == '/admin' || path.startsWith('/admin/');

  void _refreshSyncPage() {
    if (_syncPageRefreshScheduled) return;
    _syncPageRefreshScheduled = true;
    // Router initialization can notify while its sibling banner is building.
    // Update presentation after that frame and read the latest route then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPageRefreshScheduled = false;
      if (!mounted) return;
      _onSyncPage.value = _syncLocation(_router.routerDelegate.state.uri.path);
      _onAdminPage.value = _adminLocation(
        _router.routerDelegate.state.uri.path,
      );
    });
  }

  void _refreshStartupRouting() {
    final c = widget.controller;
    if (widget.auth != null &&
        !_startupRouteRefresh.value &&
        !c.loading &&
        !c.busy &&
        c.error == null) {
      _startupRouteRefresh.value = true;
    }
  }

  late final GoRouter _router = GoRouter(
    observers: [_feedbackObserver],
    // Only successful startup/recovery refreshes routing. Refreshing for every
    // autosaved keystroke can rebuild an imperative planning-page stack.
    refreshListenable: _startupRouteRefresh,
    redirect: (context, state) {
      widget.onLocationChanged?.call(state.uri);
      if (widget.auth == null) return null;
      final protectedAccount = const {
        '/account',
        '/bind-phone',
        '/phone-identity',
        '/phone-email',
      }.contains(state.uri.path);
      if (!widget.auth!.signedIn && protectedAccount) return '/login';
      if (widget.auth!.signedIn &&
          !widget.controller.loading &&
          widget.controller.error == null &&
          widget.controller.data.tasks.isEmpty &&
          widget.controller.data.goals.isEmpty &&
          widget.controller.data.platformSettings['onboardingComplete'] !=
              true &&
          const ['/', '/04'].contains(state.uri.path)) {
        return '/02';
      }
      if (widget.auth!.signedIn &&
          const [
            '/login',
            '/register',
            '/phone-login',
          ].contains(state.uri.path)) {
        return communityLoginReturn(state.uri.queryParameters['returnTo']) ??
            '/30';
      }
      return null;
    },
    initialLocation: widget.initialLocation,
    routes: [
      for (final page in [
        'login',
        'register',
        'account',
        'verify-email',
        'forgot-password',
        'reset-password',
        'phone-login',
        'bind-phone',
        'phone-identity',
        'phone-email',
      ])
        GoRoute(
          path: '/$page',
          pageBuilder: (context, state) => SeraMotion.page<void>(
            context: context,
            state: state,
            child: buildAccountScreen(
              page,
              token: state.uri.queryParameters['token'],
            ),
          ),
        ),
      GoRoute(path: '/', redirect: (_, _) => '/04'),
      GoRoute(path: '/admin', redirect: (_, _) => '/admin/overview'),
      GoRoute(
        path: '/admin/:section',
        redirect: (_, state) => communityLoginReturn(state.uri.path) == null
            ? '/admin/overview'
            : null,
        onExit: (_, _) async =>
            await _adminConsoleKey.currentState?.confirmLeave() ?? true,
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: const ValueKey('admin-console-route'),
          child: AdminConsoleScreen(
            key: _adminConsoleKey,
            section: state.pathParameters['section']!,
          ),
        ),
      ),
      GoRoute(
        path: '/community',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: const CommunityFeedScreen(),
        ),
      ),
      GoRoute(
        path: '/community/compose',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: const CommunityComposeScreen(),
        ),
      ),
      GoRoute(
        path: '/community/manage',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: const CommunityManagementScreen(),
        ),
      ),
      GoRoute(
        path: '/community/post/:postId',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: CommunityDetailScreen(postId: state.pathParameters['postId']!),
        ),
      ),
      GoRoute(
        path: '/gallery',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: const ScreenGallery(),
        ),
      ),
      GoRoute(
        path: '/:screen',
        redirect: (_, state) {
          final screen = state.pathParameters['screen']!.split('-').first;
          return screen.padLeft(2, '0') == '10'
              ? state.uri.replace(path: '/08').toString()
              : null;
        },
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: _buildScreen(context, state),
        ),
      ),
    ],
    errorPageBuilder: (context, state) => SeraMotion.page<void>(
      context: context,
      state: state,
      child: SeraScaffold(
        title: '页面未找到',
        body: SeraEmpty(
          '暂时无法打开这个页面',
          '返回今日，继续浏览。',
          action: '返回今日',
          onAction: () => context.go('/04'),
        ),
      ),
    ),
  );

  Widget _buildScreen(BuildContext context, GoRouterState state) {
    final id = state.pathParameters['screen']!.split('-').first.padLeft(2, '0');
    final q = state.uri.queryParameters;
    if (!screenNames.containsKey(id)) {
      return SeraScaffold(
        title: '页面未找到',
        body: SeraEmpty(
          '这条路径暂时没有内容',
          '请返回今日，继续安排你的下一步。',
          action: '返回今日',
          onAction: () => context.go('/04'),
        ),
      );
    }
    if (const {
      '09',
      '15',
      '16',
      '17',
      '18',
      '19',
      '24',
      '25',
      '26',
      '27',
      '28',
      '29',
      '43',
      '45',
      '46',
      '47',
    }.contains(id)) {
      return buildTaskScreen(
        id,
        taskId: q['taskId'],
        eventId: q['eventId'],
        draftId: q['draftId'],
      );
    }
    if (const {
      '04',
      '12',
      '13',
      '14',
      '20',
      '21',
      '30',
      '31',
      '32',
      '33',
      '35',
      '36',
    }.contains(id)) {
      return buildMainScreen(id, goalId: q['goalId']);
    }
    return buildPlanningScreen(id, taskId: q['taskId'], draftId: q['draftId']);
  }

  @override
  void initState() {
    super.initState();
    _router.routerDelegate.addListener(_refreshSyncPage);
    GoRouter.optionURLReflectsImperativeAPIs = true;
    widget.controller.addListener(_refreshStartupRouting);
    {
      widget.controller
          .initialize()
          .then((_) async {
            if (!mounted) return;
            _refreshStartupRouting();
            _notificationSubscription = platformServices.notificationRoutes
                .listen(_openNotification);
            final route = await platformServices
                .consumeInitialNotificationRoute();
            if (route != null) _openNotification(route);
          })
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    if (widget.communityController == null) _community.dispose();
    widget.controller.removeListener(_refreshStartupRouting);
    _notificationSubscription?.cancel();
    _router.routerDelegate.removeListener(_refreshSyncPage);
    _router.dispose();
    _onSyncPage.dispose();
    _onAdminPage.dispose();
    _startupRouteRefresh.dispose();
    super.dispose();
  }

  void _openNotification(String route) {
    if (!mounted) return;
    final uri = Uri.tryParse(route);
    if (uri == null || !route.startsWith('/') || uri.hasAuthority) return;
    final taskId = uri.queryParameters['taskId'];
    if (taskId != null && widget.controller.task(taskId) == null) {
      _router.go('/27');
      return;
    }
    _router.go(route);
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: widget.controller),
      ChangeNotifierProvider.value(value: _community),
    ],
    child: MaterialApp.router(
      scaffoldMessengerKey: _messengerKey,
      title: 'SERA · 序日',
      debugShowCheckedModeBanner: false,
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: _router,
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: _onAdminPage,
        builder: (context, isAdminPage, _) => isAdminPage
            ? SeraMotionScope(child: child ?? const SizedBox.shrink())
            : ColoredBox(
                color: const Color(0xFFE9EEEB),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth.clamp(0.0, 430.0);
                    return Center(
                      child: SizedBox(
                        width: width,
                        height: constraints.maxHeight,
                        child: MediaQuery(
                          data: MediaQuery.of(
                            context,
                          ).copyWith(size: Size(width, constraints.maxHeight)),
                          child: SeraMotionScope(
                            child: ClipRect(
                              child: Consumer<SeraController>(
                                builder: (context, c, _) {
                                  if (c.loading) {
                                    return const Scaffold(
                                      body: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }
                                  if (c.error != null && c.data.revision == 0) {
                                    return SeraScaffold(
                                      title: '连接工作空间',
                                      showBack: false,
                                      body: SeraEmpty(
                                        '暂时无法读取数据',
                                        c.error!,
                                        icon: 'wifi-off',
                                        action: '重试连接',
                                        onAction: () =>
                                            runAction(context, c.refresh),
                                      ),
                                    );
                                  }
                                  final repository = c.repository;
                                  final sync =
                                      repository
                                          is SynchronizingWorkspaceRepository
                                      ? repository
                                            as SynchronizingWorkspaceRepository
                                      : null;
                                  return Column(
                                    children: [
                                      ValueListenableBuilder<bool>(
                                        valueListenable: _onSyncPage,
                                        builder: (context, onSyncPage, _) =>
                                            SeraBannerTransition(
                                              visible:
                                                  !onSyncPage &&
                                                  repository
                                                      is SynchronizingWorkspaceRepository &&
                                                  (sync!.pendingCount > 0 ||
                                                      sync.isOffline ||
                                                      sync.syncConflict !=
                                                          null),
                                              child: Material(
                                                color: const Color(0xFFFCF3DF),
                                                child: InkWell(
                                                  onTap: () {
                                                    if (_router
                                                            .routerDelegate
                                                            .state
                                                            .uri
                                                            .path ==
                                                        '/40') {
                                                      return;
                                                    }
                                                    FocusManager
                                                        .instance
                                                        .primaryFocus
                                                        ?.unfocus();
                                                    _router.push('/40');
                                                  },
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 16,
                                                          vertical: 8,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .cloud_upload_outlined,
                                                          size: 16,
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            sync?.syncConflict !=
                                                                    null
                                                                ? '有修改需要比较，点此处理'
                                                                : c.mode,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 12,
                                                                ),
                                                          ),
                                                        ),
                                                        const Icon(
                                                          Icons.chevron_right,
                                                          size: 16,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                      ),
                                      Expanded(
                                        child: Semantics(
                                          container: true,
                                          child: ColoredBox(
                                            color: SeraColors.bg,
                                            child:
                                                child ??
                                                const SizedBox.shrink(),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    ),
  );
}

/// Feedback belongs to the page where an operation completed. Carrying it into
/// the next form can cover that form's bottom action during fast repeated use.
class _SeraPageFeedbackObserver extends NavigatorObserver {
  _SeraPageFeedbackObserver(this.messenger, this.currentLocation);
  final GlobalKey<ScaffoldMessengerState> messenger;
  final Uri Function() currentLocation;

  void _newPage(Route<dynamic>? route) {
    if (route?.settings is! Page) return;
    final uri = currentLocation();
    final screen = uri.pathSegments.firstOrNull?.split('-').first;
    // A freshly created fallback list may receive new success/undo feedback
    // during this transition. Keep that result; dismiss stale messages when
    // starting the next form, detail action or multi-step operation instead.
    if (const {
      '04',
      '12',
      '13',
      '14',
      '17',
      '20',
      '21',
      '30',
      '34',
      '35',
    }.contains(screen)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (currentLocation() != uri) return;
      final state = messenger.currentState;
      state?.clearSnackBars();
      state?.removeCurrentSnackBar();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _newPage(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _newPage(newRoute);
}

class ScreenGallery extends StatefulWidget {
  const ScreenGallery({super.key});
  @override
  State<ScreenGallery> createState() => _GalleryState();
}

class _GalleryState extends State<ScreenGallery> {
  String _q = '';
  @override
  Widget build(BuildContext context) => SeraScaffold(
    title: '界面与状态预览',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SeraIntro(
          'SERA 界面索引',
          subtitle: '55 个设计页面与状态。需要数据的界面会读取当前任务，缺少数据时显示操作入口。',
        ),
        TextField(
          onChanged: (s) => setState(() => _q = s),
          decoration: const InputDecoration(
            hintText: '按编号或名称查找',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 16),
        ...screenNames.entries
            .where((e) => '${e.key} ${e.value}'.contains(_q))
            .map(
              (e) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SeraTag(e.key),
                title: Text(e.value, style: const TextStyle(fontSize: 13)),
                trailing: const SeraIcon('chevron', size: 16),
                onTap: () => openScreen(context, e.key),
              ),
            ),
      ],
    ),
  );
}
