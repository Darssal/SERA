part of 'admin_screens.dart';

extension _AdminContent on AdminConsoleScreenState {
  Widget _overview() {
    if (_official) return _analyticsOverview();
    final counts = _controller.counts;
    final stats = <(String, int?, String)>[
      ('社区内容', counts.posts, 'posts'),
      ('使用反馈', counts.feedback, 'posts'),
      if (_canReadComments) ('评论', counts.comments, 'posts'),
      if (_official) ('待审核申请', counts.pendingApplications, 'team'),
    ];
    return ListView(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 860
                ? 4
                : constraints.maxWidth >= 500
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final stat in stats)
                  SizedBox(
                    width: width,
                    child: _AdminPanel(
                      child: InkWell(
                        onTap: () {
                          if (stat.$1 == '使用反馈') {
                            _rebuild(() => _contentTab = 'feedback');
                          }
                          if (stat.$1 == '评论') {
                            _rebuild(() => _contentTab = 'comments');
                          }
                          unawaited(_navigate(stat.$3));
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                stat.$1,
                                style: const TextStyle(color: SeraColors.muted),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                stat.$2?.toString() ?? '—',
                                key: ValueKey('admin-count-${stat.$1}'),
                                style: const TextStyle(
                                  fontSize: 34,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _AdminPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 16, 16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '最近发布',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _navigate('posts'),
                      child: const Text('查看全部'),
                    ),
                  ],
                ),
              ),
              if (_controller.posts.loading)
                const LinearProgressIndicator(minHeight: 2),
              if (_controller.posts.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _AdminNotice(
                    _controller.posts.error!,
                    error: true,
                    retry: () => _controller.loadPosts(),
                  ),
                ),
              if (_controller.posts.items.isEmpty && !_controller.posts.loading)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Text(
                    '还没有社区内容。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SeraColors.muted),
                  ),
                )
              else
                _postTable(_controller.posts.items.take(5).toList()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _searchBar(
    TextEditingController field,
    String hint,
    VoidCallback search,
    VoidCallback refresh,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: constraints.maxWidth > 650
                ? 390
                : (constraints.maxWidth - 94).clamp(100, 390).toDouble(),
            child: TextField(
              key: ValueKey(
                'admin-search-${_section == 'posts' ? _contentTab : _section}',
              ),
              controller: field,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: hint,
                counterText: '',
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
              onSubmitted: (_) => search(),
            ),
          ),
          FilledButton(onPressed: search, child: const Text('查询')),
          OutlinedButton.icon(
            onPressed: refresh,
            icon: const Icon(Icons.refresh, size: 19),
            label: const Text('刷新'),
          ),
        ],
      ),
    ),
  );

  Widget _posts() {
    final comments = _contentTab == 'comments';
    final tabs = <String, String>{
      if (_canReadPosts) ...{
        'all': '全部',
        'daily': '日常',
        'activity': '活动',
        'feedback': '使用反馈',
      },
      if (_canReadComments) 'comments': '评论',
    };
    final state = comments ? _controller.comments : _controller.posts;
    return _AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: 16),
                for (final tab in tabs.entries)
                  InkWell(
                    key: ValueKey('admin-content-tab-${tab.key}'),
                    onTap: () {
                      _rebuild(() => _contentTab = tab.key);
                      unawaited(_loadSection());
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 20,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: _contentTab == tab.key
                                ? SeraColors.brand
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        tab.value,
                        style: TextStyle(
                          fontSize: 16,
                          color: _contentTab == tab.key
                              ? SeraColors.brand
                              : SeraColors.ink,
                          fontWeight: _contentTab == tab.key
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          _searchBar(
            comments ? _commentSearch : _postSearch,
            comments ? '搜索评论或作者' : '搜索标题、内容或作者',
            () => unawaited(_loadSection()),
            () => unawaited(_loadSection()),
          ),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
              child: _AdminNotice(
                state.error!,
                error: true,
                retry: _loadSection,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey('admin-content-scroll-$_contentTab'),
              child: state.items.isEmpty && !state.loading
                  ? const Padding(
                      padding: EdgeInsets.all(48),
                      child: Text(
                        '没有符合条件的内容。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: SeraColors.muted),
                      ),
                    )
                  : comments
                  ? _commentTable()
                  : _postTable(_controller.posts.items),
            ),
          ),
          _pageFooter(
            total: state.total,
            loaded: state.items.length,
            more: state.nextCursor != null,
            loading: state.loadingMore,
            next: comments
                ? _controller.loadMoreComments
                : _controller.loadMorePosts,
          ),
        ],
      ),
    );
  }

  Widget _postTable(List<CommunityPost> posts) => _table(
    minWidth: 1060,
    columns: const ['动态', '作者', '类型', '发布时间', '互动', '操作'],
    rows: [
      for (final post in posts)
        DataRow(
          key: ValueKey('admin-post-row-${post.id}'),
          cells: [
            DataCell(
              SizedBox(
                width: 335,
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: post.media.isEmpty
                            ? const ColoredBox(
                                color: Color(0xFFF0F2F1),
                                child: Icon(
                                  Icons.notes_outlined,
                                  color: SeraColors.control,
                                  size: 28,
                                ),
                              )
                            : Image.network(
                                _controller.resolveMediaUrl(
                                  post.media.first.url,
                                ),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const ColoredBox(
                                  color: SeraColors.mint,
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: SeraColors.control,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post.title.trim().isEmpty
                                ? post.content
                                : post.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            post.content.replaceAll(RegExp(r'\s+'), ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: SeraColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            DataCell(
              SizedBox(
                width: 130,
                child: Row(
                  children: [
                    _AdminAvatar(post.authorName),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        post.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            DataCell(Text(_adminPostType(post))),
            DataCell(Text(_adminDate(post.createdAt))),
            DataCell(
              Text(
                '${post.likeCount} 赞 · ${post.commentCount} 评${post.isActivity ? ' · ${post.participantCount} 人' : ''}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            DataCell(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: ValueKey('admin-view-post-${post.id}'),
                    onPressed: () => _viewPost(post.id),
                    child: const Text('查看'),
                  ),
                  if (_controller.viewer.permissions.moderatePosts)
                    TextButton(
                      key: ValueKey('admin-delete-post-${post.id}'),
                      style: TextButton.styleFrom(
                        foregroundColor: SeraColors.red,
                      ),
                      onPressed: _controller.saving
                          ? null
                          : () => _deletePost(post),
                      child: const Text('移除'),
                    ),
                ],
              ),
            ),
          ],
        ),
    ],
  );

  Widget _commentTable() => _table(
    minWidth: 1030,
    columns: const ['评论', '作者', '所属动态', '发布时间', '操作'],
    rows: [
      for (final item in _controller.comments.items)
        DataRow(
          key: ValueKey('admin-comment-row-${item.id}'),
          cells: [
            DataCell(
              SizedBox(
                width: 330,
                child: Text(
                  item.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            DataCell(
              SizedBox(
                width: 130,
                child: Text(
                  item.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            DataCell(
              SizedBox(
                width: 200,
                child: Text(
                  item.postTitle.isEmpty ? '无标题动态' : item.postTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            DataCell(Text(_adminDate(item.createdAt))),
            DataCell(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => _viewPost(item.postId),
                    child: const Text('查看'),
                  ),
                  if (item.canDelete)
                    TextButton(
                      key: ValueKey('admin-delete-comment-${item.id}'),
                      style: TextButton.styleFrom(
                        foregroundColor: SeraColors.red,
                      ),
                      onPressed: _controller.saving
                          ? null
                          : () => _deleteComment(item),
                      child: const Text('移除'),
                    ),
                ],
              ),
            ),
          ],
        ),
    ],
  );

  Widget _table({
    required double minWidth,
    required List<String> columns,
    required List<DataRow> rows,
  }) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: constraints.maxWidth > minWidth
              ? constraints.maxWidth
              : minWidth,
        ),
        child: DataTable(
          columnSpacing: 22,
          horizontalMargin: 22,
          headingRowHeight: 50,
          dataRowMinHeight: 84,
          dataRowMaxHeight: 94,
          dividerThickness: 1,
          columns: columns
              .map((label) => DataColumn(label: Text(label)))
              .toList(),
          rows: rows,
        ),
      ),
    ),
  );

  Widget _pageFooter({
    required int total,
    required int loaded,
    required bool more,
    required bool loading,
    required VoidCallback next,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: SeraColors.line)),
    ),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '共 $total 条 · 已显示 $loaded 条',
          style: const TextStyle(fontSize: 13, color: SeraColors.muted),
        ),
        OutlinedButton(
          onPressed: more && !loading ? next : null,
          child: Text(
            loading
                ? '正在加载'
                : more
                ? '加载更多'
                : '已显示全部',
          ),
        ),
      ],
    ),
  );

  Future<void> _deletePost(CommunityPost post) async {
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminReasonDialog(
        title: '移除这条内容？',
        description:
            '“${post.title.isEmpty ? '这条动态' : post.title}”及其评论、点赞和报名将被删除。此操作无法撤销。',
        confirmLabel: '确认移除',
        onSubmit: (reason) async {
          if (!_owns(owner)) throw const RepositoryException('账号已变化，请重新操作。');
          await _controller.deletePost(post.id, reason: reason);
          if (_owns(owner)) _showMessage('内容已移除');
        },
      ),
    );
  }

  Future<void> _deleteComment(AdminComment item) async {
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminReasonDialog(
        title: '移除这条评论？',
        description: item.content,
        confirmLabel: '确认移除',
        onSubmit: (reason) async {
          if (!_owns(owner)) throw const RepositoryException('账号已变化，请重新操作。');
          await _controller.deleteComment(item.id, reason: reason);
          if (_owns(owner)) _showMessage('评论已移除');
        },
      ),
    );
  }

  Future<void> _viewPost(String id) async {
    unawaited(_controller.loadDetail(id));
    await _dialog<void>(
      (context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final detail = _controller.detail(id);
          final loading = _controller.isDetailLoading(id);
          final failure = _controller.detailError(id);
          return Dialog(
            key: const ValueKey('admin-detail-dialog'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 800),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '内容详情',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          tooltip: '关闭详情',
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (loading)
                            const LinearProgressIndicator(minHeight: 2),
                          if (failure != null)
                            _AdminNotice(
                              failure,
                              error: true,
                              retry: () => _controller.loadDetail(id),
                            ),
                          if (detail != null) ...[
                            Row(
                              children: [
                                _AdminAvatar(detail.post.authorName),
                                const SizedBox(width: 10),
                                Expanded(child: Text(detail.post.authorName)),
                                Text(
                                  _adminPostType(detail.post),
                                  style: const TextStyle(
                                    color: SeraColors.muted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (detail.post.title.isNotEmpty) ...[
                              SelectableText(
                                detail.post.title,
                                style: const TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            SelectableText(detail.post.content),
                            const SizedBox(height: 12),
                            Text(
                              _adminDate(detail.post.createdAt),
                              style: const TextStyle(
                                fontSize: 12,
                                color: SeraColors.muted,
                              ),
                            ),
                            if (detail.post.isActivity) ...[
                              const SizedBox(height: 16),
                              Text(
                                '活动时间：${detail.post.startsAt == null ? '未设置' : _adminDate(detail.post.startsAt!)}',
                              ),
                              if (detail.post.place.isNotEmpty)
                                Text('活动地点：${detail.post.place}'),
                            ],
                            for (final media in detail.post.media) ...[
                              const SizedBox(height: 16),
                              Image.network(
                                _controller.resolveMediaUrl(media.url),
                                width: double.infinity,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    const Text('图片未能加载，请刷新后重试。'),
                              ),
                            ],
                            const SizedBox(height: 24),
                            Text(
                              '${detail.post.likeCount} 个赞 · ${detail.post.commentCount} 条评论${detail.post.isActivity ? ' · ${detail.post.participantCount} 人报名' : ''}',
                              style: const TextStyle(color: SeraColors.muted),
                            ),
                            if (_canReadComments) ...[
                              const Divider(height: 32),
                              const Text(
                                '评论',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (detail.comments.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 18),
                                  child: Text(
                                    '暂无评论',
                                    style: TextStyle(color: SeraColors.muted),
                                  ),
                                ),
                              for (final comment in detail.comments)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        comment.authorName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SelectableText(comment.content),
                                      const SizedBox(height: 6),
                                      Text(
                                        _adminDate(comment.createdAt),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: SeraColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (detail.commentsNextCursor != null)
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _rebuild(() {
                                      _contentTab = 'comments';
                                      _commentSearch.clear();
                                    });
                                    context.go('/admin/posts');
                                    unawaited(
                                      _controller.loadComments(postId: id),
                                    );
                                  },
                                  child: const Text('在评论管理中查看全部'),
                                ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _users() {
    final state = _controller.users;
    return _AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchBar(
            _userSearch,
            '搜索用户名、完整邮箱或手机号',
            () => unawaited(_loadSection()),
            () => unawaited(_loadSection()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final entry in {
                  '': '全部',
                  'active': '正常',
                  'disabled': '已停用',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: _userStatus == entry.key,
                    onSelected: (_) {
                      _rebuild(() => _userStatus = entry.key);
                      unawaited(_loadSection());
                    },
                  ),
              ],
            ),
          ),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: _AdminNotice(
                state.error!,
                error: true,
                retry: _loadSection,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: state.items.isEmpty && !state.loading
                  ? const Padding(
                      padding: EdgeInsets.all(40),
                      child: Text('没有符合条件的用户。', textAlign: TextAlign.center),
                    )
                  : _table(
                      minWidth: 1060,
                      columns: const [
                        '用户',
                        '联系方式',
                        '邮箱验证',
                        '社区内容',
                        '注册时间',
                        '状态',
                        '操作',
                      ],
                      rows: [
                        for (final user in state.items)
                          DataRow(
                            key: ValueKey('admin-user-row-${user.id}'),
                            cells: [
                              DataCell(
                                SizedBox(
                                  width: 155,
                                  child: Row(
                                    children: [
                                      _AdminAvatar(user.username),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          user.username,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              DataCell(
                                Text(
                                  [user.emailMasked, user.phoneMasked]
                                          .where((value) => value.isNotEmpty)
                                          .join('\n')
                                          .isEmpty
                                      ? '未提供'
                                      : [user.emailMasked, user.phoneMasked]
                                            .where((value) => value.isNotEmpty)
                                            .join('\n'),
                                ),
                              ),
                              DataCell(
                                Text(user.emailVerified ? '已验证' : '未验证'),
                              ),
                              DataCell(
                                Text(
                                  '${user.postCount} 动态 · ${user.commentCount} 评论',
                                ),
                              ),
                              DataCell(Text(_adminDate(user.createdAt))),
                              DataCell(
                                Text(
                                  user.disabled ? '已停用' : '正常',
                                  style: TextStyle(
                                    color: user.disabled
                                        ? SeraColors.red
                                        : SeraColors.brand,
                                  ),
                                ),
                              ),
                              DataCell(
                                user.id == _auth?.session?.user.id
                                    ? const Text(
                                        '当前账号',
                                        style: TextStyle(
                                          color: SeraColors.muted,
                                        ),
                                      )
                                    : TextButton(
                                        key: ValueKey(
                                          'admin-toggle-user-${user.id}',
                                        ),
                                        onPressed: _controller.saving
                                            ? null
                                            : () => _toggleUser(user),
                                        child: Text(
                                          user.disabled ? '恢复账号' : '停用账号',
                                          style: TextStyle(
                                            color: user.disabled
                                                ? SeraColors.brand
                                                : SeraColors.red,
                                          ),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
          ),
          _pageFooter(
            total: state.total,
            loaded: state.items.length,
            more: state.nextCursor != null,
            loading: state.loadingMore,
            next: _controller.loadMoreUsers,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleUser(AdminUser user) async {
    final owner = _owner;
    await _dialog<bool>(
      (context) => _AdminReasonDialog(
        title: user.disabled ? '恢复账号？' : '停用账号？',
        description: user.disabled
            ? '${user.username}将可以重新登录，之前的会话不会恢复，需要重新登录。'
            : '${user.username}将被退出当前会话并无法再登录，已有内容保留。恢复账号后仍需要重新登录。',
        confirmLabel: user.disabled ? '确认恢复' : '确认停用',
        destructive: !user.disabled,
        onSubmit: (reason) async {
          if (!_owns(owner)) throw const RepositoryException('账号已变化，请重新操作。');
          await _controller.setUserDisabled(
            user.id,
            disabled: !user.disabled,
            reason: reason,
          );
          if (_owns(owner)) _showMessage(user.disabled ? '账号已恢复' : '账号已停用');
        },
      ),
    );
  }

  Widget _audit() {
    final state = _controller.audit;
    return _AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchBar(
            _auditSearch,
            '搜索操作者或对象',
            () => unawaited(_loadSection()),
            () => unawaited(_loadSection()),
          ),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: _AdminNotice(
                state.error!,
                error: true,
                retry: _loadSection,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: state.items.isEmpty && !state.loading
                  ? const Padding(
                      padding: EdgeInsets.all(40),
                      child: Text('暂时没有后台操作记录。', textAlign: TextAlign.center),
                    )
                  : _table(
                      minWidth: 1010,
                      columns: const ['时间', '操作者', '操作', '对象', '处理原因'],
                      rows: [
                        for (final entry in state.items)
                          DataRow(
                            key: ValueKey('admin-audit-row-${entry.id}'),
                            cells: [
                              DataCell(Text(_adminDate(entry.createdAt))),
                              DataCell(Text(entry.actorName)),
                              DataCell(Text(_auditAction(entry.action))),
                              DataCell(
                                SizedBox(
                                  width: 230,
                                  child: Text(
                                    entry.targetLabel.isEmpty
                                        ? _auditTarget(entry.targetType)
                                        : entry.targetLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(
                                SizedBox(
                                  width: 320,
                                  child: Text(
                                    entry.reason.isEmpty ? '—' : entry.reason,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
          ),
          _pageFooter(
            total: state.total,
            loaded: state.items.length,
            more: state.nextCursor != null,
            loading: state.loadingMore,
            next: _controller.loadMoreAudit,
          ),
        ],
      ),
    );
  }

  String _auditAction(String action) =>
      const {
        'delete_post': '移除内容',
        'delete_comment': '移除评论',
        'disable_user': '停用账号',
        'enable_user': '恢复账号',
        'grant_admin': '添加管理员',
        'update_admin': '修改管理员权限',
        'remove_admin': '移除管理员',
        'approve_application': '批准管理申请',
        'reject_application': '拒绝管理申请',
        'publish_official': '发布官方动态',
        'publish_activity': '发布活动',
        'post_delete': '移除内容',
        'comment_delete': '移除评论',
        'user_disable': '停用账号',
        'user_enable': '恢复账号',
        'admin_add': '添加管理员',
        'admin_update': '修改管理员权限',
        'admin_remove': '移除管理员',
        'application_approve': '批准管理申请',
        'application_reject': '拒绝管理申请',
        'official_publish': '发布官方内容',
        'community.post.delete': '移除内容',
        'community.comment.delete': '移除评论',
        'user.disable': '停用账号',
        'user.enable': '恢复账号',
      }[action] ??
      action.replaceAll('_', ' ');

  String _auditTarget(String target) =>
      const {
        'post': '社区内容',
        'comment': '评论',
        'user': '用户',
        'admin': '管理员',
        'application': '管理申请',
      }[target] ??
      '管理对象';

  Widget _status() {
    final status = _controller.status;
    return _AdminPanel(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '服务状态',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _controller.statusLoading
                    ? null
                    : _controller.loadStatus,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '“已配置”表示配置已就绪；未进行实时检查的服务不会显示为运行正常。',
            style: TextStyle(color: SeraColors.muted, fontSize: 13),
          ),
          if (_controller.statusLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_controller.statusError != null)
            _AdminNotice(
              _controller.statusError!,
              error: true,
              retry: _controller.loadStatus,
            ),
          if (status != null)
            for (final item in status.components)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: SeraColors.line)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 7, right: 14),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: item.healthy == true
                            ? SeraColors.brand
                            : item.status == 'unavailable'
                            ? SeraColors.red
                            : SeraColors.amber,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            item.detail,
                            style: const TextStyle(color: SeraColors.muted),
                          ),
                          if (item.lastHeartbeatAt != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                '最近心跳：${_adminDate(item.lastHeartbeatAt!)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: SeraColors.muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      switch (item.status) {
                        'healthy' => '运行正常',
                        'unavailable' => '暂不可用',
                        'not_configured' => '未配置',
                        'configured' => '已配置',
                        _ => '未确认',
                      },
                      style: TextStyle(
                        color: item.healthy == true
                            ? SeraColors.brand
                            : item.status == 'unavailable'
                            ? SeraColors.red
                            : SeraColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _AdminReasonDialog extends StatefulWidget {
  const _AdminReasonDialog({
    required this.title,
    required this.description,
    required this.confirmLabel,
    required this.onSubmit,
    this.destructive = true,
  });
  final String title, description, confirmLabel;
  final Future<void> Function(String reason) onSubmit;
  final bool destructive;
  @override
  State<_AdminReasonDialog> createState() => _AdminReasonDialogState();
}

class _AdminReasonDialogState extends State<_AdminReasonDialog> {
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_reason.text.trim());
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
      key: const ValueKey('admin-action-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.description),
                const SizedBox(height: 22),
                TextFormField(
                  key: const ValueKey('admin-action-reason'),
                  controller: _reason,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: '处理原因',
                    hintText: '说明本次操作的原因',
                    alignLabelWithHint: true,
                  ),
                  validator: (value) =>
                      value?.trim().isNotEmpty == true ? null : '请填写处理原因',
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _AdminNotice(_error!, error: true),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('admin-action-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('admin-action-confirm'),
          style: widget.destructive
              ? FilledButton.styleFrom(backgroundColor: SeraColors.red)
              : null,
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存' : widget.confirmLabel),
        ),
      ],
    ),
  );
}
