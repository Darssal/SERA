import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/admin_controller.dart';
import '../../application/community_controller.dart';
import '../../data/auth_repository.dart';
import '../../data/workspace_repository.dart';
import '../../domain/admin_models.dart';
import '../../domain/community_models.dart';
import '../core/sera_widgets.dart';
import 'community_screens.dart';

part 'admin_content.dart';
part 'admin_team.dart';
part 'admin_analytics.dart';

const _adminSections = <String, (String, String, IconData)>{
  'overview': ('概览', '了解社区当前情况，继续需要处理的工作', Icons.home_outlined),
  'posts': ('内容管理', '管理社区动态、活动和使用反馈', Icons.article_outlined),
  'publish': ('官方发布', '以官方身份发布社区动态或活动', Icons.campaign_outlined),
  'team': ('管理员与申请', '邀请管理员，审核申请并分配每一项权限', Icons.manage_accounts_outlined),
  'users': ('用户', '查看社区用户，处理需要限制的账号', Icons.people_outline),
  'audit': ('操作记录', '查看后台管理操作及处理原因', Icons.receipt_long_outlined),
  'status': ('运行状态', '查看服务配置、心跳与当前可用情况', Icons.monitor_heart_outlined),
};

const _adminPermissionNames = {
  'publishOfficial': '发布官方动态',
  'publishActivity': '发布活动',
  'moderatePosts': '管理帖子',
  'moderateComments': '管理评论',
};

const _adminDialogTheme = DialogThemeData(
  backgroundColor: Colors.white,
  surfaceTintColor: Colors.transparent,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  ),
);

String _adminDate(DateTime date) {
  final d = date.toLocal();
  return '${d.month}月${d.day}日 ${formatTime(d)}';
}

String _adminPostType(CommunityPost post) => post.isActivity
    ? '活动'
    : post.category == 'feedback'
    ? '使用反馈'
    : post.isOfficial
    ? '官方'
    : '日常';

String _adminFailure(Object failure) =>
    failure is RepositoryException ? failure.message : '操作未完成，请重试。';

class AdminConsoleScreen extends StatefulWidget {
  const AdminConsoleScreen({super.key, required this.section, this.controller});

  final String section;
  final AdminController? controller;

  @override
  AdminConsoleScreenState createState() => AdminConsoleScreenState();
}

class AdminConsoleScreenState extends State<AdminConsoleScreen> {
  final _postSearch = TextEditingController();
  final _commentSearch = TextEditingController();
  final _userSearch = TextEditingController();
  final _auditSearch = TextEditingController();
  final _dialogs = <Route<dynamic>>[];
  AdminController? _admin;
  AuthRepository? _auth;
  Object? _owner;
  GlobalKey _composeKey = GlobalKey();
  bool _composeVisited = false, _dirty = false, _leaving = false;
  String _contentTab = 'all', _userStatus = '';
  String _permissionScope = '';

