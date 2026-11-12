part of 'admin_screens.dart';

String _analyticsDate(String date) => date.replaceAll('-', '/');

String _analyticsInstant(DateTime value) {
  final hongKong = value.toUtc().add(const Duration(hours: 8));
  return '${hongKong.month}月${hongKong.day}日 ${formatTime(hongKong)}';
}

extension _AdminAnalyticsSection on AdminConsoleScreenState {
  Widget _analyticsOverview() =>
      _AdminAnalyticsOverview(controller: _controller, onViewPost: _viewPost);
}

class _AdminAnalyticsOverview extends StatefulWidget {
  const _AdminAnalyticsOverview({
    required this.controller,
    required this.onViewPost,
  });
  final AdminController controller;
  final Future<void> Function(String id) onViewPost;
  @override
  State<_AdminAnalyticsOverview> createState() =>
      _AdminAnalyticsOverviewState();
}

class _AdminAnalyticsOverviewState extends State<_AdminAnalyticsOverview> {
  String? _selectedDate;

  void _select(String date) => setState(() => _selectedDate = date);

  Widget _metric(
    String key,
    String title,
    String unit,
    AdminAnalyticsMetric metric,
  ) {
    final difference = metric.value - metric.previous;
    final change = difference == 0
        ? '与前期相同'
        : '较前期${difference > 0 ? '增加' : '减少'} ${difference.abs()}$unit';
    return _AdminPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(color: SeraColors.muted, fontSize: 14),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(
                  '${metric.value}',
                  key: ValueKey('admin-analytics-metric-$key'),
                  style: const TextStyle(
                    fontSize: 34,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    unit,
                    style: const TextStyle(
                      color: SeraColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(change, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 3),
            Text(
              '前期 ${metric.previous}$unit',
              style: const TextStyle(color: SeraColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metrics(AdminAnalytics data) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1000
          ? 4
          : constraints.maxWidth >= 500
          ? 2
          : 1;
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final metric in <(String, String, String, AdminAnalyticsMetric)>[
            ('new-users', '新增账号', '人', data.summary.newUsers),
            ('contributors', '发帖或评论人数', '人', data.summary.contributors),
            ('posts', '发布内容', '篇', data.summary.posts),
            ('comments', '新增评论', '条', data.summary.comments),
          ])
            SizedBox(
              width: width,
              child: _metric(metric.$1, metric.$2, metric.$3, metric.$4),
            ),
        ],
      );
    },
  );

  Widget _chartPanel(AdminAnalytics data, {required bool registrations}) =>
      _AdminPanel(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                registrations ? '新增账号' : '内容与评论趋势',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              _AdminAnalyticsChart(
                key: ValueKey(
                  registrations
                      ? 'admin-analytics-registrations'
                      : 'admin-analytics-trend',
                ),
                days: data.daily,
                registrations: registrations,
                selectedDate: _selectedDate,
                onSelected: _select,
              ),
            ],
          ),
        ),
      );

  Widget _twoColumns(Widget left, Widget right) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 850) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [left, const SizedBox(height: 20), right],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 20),
          Expanded(child: right),
        ],
      );
    },
  );

  Widget _distribution(AdminAnalytics data) {
    final total = data.contentTypes.fold<int>(
      0,
      (sum, item) => sum + item.count,
    );
    return _AdminPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '内容分布',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '所选期间发布的现存内容',
              style: TextStyle(fontSize: 13, color: SeraColors.muted),
            ),
            const SizedBox(height: 20),
            for (final category in data.contentTypes)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Semantics(
                  label:
                      '${category.label}，${category.count}篇，占${total == 0 ? '0' : (category.count * 100 / total).toStringAsFixed(1)}%',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(category.label),
                          Text(
                            '${category.count} 篇 · ${total == 0 ? '0' : (category.count * 100 / total).toStringAsFixed(1)}%',
                            key: ValueKey(
                              'admin-analytics-category-${category.key}',
                            ),
                            style: const TextStyle(
                              fontSize: 13,
                              color: SeraColors.muted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      LinearProgressIndicator(
                        value: total == 0 ? 0 : category.count / total,
                        minHeight: 7,
                        color: SeraColors.brand,
                        backgroundColor: SeraColors.mint,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topPosts(AdminAnalytics data) {
    final posts = data.topPosts
        .where((item) => item.interactions > 0)
        .take(5)
        .toList();
    return _AdminPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '互动较多的内容',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '所选期间发布 · 当前累计互动',
              style: TextStyle(fontSize: 13, color: SeraColors.muted),
            ),
            const SizedBox(height: 12),
            if (posts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  '这些内容暂时没有互动。',
                  key: ValueKey('admin-analytics-top-empty'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SeraColors.muted),
                ),
              ),
            for (final (index, item) in posts.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: 16,
                          color: SeraColors.muted,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.post.title.isEmpty
                                ? item.post.content
                                : item.post.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${item.post.authorName} · ${item.interactions} 次互动',
                            style: const TextStyle(
                              fontSize: 12,
                              color: SeraColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: ValueKey(
                        'admin-analytics-view-post-${item.post.id}',
                      ),
                      onPressed: () => widget.onViewPost(item.post.id),
                      child: const Text('查看'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _dailyTable(AdminAnalytics data) => _AdminPanel(
    child: ExpansionTile(
      key: const ValueKey('admin-analytics-daily-data'),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      title: const Text(
        '逐日数据',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      children: [
        SizedBox(
          height: 320,
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 28,
                columns: const [
                  DataColumn(label: Text('香港日期')),
                  DataColumn(label: Text('新增账号')),
                  DataColumn(label: Text('发帖或评论人数')),
                  DataColumn(label: Text('发布内容')),
                  DataColumn(label: Text('新增评论')),
                ],
                rows: [
                  for (final day in data.daily.reversed)
                    DataRow(
                      cells: [
                        DataCell(
                          TextButton(
                            key: ValueKey('admin-analytics-select-${day.date}'),
                            onPressed: () => _select(day.date),
                            child: Text(_analyticsDate(day.date)),
                          ),
                        ),
                        DataCell(Text('${day.newUsers}')),
                        DataCell(Text('${day.contributors}')),
                        DataCell(Text('${day.posts}')),
                        DataCell(Text('${day.comments}')),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _definitions() => const _AdminPanel(
    child: ExpansionTile(
      key: ValueKey('admin-analytics-definitions'),
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      title: Text(
        '统计口径',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      childrenPadding: EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text(
          '按香港日期统计，今天与前期最后一天均截至相同时刻。发帖或评论人数按账号去重，包含发布动态、活动、反馈或评论的用户，不代表访问人数或日活跃用户。\n\n内容和评论基于现存记录；删除内容、取消点赞或取消报名后，相关数量会减少。内容分为日常动态（含官方动态）、使用反馈和活动，三类互不重复。\n\n点赞和报名没有完整的发生时间记录，因此仅展示当前累计值。排行筛选所选期间发布的现存内容，再按当前累计点赞、评论和报名排序，仅列出有互动的内容。演示账号和模拟帖子如仍保留在社区中，也计入统计。',
          style: TextStyle(fontSize: 13, color: SeraColors.muted),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final data = controller.analytics;
    return ListView(
      key: const ValueKey('admin-analytics-overview'),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final days in const [7, 30, 90])
                  ChoiceChip(
                    key: ValueKey('admin-analytics-range-$days'),
                    label: Text('近 $days 天'),
                    selected: controller.analyticsDays == days,
                    onSelected: (_) => controller.loadAnalytics(days: days),
                  ),
              ],
            ),
            OutlinedButton.icon(
              key: const ValueKey('admin-analytics-refresh'),
              onPressed: controller.analyticsLoading
                  ? null
                  : () => controller.loadAnalytics(
                      days: controller.analyticsDays,
                    ),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (controller.analyticsLoading)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (controller.analyticsError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _AdminNotice(
              controller.analyticsError!,
              error: true,
              retry: () =>
                  controller.loadAnalytics(days: controller.analyticsDays),
            ),
          ),
        if (data == null || data.days != controller.analyticsDays)
          _AdminPanel(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                controller.analyticsLoading
                    ? '正在读取近 ${controller.analyticsDays} 天的数据…'
                    : '近 ${controller.analyticsDays} 天的数据尚未加载，请重试。',
                key: const ValueKey('admin-analytics-unavailable'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: SeraColors.muted),
              ),
            ),
          )
        else ...[
          Text(
            '${_analyticsDate(data.period.startDate)} — ${_analyticsDate(data.period.endDate)} · 香港时间',
            key: const ValueKey('admin-analytics-period'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 5),
          Text(
            '截至 ${_analyticsInstant(data.period.endAt)}；前期 ${_analyticsDate(data.previousPeriod.startDate)} — ${_analyticsDate(data.previousPeriod.endDate)}，截至 ${_analyticsInstant(data.previousPeriod.endAt)}',
            style: const TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
          const SizedBox(height: 18),
          _metrics(data),
          const SizedBox(height: 20),
          _twoColumns(
            _chartPanel(data, registrations: false),
            _chartPanel(data, registrations: true),
          ),
          const SizedBox(height: 20),
          _twoColumns(_distribution(data), _topPosts(data)),
          const SizedBox(height: 20),
          _AdminPanel(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 20,
                runSpacing: 8,
                children: [
                  const Text(
                    '全站当前累计',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    '${data.currentInteractions.likes} 个赞 · ${data.currentInteractions.participants} 次报名',
                    key: const ValueKey('admin-analytics-current-interactions'),
                  ),
                  const Text(
                    '不随所选日期变化',
                    style: TextStyle(fontSize: 12, color: SeraColors.muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _dailyTable(data),
          const SizedBox(height: 12),
          _definitions(),
          const SizedBox(height: 12),
          Text(
            '更新于 ${_analyticsInstant(data.generatedAt)}（香港时间）',
            style: const TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
        ],
      ],
    );
  }
}

class _AdminAnalyticsChart extends StatefulWidget {
  const _AdminAnalyticsChart({
    super.key,
    required this.days,
    required this.registrations,
    required this.selectedDate,
    required this.onSelected,
  });
  final List<AdminAnalyticsDay> days;
  final bool registrations;
  final String? selectedDate;
  final ValueChanged<String> onSelected;
  @override
  State<_AdminAnalyticsChart> createState() => _AdminAnalyticsChartState();
}

class _AdminAnalyticsChartState extends State<_AdminAnalyticsChart> {
  final _focus = FocusNode();
  bool _focused = false;
  int get _selected {
    final index = widget.days.indexWhere(
      (day) => day.date == widget.selectedDate,
    );
    return index < 0 ? widget.days.length - 1 : index;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (widget.days.isEmpty) return;
    widget.onSelected(
      widget.days[index.clamp(0, widget.days.length - 1).toInt()].date,
    );
  }

  int get _maximum {
    var maximum = 0;
    for (final day in widget.days) {
      final values = widget.registrations
          ? [day.newUsers]
          : [day.posts, day.comments];
      for (final value in values) {
        if (value > maximum) maximum = value;
      }
    }
    if (maximum < 2) return 1;
    return maximum <= 4 ? maximum : (maximum / 4).ceil() * 4;
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _select(_selected - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _select(_selected + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _select(0);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _select(widget.days.length - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _legend(String label, {bool comments = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 26,
        height: 12,
        child: CustomPaint(painter: _AdminLegendPainter(comments)),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: SeraColors.muted),
      ),
    ],
  );

  String _semanticsValue(AdminAnalyticsDay day) =>
      '${_analyticsDate(day.date)}，${widget.registrations ? '新增账号 ${day.newUsers} 人' : '发布内容 ${day.posts} 篇 · 新增评论 ${day.comments} 条'}';

  @override
  Widget build(BuildContext context) {
    if (widget.days.isEmpty) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: Text('暂无逐日数据。', style: TextStyle(color: SeraColors.muted)),
        ),
      );
    }
    final selected = widget.days[_selected];
    final maximum = _maximum;
    final description = widget.registrations
        ? '新增账号 ${selected.newUsers} 人'
        : '发布内容 ${selected.posts} 篇 · 新增评论 ${selected.comments} 条';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.registrations)
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [_legend('内容（篇）'), _legend('评论（条）', comments: true)],
          )
        else
          const Text(
            '账号（人）',
            style: TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
        const SizedBox(height: 10),
        Semantics(
          key: ValueKey(
            widget.registrations
                ? 'admin-analytics-growth-semantics'
                : 'admin-analytics-trend-semantics',
          ),
          label: widget.registrations ? '新增账号柱状图' : '内容与评论趋势图',
          value: '${_analyticsDate(selected.date)}，$description',
          increasedValue: _selected < widget.days.length - 1
              ? _semanticsValue(widget.days[_selected + 1])
              : null,
          decreasedValue: _selected > 0
              ? _semanticsValue(widget.days[_selected - 1])
              : null,
          hint: '左右方向键切换日期，Home 和 End 跳到首日或末日。',
          onIncrease: _selected < widget.days.length - 1
              ? () => _select(_selected + 1)
              : null,
          onDecrease: _selected > 0 ? () => _select(_selected - 1) : null,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            onFocusChange: (value) => setState(() => _focused = value),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _focused ? SeraColors.brand : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SizedBox(
                height: 224,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const left = 34.0;
                    final width = (constraints.maxWidth - left - 8).clamp(
                      1.0,
                      double.infinity,
                    );
                    final dateSize = MediaQuery.textScalerOf(context).scale(11);
                    final tickHeight = width < 220 && dateSize > 14
                        ? dateSize * 3 + 8
                        : 28.0;
                    final plotHeight = constraints.maxHeight - 10 - tickHeight;
                    return Stack(
                      children: [
                        Positioned(
                          left: left,
                          right: 8,
                          top: 10,
                          bottom: tickHeight,
                          child: GestureDetector(
                            key: ValueKey(
                              widget.registrations
                                  ? 'admin-analytics-growth-plot'
                                  : 'admin-analytics-trend-plot',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (event) {
                              _focus.requestFocus();
                              _select(
                                (event.localPosition.dx /
                                        width *
                                        (widget.days.length - 1))
                                    .round(),
                              );
                            },
                            onHorizontalDragUpdate: (event) => _select(
                              (event.localPosition.dx /
                                      width *
                                      (widget.days.length - 1))
                                  .round(),
                            ),
                            child: CustomPaint(
                              painter: _AdminTrendPainter(
                                days: widget.days,
                                selected: _selected,
                                maximum: maximum,
                                registrations: widget.registrations,
                              ),
                            ),
                          ),
                        ),
                        for (final value
                            in maximum < 2
                                ? [0, maximum]
                                : [0, (maximum / 2).ceil(), maximum])
                          Positioned(
                            left: 0,
                            top: 10 + (1 - value / maximum) * plotHeight - 7,
                            child: Text(
                              '$value',
                              textScaler: TextScaler.noScaling,
                              style: const TextStyle(
                                fontSize: 11,
                                color: SeraColors.muted,
                              ),
                            ),
                          ),
                        Positioned(
                          left: left,
                          right: 8,
                          bottom: 2,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  widget.days.first.date
                                      .substring(5)
                                      .replaceAll('-', '/'),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: SeraColors.muted,
                                  ),
                                ),
                              ),
                              if (widget.days.length > 2 && width > 300)
                                Expanded(
                                  child: Text(
                                    widget.days[widget.days.length ~/ 2].date
                                        .substring(5)
                                        .replaceAll('-', '/'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: SeraColors.muted,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  widget.days.last.date
                                      .substring(5)
                                      .replaceAll('-', '/'),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: SeraColors.muted,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
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
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            '${_analyticsDate(selected.date)} · $description',
            key: ValueKey(
              widget.registrations
                  ? 'admin-analytics-growth-selected'
                  : 'admin-analytics-trend-selected',
            ),
            style: const TextStyle(fontSize: 12, color: SeraColors.muted),
          ),
        ),
      ],
    );
  }
}

class _AdminLegendPainter extends CustomPainter {
  const _AdminLegendPainter(this.comments);
  final bool comments;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = comments ? SeraColors.blue : SeraColors.brand
      ..strokeWidth = 2;
    if (comments) {
      for (var x = 0.0; x < size.width; x += 7) {
        canvas.drawLine(
          Offset(x, 6),
          Offset((x + 4).clamp(0, size.width), 6),
          paint,
        );
      }
      canvas.drawRect(const Rect.fromLTWH(10, 3, 6, 6), paint);
    } else {
      canvas.drawLine(const Offset(0, 6), Offset(size.width, 6), paint);
      canvas.drawCircle(const Offset(13, 6), 3, paint);
    }
  }

  @override
  bool shouldRepaint(_AdminLegendPainter oldDelegate) =>
      oldDelegate.comments != comments;
}

class _AdminTrendPainter extends CustomPainter {
  const _AdminTrendPainter({
    required this.days,
    required this.selected,
    required this.maximum,
    required this.registrations,
  });
  final List<AdminAnalyticsDay> days;
  final int selected, maximum;
  final bool registrations;
  double _x(int index, double width) =>
      days.length == 1 ? width / 2 : width * index / (days.length - 1);
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = SeraColors.line
      ..strokeWidth = 1;
    for (final value
        in maximum < 2 ? [0, maximum] : [0, (maximum / 2).ceil(), maximum]) {
      final y = size.height * (1 - value / maximum);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (days.isEmpty) return;
    final selectedX = _x(selected, size.width);
    final guide = Paint()
      ..color = SeraColors.control.withValues(alpha: .55)
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 7) {
      canvas.drawLine(
        Offset(selectedX, y),
        Offset(selectedX, (y + 3).clamp(0, size.height)),
        guide,
      );
    }
    if (registrations) {
      final width = (size.width / (days.length + 1) * .65).clamp(1.5, 26.0);
      for (final (index, day) in days.indexed) {
        if (day.newUsers == 0) continue;
        final height = size.height * day.newUsers / maximum;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              (_x(index, size.width) - width / 2).clamp(
                0,
                (size.width - width).clamp(0, double.infinity),
              ),
              size.height - height,
              width,
              height,
            ),
            const Radius.circular(2),
          ),
          Paint()
            ..color = index == selected
                ? SeraColors.brand
                : SeraColors.brand.withValues(alpha: .45),
        );
      }
      return;
    }
    for (final comments in const [false, true]) {
      final paint = Paint()
        ..color = comments ? SeraColors.blue : SeraColors.brand
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (final (index, day) in days.indexed) {
        final point = Offset(
          _x(index, size.width),
          size.height * (1 - (comments ? day.comments : day.posts) / maximum),
        );
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      if (comments) {
        for (final metric in path.computeMetrics()) {
          for (var d = 0.0; d < metric.length; d += 9) {
            canvas.drawPath(
              metric.extractPath(d, (d + 5).clamp(0, metric.length)),
              paint,
            );
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      final value = comments ? days[selected].comments : days[selected].posts;
      final point = Offset(selectedX, size.height * (1 - value / maximum));
      final fill = Paint()
        ..color = comments ? SeraColors.blue : SeraColors.brand;
      if (comments) {
        canvas.drawRect(
          Rect.fromCenter(center: point, width: 7, height: 7),
          fill,
        );
      } else {
        canvas.drawCircle(point, 4, fill);
      }
    }
  }

  @override
  bool shouldRepaint(_AdminTrendPainter oldDelegate) =>
      oldDelegate.days != days ||
      oldDelegate.selected != selected ||
      oldDelegate.maximum != maximum ||
      oldDelegate.registrations != registrations;
}
