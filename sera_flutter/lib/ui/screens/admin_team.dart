part of 'admin_screens.dart';

extension _AdminTeam on AdminConsoleScreenState {
  Widget _team() => Consumer<CommunityController>(
    builder: (context, community, _) {
      final management = community.management;
      final busy = community.isBusy('management');
      return ListView(
        children: [
          if (community.managementLoading && management == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (community.managementError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _AdminNotice(
                community.managementError!,
                error: true,
                retry: community.loadManagement,
              ),
            ),
          _AdminPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        '社区管理员',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('admin-add-member'),
                        onPressed: busy ? null : () => _editPermissions(),
                        icon: const Icon(Icons.person_add_alt, size: 19),
                        label: const Text('添加管理员'),
                      ),
                    ],
                  ),
                ),
                if (management != null && management.admins.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(22, 12, 22, 32),
                    child: Text(
                      '还没有社区管理员。可添加已注册用户并逐项分配权限。',
                      style: TextStyle(color: SeraColors.muted),
                    ),
                  ),
                if (management != null && management.admins.isNotEmpty)
                  _table(
                    minWidth: 980,
                    columns: const [
                      '管理员',
                      '发布官方动态',
                      '发布活动',
                      '管理帖子',
                      '管理评论',
                      '操作',
                    ],
                    rows: [
                      for (final admin in management.admins)
                        DataRow(
                          key: ValueKey('admin-member-row-${admin.userId}'),
                          cells: [
                            DataCell(
                              SizedBox(
                                width: 180,
                                child: Row(
                                  children: [
                                    _AdminAvatar(admin.username),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        admin.username,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            for (final permission
                                in admin.permissions.toJson().values)
                              DataCell(
                                Semantics(
                                  label: permission == true ? '已授权' : '未授权',
                                  child: Icon(
                                    permission == true
                                        ? Icons.check
                                        : Icons.remove,
                                    size: 19,
                                    color: permission == true
                                        ? SeraColors.brand
                                        : SeraColors.control,
                                  ),
                                ),
                              ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    key: ValueKey(
                                      'admin-edit-member-${admin.userId}',
                                    ),
                                    onPressed: busy
                                        ? null
                                        : () => _editPermissions(admin: admin),
                                    child: const Text('设置权限'),
                                  ),
                                  TextButton(
                                    key: ValueKey(
                                      'admin-remove-member-${admin.userId}',
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: SeraColors.red,
                                    ),
                                    onPressed: busy
                                        ? null
                                        : () => _removeAdmin(admin),
                                    child: const Text('移除'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _AdminPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(22),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '管理申请',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: community.managementLoading
                            ? null
                            : community.loadManagement,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('刷新'),
                      ),
                    ],
                  ),
                ),
                if (management != null && management.applications.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(22, 12, 22, 32),
                    child: Text(
                      '暂时没有管理申请。',
                      style: TextStyle(color: SeraColors.muted),
                    ),
                  ),
                if (management != null && management.applications.isNotEmpty)
                  _table(
                    minWidth: 1000,
                    columns: const ['申请人', '申请理由', '申请时间', '状态', '操作'],
                    rows: [
                      for (final application in management.applications)
                        DataRow(
                          key: ValueKey(
                            'admin-application-row-${application.id}',
                          ),
                          cells: [
                            DataCell(
                              SizedBox(
                                width: 150,
                                child: Text(
                                  application.username,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            DataCell(
                              SizedBox(
                                width: 330,
                                child: SelectableText(
                                  application.reason,
                                  maxLines: 3,
                                ),
                              ),
                            ),
                            DataCell(Text(_adminDate(application.createdAt))),
                            DataCell(
                              Text(
                                switch (application.status) {
                                  'pending' => '待审核',
                                  'approved' => '已通过',
                                  'rejected' => '未通过',
                                  _ => '处理中',
                                },
                                style: TextStyle(
                                  color: application.status == 'pending'
                                      ? SeraColors.amber
                                      : SeraColors.muted,
                                ),
                              ),
                            ),
                            DataCell(
                              application.status != 'pending'
                                  ? const Text(
                                      '已处理',
                                      style: TextStyle(color: SeraColors.muted),
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextButton(
                                          key: ValueKey(
                                            'admin-approve-application-${application.id}',
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () => _editPermissions(
                                                  application: application,
                                                ),
                                          child: const Text('审核并授权'),
                                        ),
                                        TextButton(
                                          key: ValueKey(
                                            'admin-reject-application-${application.id}',
                                          ),
                                          style: TextButton.styleFrom(
                                            foregroundColor: SeraColors.red,
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () => _rejectApplication(
                                                  application,
                                                ),
                                          child: const Text('拒绝'),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Future<void> _editPermissions({
    CommunityAdmin? admin,
    CommunityAdminApplication? application,
  }) async {
    final community = context.read<CommunityController>();
    if (community.isBusy('management') || !_official) return;
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminPermissionDialog(
        title: admin != null
            ? '设置管理员权限'
            : application != null
            ? '审核并授权'
            : '添加管理员',
        name: admin?.username ?? application?.username,
        reason: application?.reason,
        initial: admin?.permissions ?? const CommunityPermissions(),
        adding: admin == null && application == null,
        confirmLabel: admin != null
            ? '保存权限'
            : application != null
            ? '批准并授权'
            : '添加管理员',
        onSubmit: (identifier, permissions) async {
          if (!_owns(owner) || !_official) {
            throw const RepositoryException('账号或管理权限已变化，请重新操作。');
          }
          if (admin != null) {
            await community.updateAdmin(admin.userId, permissions);
          } else if (application != null) {
            await community.reviewApplication(
              application.id,
              status: 'approved',
              permissions: permissions,
            );
          } else {
            await community.addAdmin(identifier, permissions);
          }
          if (_owns(owner)) {
            unawaited(_controller.loadBootstrap());
            _showMessage(
              admin != null
                  ? '管理员权限已保存'
                  : application != null
                  ? '申请已通过并分配权限'
                  : '管理员已添加',
            );
          }
        },
      ),
    );
  }

  Future<void> _removeAdmin(CommunityAdmin admin) async {
    final community = context.read<CommunityController>();
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminTeamActionDialog(
        title: '移除管理员？',
        description: '${admin.username}将失去社区管理权限，账号和已发布的内容保留。',
        confirmLabel: '确认移除',
        onSubmit: () async {
          if (!_owns(owner) || !_official) {
            throw const RepositoryException('账号或管理权限已变化，请重新操作。');
          }
          await community.removeAdmin(admin.userId);
          if (_owns(owner)) {
            unawaited(_controller.loadBootstrap());
            _showMessage('管理员已移除');
          }
        },
      ),
    );
  }

  Future<void> _rejectApplication(CommunityAdminApplication application) async {
    final community = context.read<CommunityController>();
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminTeamActionDialog(
        title: '拒绝管理申请？',
        description: '${application.username}本次申请将标记为未通过，之后仍可以重新申请。',
        confirmLabel: '确认拒绝',
        onSubmit: () async {
          if (!_owns(owner) || !_official) {
            throw const RepositoryException('账号或管理权限已变化，请重新操作。');
          }
          await community.reviewApplication(application.id, status: 'rejected');
          if (_owns(owner)) {
            unawaited(_controller.loadBootstrap());
            _showMessage('申请已拒绝');
          }
        },
      ),
    );
  }
}

class _AdminPermissionDialog extends StatefulWidget {
  const _AdminPermissionDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.adding,
    required this.onSubmit,
    this.name,
    this.reason,
  });
  final String title, confirmLabel;
  final String? name, reason;
  final bool adding;
  final CommunityPermissions initial;
  final Future<void> Function(
    String identifier,
    CommunityPermissions permissions,
  )
  onSubmit;
  @override
  State<_AdminPermissionDialog> createState() => _AdminPermissionDialogState();
}

class _AdminPermissionDialogState extends State<_AdminPermissionDialog> {
  final _identifier = TextEditingController();
  final _form = GlobalKey<FormState>();
  late CommunityPermissions _permissions = widget.initial;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _identifier.dispose();
    super.dispose();
  }

  void _set(String key, bool value) => setState(
    () => _permissions = _permissions.copyWith(
      publishOfficial: key == 'publishOfficial' ? value : null,
      publishActivity: key == 'publishActivity' ? value : null,
      moderatePosts: key == 'moderatePosts' ? value : null,
      moderateComments: key == 'moderateComments' ? value : null,
    ),
  );
  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_identifier.text.trim(), _permissions);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => _error = _adminFailure(failure));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      key: const ValueKey('admin-permission-dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 18, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭权限设置',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 21),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 22),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.name != null) ...[
                        Text(
                          widget.name!,
                          style: const TextStyle(
                            color: SeraColors.muted,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (widget.reason != null) ...[
                        SelectableText(widget.reason!),
                        const SizedBox(height: 20),
                      ],
                      if (widget.adding) ...[
                        TextFormField(
                          key: const ValueKey('admin-member-identifier'),
                          controller: _identifier,
                          enabled: !_saving,
                          maxLength: 254,
                          decoration: const InputDecoration(
                            labelText: '完整用户名或邮箱',
                            counterText: '',
                          ),
                          validator: (value) => value?.trim().isNotEmpty == true
                              ? null
                              : '请输入已注册用户的完整用户名或邮箱',
                        ),
                        const SizedBox(height: 16),
                      ],
                      for (final permission in _adminPermissionNames.entries)
                        CheckboxListTile(
                          key: ValueKey('admin-permission-${permission.key}'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _permissions.toJson()[permission.key] == true,
                          onChanged: _saving
                              ? null
                              : (value) => _set(permission.key, value == true),
                          title: Text(
                            permission.value,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _AdminNotice(_error!, error: true),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 16, 26, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey('admin-permissions-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '正在保存' : widget.confirmLabel),
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

class _AdminTeamActionDialog extends StatefulWidget {
  const _AdminTeamActionDialog({
    required this.title,
    required this.description,
    required this.confirmLabel,
    required this.onSubmit,
  });
  final String title, description, confirmLabel;
  final Future<void> Function() onSubmit;
  @override
  State<_AdminTeamActionDialog> createState() => _AdminTeamActionDialogState();
}

class _AdminTeamActionDialogState extends State<_AdminTeamActionDialog> {
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit();
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => _error = _adminFailure(failure));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.description),
            if (_error != null) ...[
              const SizedBox(height: 18),
              _AdminNotice(_error!, error: true),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: SeraColors.red),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存' : widget.confirmLabel),
        ),
      ],
    ),
  );
}