  AdminController get _controller => _admin!;
  String get _section =>
      _adminSections.containsKey(widget.section) ? widget.section : 'overview';
  bool get _official => _controller.viewer.canManageAdmins;
  bool get _canPublish =>
      _controller.viewer.permissions.publishOfficial ||
      _controller.viewer.permissions.publishActivity;
  bool get _canReadPosts =>
      _controller.viewer.isAdmin || _controller.viewer.isOfficial;
  bool get _canReadComments => _controller.viewer.permissions.moderateComments;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthRepository?>() ?? widget.controller?.auth;
    if (identical(auth, _auth)) return;
    _auth?.removeListener(_accountChanged);
    _admin?.removeListener(_updated);
    if (_admin != null && widget.controller == null) _admin!.dispose();
    _auth = auth;
    if (auth == null) return;
    _owner = auth.sessionOwner;
    _admin = widget.controller ?? AdminController(auth: auth);
    _admin!.addListener(_updated);
    auth.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didUpdateWidget(AdminConsoleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSection());
    }
  }

  void _updated() {
    if (!mounted) return;
    final viewer = _controller.viewer;
    final scope =
        '${viewer.isAdmin}:${viewer.isOfficial}:${viewer.canManageAdmins}:${viewer.permissions.toJson().values.join(',')}';
    if (_permissionScope.isNotEmpty && _permissionScope != scope) {
      _closeDialogs();
    }
    _permissionScope = scope;
    setState(() {});
  }

  void _rebuild(VoidCallback change) {
    if (mounted) setState(change);
  }

  void _accountChanged() {
    final owner = _auth!.sessionOwner;
    if (owner == _owner || !mounted) return;
    _owner = owner;
    _postSearch.clear();
    _commentSearch.clear();
    _userSearch.clear();
    _auditSearch.clear();
    _closeDialogs();
    setState(() {
      _composeKey = GlobalKey();
      _composeVisited = _dirty = _leaving = false;
      _permissionScope = '';
      _contentTab = 'all';
      _userStatus = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted || _auth?.signedIn != true) return;
    final owner = _owner;
    await _controller.loadBootstrap();
    if (_owns(owner)) await _loadSection();
  }

  bool _owns(Object? owner) =>
      mounted && _owner == owner && _auth?.sessionOwner == owner;

  void _closeDialogs() {
    final routes = List<Route<dynamic>>.of(_dialogs);
    _dialogs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    });
  }

  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    final theme = Theme.of(context).copyWith(dialogTheme: _adminDialogTheme);
    final route = DialogRoute<T>(
      context: context,
      builder: (_) => Theme(
        data: theme,
        child: Builder(builder: builder),
      ),
    );
    _dialogs.add(route);
    try {
      return await Navigator.of(context).push(route);
    } finally {
      _dialogs.remove(route);
    }
  }

  Future<void> _loadSection() async {
    if (!mounted || _controller.bootstrap == null) return;
    switch (_section) {
      case 'overview':
        if (_official) {
          await _controller.loadAnalytics(days: _controller.analyticsDays);
        } else if (_canReadPosts) {
          await _controller.loadPosts();
        }
      case 'posts':
        if (_contentTab == 'comments' || !_canReadPosts) {
          if (_canReadComments) {
            if (_contentTab != 'comments') {
              setState(() => _contentTab = 'comments');
            }
            await _controller.loadComments(q: _commentSearch.text);
          }
        } else {
          await _loadPosts();
        }
      case 'publish':
        if (_canPublish && !_composeVisited) {
          setState(() => _composeVisited = true);
        }
      case 'team':
        if (_official) {
          await context.read<CommunityController>().loadManagement();
        }
      case 'users':
        if (_official) {
          await _controller.loadUsers(q: _userSearch.text, status: _userStatus);
        }
      case 'audit':
        if (_official) await _controller.loadAudit(q: _auditSearch.text);
      case 'status':
        if (_official) await _controller.loadStatus();
    }
  }

  Future<void> _loadPosts() => _controller.loadPosts(
    q: _postSearch.text,
    category: _contentTab == 'feedback'
        ? 'feedback'
        : _contentTab == 'daily'
        ? 'daily'
        : '',
    kind: _contentTab == 'activity'
        ? 'activity'
        : _contentTab == 'daily'
        ? 'post'
        : '',
  );

  /// Used by the route's onExit and the console's own navigation controls.
  Future<bool> confirmLeave() async {
    if (_leaving) return false;
    if (context.read<CommunityController>().isBusy('create')) {
      _showMessage('正在发布，请等待结果后离开。');
      return false;
    }
    if (!_dirty) return true;
    final owner = _owner;
    _leaving = true;
    final leave = await _dialog<bool>(
      (context) => AlertDialog(
        title: const Text('放弃尚未发布的内容？'),
        content: const Text('未发布的文字和图片将被放弃。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃并离开'),
          ),
        ],
      ),
    );
    if (!_owns(owner)) return false;
    _leaving = false;
    if (leave == true) {
      setState(() {
        _dirty = false;
        _composeVisited = false;
        _composeKey = GlobalKey();
      });
      return true;
    }
    return false;
  }

  Future<void> _navigate(String section) async {
    if (_section == section) return;
    if (!await confirmLeave() || !mounted) return;
    context.go('/admin/$section');
  }

  Future<void> _returnToApp() async {
    if (await confirmLeave() && mounted) context.go('/community');
  }

  Future<void> _logout() async {
    if (!await confirmLeave() || !mounted) return;
    await _auth!.logout();
    if (mounted) {
      if (_auth!.logoutWarning case final warning?) _showMessage(warning);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _auth?.removeListener(_accountChanged);
    _admin?.removeListener(_updated);
    if (widget.controller == null) _admin?.dispose();
    _closeDialogs();
    for (final field in [
      _postSearch,
      _commentSearch,
      _userSearch,
      _auditSearch,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _navigation({bool drawer = false}) {
    final username = _auth?.session?.user.username ?? '';
    return Material(
      color: Colors.white,
      child: Container(
        width: 254,
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: SeraColors.line)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(28, 28, 20, 36),
                child: Row(
                  children: [
                    Icon(Icons.eco_outlined, color: SeraColors.brand, size: 40),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SERA',
                            style: TextStyle(
                              fontSize: 28,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '管理后台',
                            style: TextStyle(
                              fontSize: 16,
                              color: SeraColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    for (final entry in _adminSections.entries)
                      if (_sectionVisible(entry.key))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: _section == entry.key
                                ? SeraColors.mint
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              key: ValueKey('admin-nav-${entry.key}'),
                              minLeadingWidth: 24,
                              leading: Icon(
                                entry.value.$3,
                                size: 22,
                                color: _section == entry.key
                                    ? SeraColors.brand
                                    : SeraColors.ink,
                              ),
                              title: Text(
                                entry.value.$1,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: _section == entry.key
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: _section == entry.key
                                      ? SeraColors.brand
                                      : SeraColors.ink,
                                ),
                              ),
                              selected: _section == entry.key,
                              onTap: () {
                                if (drawer) Navigator.pop(context);
                                unawaited(_navigate(entry.key));
                              },
                            ),
                          ),
                        ),
                  ],
                ),
              ),
              const Divider(indent: 24, endIndent: 24),
              ListTile(
                leading: const Icon(Icons.open_in_new, size: 21),
                title: const Text('返回应用'),
                onTap: _returnToApp,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 20),
                child: Row(
                  children: [
                    _AdminAvatar(username),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    TextButton(
                      onPressed: _auth?.loading == true ? null : _logout,
                      child: const Text('退出'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _sectionVisible(String section) => switch (section) {
    'overview' => true,
    'posts' => _canReadPosts || _canReadComments,
    'publish' => _canPublish,
    _ => _official,
  };

  Widget _accessMessage(
    String title,
    String detail, {
    bool login = false,
  }) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              login ? Icons.admin_panel_settings_outlined : Icons.lock_outline,
              size: 42,
              color: SeraColors.brand,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              detail,
              style: const TextStyle(color: SeraColors.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go(
                login ? '/login?returnTo=%2Fadmin%2F$_section' : '/community',
              ),
              child: Text(login ? '登录' : '返回社区'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _mainContent() {
    final section = _adminSections[_section]!;
    if (!_sectionVisible(_section)) {
      return _accessMessage('没有此项管理权限', '请联系官方账号分配相应权限。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 24,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: constraints.maxWidth > 700
                      ? constraints.maxWidth - 250
                      : constraints.maxWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.$1,
                        key: ValueKey('admin-title-$_section'),
                        style: const TextStyle(
                          fontSize: 32,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        section.$2,
                        style: const TextStyle(
                          color: SeraColors.muted,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_section != 'publish' && _canPublish)
                  FilledButton.icon(
                    onPressed: () => _navigate('publish'),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('发布官方内容'),
                  ),
              ],
            ),
          ),
        ),
        if (_controller.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
            child: _AdminNotice(
              _controller.error!,
              error: true,
              retry: _controller.refresh,
            ),
          ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              32,
              0,
              32,
              MediaQuery.viewInsetsOf(context).bottom > 0 ? 0 : 28,
            ),
            child: IndexedStack(
              index: _section == 'publish' ? 1 : 0,
              children: [
                _section == 'publish'
                    ? const SizedBox.shrink()
                    : _sectionBody(),
                if (_composeVisited)
                  _AdminPanel(
                    child: CommunityComposeScreen(
                      key: _composeKey,
                      desktopMode: true,
                      onDirtyChanged: (dirty) {
                        if (mounted && _dirty != dirty) {
                          setState(() => _dirty = dirty);
                        }
                      },
                      onPublished: (post) {
                        if (!mounted) return;
                        setState(() => _dirty = false);
                        _controller.invalidateAnalytics();
                        _showMessage('已发布到社区');
                        unawaited(_controller.refresh());
                        context.go('/admin/posts');
                      },
                    ),
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionBody() => switch (_section) {
    'posts' => _posts(),
    'team' => _team(),
    'users' => _users(),
    'audit' => _audit(),
    'status' => _status(),
    _ => _overview(),
  };

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository?>() ?? widget.controller?.auth;
    final admin = _admin;
    Widget body;
    if (auth?.signedIn != true) {
      body = _accessMessage('SERA 管理后台', '使用官方账号或社区管理员账号登录。', login: true);
    } else if (admin == null || admin.loading && admin.bootstrap == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (admin.bootstrap == null) {
      body = Center(
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AdminNotice(
                  admin.error ?? '当前账号没有后台管理权限。',
                  error: true,
                  retry: _bootstrap,
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: _returnToApp,
                  child: const Text('返回社区'),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 900) {
            return Scaffold(
              appBar: AppBar(
                title: const Text('SERA 管理后台'),
                centerTitle: false,
                backgroundColor: Colors.white,
              ),
              drawer: Drawer(width: 254, child: _navigation(drawer: true)),
              body: _mainContent(),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _navigation(),
              Expanded(child: _mainContent()),
            ],
          );
        },
      );
    }
    return Theme(
      data: Theme.of(context).copyWith(
        dialogTheme: _adminDialogTheme,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(80, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(72, 44),
            side: const BorderSide(color: SeraColors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: SeraColors.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: SeraColors.line),
          ),
        ),
        dataTableTheme: const DataTableThemeData(
          headingRowColor: WidgetStatePropertyAll(Color(0xFFF5F7F6)),
          headingTextStyle: TextStyle(
            fontFamily: 'SeraSans',
            fontSize: 14,
            color: SeraColors.muted,
            fontWeight: FontWeight.w500,
          ),
          dataTextStyle: TextStyle(
            fontFamily: 'SeraSans',
            fontSize: 16,
            color: SeraColors.ink,
          ),
        ),
      ),
      child: Scaffold(
        key: const ValueKey('admin-console'),
        backgroundColor: const Color(0xFFF5F8F7),
        body: body,
      ),
    );
  }
}

class _AdminPanel extends StatelessWidget {
  const _AdminPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: SeraColors.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );
}

class _AdminNotice extends StatelessWidget {
  const _AdminNotice(this.message, {this.error = false, this.retry});
  final String message;
  final bool error;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: error ? SeraColors.redBg : SeraColors.mint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: error ? SeraColors.red : SeraColors.brand,
              ),
            ),
          ),
          if (retry != null)
            TextButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _AdminAvatar extends StatelessWidget {
  const _AdminAvatar(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 16,
    backgroundColor: SeraColors.mint,
    foregroundColor: SeraColors.brand,
    child: Text(
      name.trim().isEmpty ? '友' : name.trim().characters.first,
      style: const TextStyle(fontSize: 13),
    ),
  );
}
