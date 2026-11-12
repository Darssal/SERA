import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import 'sera_theme.dart';
export 'sera_theme.dart';

void openScreen(
  BuildContext c,
  String id, {
  String? taskId,
  String? eventId,
  String? draftId,
  bool replaceBrowserHistory = false,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  // The previous action's feedback must not cover the next page's controls.
  ScaffoldMessenger.maybeOf(c)?.clearSnackBars();
  ScaffoldMessenger.maybeOf(c)?.removeCurrentSnackBar();
  final q = <String, String>{
    'taskId': ?taskId,
    'eventId': ?eventId,
    'draftId': ?draftId,
  };
  final location = Uri(
    path: '/$id',
    queryParameters: q.isEmpty ? null : q,
  ).toString();
  final source = GoRouterState.of(c).uri.pathSegments.firstOrNull
      ?.split('-')
      .first;
  final target = id.split('-').first;
  final intermediateFocusStep =
      target == '47' && const {'24', '26', '46'}.contains(source);
  if (replaceBrowserHistory || intermediateFocusStep) {
    Router.neglect(c, () {
      c.push(location, extra: const {'replaceHistoryOnExit': true});
    });
  } else {
    c.push(location);
  }
}

Future<void> runAction(
  BuildContext c,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (c.mounted && success != null) {
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (e) {
    if (c.mounted) {
      ScaffoldMessenger.of(c)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

String formatDate(DateTime d) =>
    '${d.month}月${d.day}日 周${['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';
String formatTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String formatRange(DateTime s, DateTime e) =>
    '${formatTime(s)}–${formatTime(e)}';
String formatEntryRange(CalendarEntry entry, {bool showDate = false}) {
  String day(DateTime value) {
    if (showDate && !entry.allDay) {
      return '${entry.start.year != entry.end.year ? '${value.year}年' : ''}${value.month}月${value.day}日';
    }
    return entry.start.year != entry.end.year
        ? '${value.year}年${formatDate(value)}'
        : formatDate(value);
  }

  if (entry.allDay) {
    final last = calendarDay(entry.end, -1);
    return dateOnly(entry.start) == dateOnly(last)
        ? '${day(entry.start)} · 全天'
        : '${day(entry.start)}–${day(last)} · 全天';
  }
  return dateOnly(entry.start) == dateOnly(entry.end)
      ? '${showDate ? '${day(entry.start)} ' : ''}${formatRange(entry.start, entry.end)}'
      : '${day(entry.start)} ${formatTime(entry.start)}–${day(entry.end)} ${formatTime(entry.end)}';
}

String formatMinutes(int m) =>
    m >= 60 ? '${m ~/ 60}小时${m % 60 == 0 ? '' : '${m % 60}分钟'}' : '$m分钟';

class SeraIcon extends StatelessWidget {
  const SeraIcon(this.name, {super.key, this.size = 22, this.color});
  final String name;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext c) => SvgPicture.asset(
    'assets/icons/icon-$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color ?? SeraColors.brand, BlendMode.srcIn),
    excludeFromSemantics: true,
  );
}

class SeraScaffold extends StatelessWidget {
  const SeraScaffold({
    super.key,
    this.title = '',
    this.titleContent,
    this.body,
    this.slivers,
    this.scrollKey,
    this.scrollController,
    this.footer,
    this.navIndex,
    this.actions = const [],
    this.showBack = true,
    this.brand = false,
    this.onBack,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    this.surfaceColor,
  }) : assert((body == null) != (slivers == null), 'Provide body or slivers.');
  final String title;
  final Widget? titleContent;
  final Widget? body;
  final List<Widget>? slivers;
  final Key? scrollKey;
  final ScrollController? scrollController;
  final Widget? footer;
  final int? navIndex;
  final List<Widget> actions;
  final bool showBack, brand;
  final VoidCallback? onBack;
  final EdgeInsetsGeometry contentPadding;
  final Color? surfaceColor;
  @override
  Widget build(BuildContext c) => Scaffold(
    backgroundColor: surfaceColor,
    appBar: AppBar(
      backgroundColor: surfaceColor,
      toolbarHeight: 56,
      centerTitle: !brand && titleContent == null,
      titleSpacing: brand ? 17 : null,
      automaticallyImplyLeading: false,
      leading: showBack && !brand
          ? IconButton(
              tooltip: '返回',
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                if (onBack != null) {
                  onBack!();
                } else {
                  if (c.canPop()) {
                    c.pop();
                  } else {
                    c.go('/04');
                  }
                }
              },
              icon: const SeraIcon('back', color: SeraColors.ink),
            )
          : null,
      title: brand
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/brand/brand-sera-mark@3x.png',
                  width: 22,
                  height: 24,
                ),
                const SizedBox(width: 8),
                const Text(
                  '序日',
                  style: TextStyle(
                    letterSpacing: 1,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          : titleContent ??
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 26 / 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
      actions: [
        ...actions,
        if (navIndex == 0)
          IconButton(
            tooltip: '账户与设置',
            onPressed: () => openScreen(c, '30'),
            icon: const SeraIcon('user', color: SeraColors.ink),
          ),
      ],
    ),
    body: SafeArea(
      top: false,
      bottom: navIndex == null && footer == null,
      child: Column(
        children: [
          Expanded(
            child: slivers != null
                ? CustomScrollView(
                    key: scrollKey,
                    controller: scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    slivers: [
                      SliverPadding(
                        padding: contentPadding,
                        sliver: SliverMainAxisGroup(slivers: slivers!),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    key: scrollKey,
                    controller: scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: contentPadding,
                    child: SizedBox(width: double.infinity, child: body),
                  ),
          ),
          if (footer != null)
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: SeraColors.line)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: SafeArea(
                top: false,
                bottom: navIndex == null,
                child: footer!,
              ),
            ),
        ],
      ),
    ),
    bottomNavigationBar: navIndex == null ? null : _BottomNav(index: navIndex!),
  );
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index});
  final int index;
  @override
  Widget build(BuildContext c) => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: SeraColors.line)),
    ),
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 66,
        child: Row(
          children: List.generate(
            4,
            (i) => Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                child: InkWell(
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    if (i != index) {
                      c.go(
                        const [
                          '/04',
                          '/17?filter=todo',
                          '/12',
                          '/community',
                        ][i],
                      );
                    }
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (i == 3)
                        Icon(
                          Icons.forum_outlined,
                          size: 24,
                          color: i == index
                              ? SeraColors.brand
                              : SeraColors.muted,
                        )
                      else
                        SeraIcon(
                          ['home', 'list', 'calendar'][i],
                          color: i == index
                              ? SeraColors.brand
                              : SeraColors.muted,
                        ),
                      const SizedBox(height: 3),
                      Text(
                        ['今日', '计划', '日程', '社区'][i],
                        style: TextStyle(
                          fontSize: 12,
                          color: i == index
                              ? SeraColors.brand
                              : SeraColors.muted,
                          fontWeight: i == index
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class SeraCard extends StatelessWidget {
  const SeraCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: color ?? Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// Secondary details stay available without occupying the main reading flow.
/// Keeping children mounted preserves unfinished forms when the section closes.
class SeraDisclosure extends StatelessWidget {
  const SeraDisclosure({
    super.key,
    required this.title,
    required this.children,
    this.summary,
    this.initiallyExpanded = false,
    this.controller,
  });
  final String title;
  final String? summary;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ExpansibleController? controller;

  @override
  Widget build(BuildContext context) => SeraCard(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: ExpansionTile(
      key: PageStorageKey('disclosure:$title'),
      tilePadding: const EdgeInsets.symmetric(vertical: 4),
      childrenPadding: const EdgeInsets.only(top: 8, bottom: 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      maintainState: true,
      controller: controller,
      initiallyExpanded: initiallyExpanded,
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: SeraColors.brand,
      collapsedIconColor: SeraColors.brand,
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: summary == null
          ? null
          : Text(
              summary!,
              style: const TextStyle(
                fontSize: 13,
                height: 20 / 13,
                color: SeraColors.muted,
              ),
            ),
      children: children,
    ),
  );
}

class SeraButton extends StatelessWidget {
  const SeraButton(
    this.label, {
    super.key,
    this.onPressed,
    this.variant = 'primary',
    this.icon,
    this.busy = false,
  });
  final String label, variant;
  final String? icon;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext c) {
    final fill = variant == 'primary'
        ? SeraColors.brand
        : variant == 'danger'
        ? SeraColors.redBg
        : Colors.transparent;
    final fg = variant == 'primary'
        ? Colors.white
        : variant == 'danger'
        ? SeraColors.red
        : variant == 'quiet'
        ? SeraColors.muted
        : variant == 'ghost'
        ? SeraColors.ink
        : SeraColors.brand;
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: busy ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: fill,
          foregroundColor: fg,
          disabledBackgroundColor: busy
              ? fill
              : variant == 'primary' ||
                    variant == 'secondary' ||
                    variant == 'danger'
              ? SeraColors.line
              : Colors.transparent,
          disabledForegroundColor: busy ? fg : SeraColors.muted,
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: variant == 'ghost' || variant == 'secondary'
                ? const BorderSide(color: SeraColors.control)
                : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy) ...[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
              const SizedBox(width: 8),
            ] else if (icon != null) ...[
              SeraIcon(icon!, size: 19, color: fg),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeraIntro extends StatelessWidget {
  const SeraIntro(this.title, {super.key, this.subtitle, this.eyebrow});
  final String title;
  final String? subtitle, eyebrow;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          Text(
            eyebrow!,
            style: const TextStyle(
              color: SeraColors.brand,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            height: 32 / 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            style: const TextStyle(
              color: SeraColors.muted,
              fontSize: 15,
              height: 22 / 15,
            ),
          ),
        ],
      ],
    ),
  );
}

class SeraSection extends StatelessWidget {
  const SeraSection(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              height: 26 / 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            child: Text(action!, style: const TextStyle(fontSize: 13)),
          ),
      ],
    ),
  );
}

class SeraNote extends StatelessWidget {
  const SeraNote(
    this.title, {
    super.key,
    this.body,
    this.color,
    this.background,
    this.icon = 'spark',
  });
  final String title, icon;
  final String? body;
  final Color? color, background;
  @override
  Widget build(BuildContext c) => SeraCard(
    color: background ?? SeraColors.mint,
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SeraIcon(icon, size: 20, color: color ?? SeraColors.brand),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color ?? SeraColors.brand,
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: 5),
                Text(
                  body!,
                  style: TextStyle(
                    fontSize: 13,
                    height: 20 / 13,
                    color: color ?? SeraColors.mutedOnMint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class SeraTag extends StatelessWidget {
  const SeraTag(this.text, {super.key, this.color, this.background});
  final String text;
  final Color? color, background;
  @override
  Widget build(BuildContext c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: background ?? SeraColors.mint,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: color ?? SeraColors.brand,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class SeraField extends StatelessWidget {
  const SeraField(
    this.label,
    this.value, {
    super.key,
    this.trailing,
    this.valueAlign = TextAlign.start,
  });
  final String label, value;
  final Widget? trailing;
  final TextAlign valueAlign;
  @override
  Widget build(BuildContext c) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: trailing == null ? 0 : 48),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: SeraColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: valueAlign,
              style: const TextStyle(fontSize: 15, height: 22 / 15),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

class SeraInput extends StatelessWidget {
  const SeraInput({
    super.key,
    required this.label,
    required this.controller,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.validator,
    this.readOnly = false,
    this.onTap,
    this.hintText,
  });
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final int minLines;
  final int? maxLines;
  final int? maxLength;
  final String? Function(String?)? validator;
  final bool readOnly;
  final VoidCallback? onTap;
  final String? hintText;
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          minLines: minLines,
          maxLines: maxLines,
          maxLength: maxLength,
          validator: validator,
          readOnly: readOnly,
          onTap: onTap,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          style: const TextStyle(fontSize: 15, height: 22 / 15),
          decoration: InputDecoration(hintText: hintText),
        ),
      ],
    ),
  );
}

class SeraWeekdayPicker extends StatelessWidget {
  const SeraWeekdayPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  final List<int> selected;
  final ValueChanged<List<int>> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final labelWidth = MediaQuery.textScalerOf(context).scale(13);
      final minWidth = (labelWidth + 28).clamp(48.0, double.infinity);
      final rowWidth = bounds.maxWidth.clamp(
        minWidth * 7 + 12,
        double.infinity,
      );
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: rowWidth,
          child: Row(
            children: [
              for (var i = 1; i <= 7; i++) ...[
                if (i > 1) const SizedBox(width: 2),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: '周${['一', '二', '三', '四', '五', '六', '日'][i - 1]}',
                    selected: selected.contains(i),
                    onTap: () {
                      final next = [...selected];
                      if (!next.remove(i)) next.add(i);
                      onChanged(next..sort());
                    },
                    child: ExcludeSemantics(
                      child: TextButton(
                        onPressed: () {
                          final next = [...selected];
                          if (!next.remove(i)) next.add(i);
                          onChanged(next..sort());
                        },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 12,
                          ),
                          foregroundColor: selected.contains(i)
                              ? SeraColors.brand
                              : SeraColors.ink,
                          backgroundColor: selected.contains(i)
                              ? SeraColors.mint
                              : SeraColors.surface,
                          side: BorderSide(
                            color: selected.contains(i)
                                ? SeraColors.brand
                                : SeraColors.control,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (selected.contains(i)) ...[
                              const Icon(Icons.check, size: 10),
                              const SizedBox(width: 2),
                            ],
                            Text(
                              ['一', '二', '三', '四', '五', '六', '日'][i - 1],
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class SeraEmpty extends StatelessWidget {
  const SeraEmpty(
    this.title,
    this.subtitle, {
    super.key,
    this.icon = 'calendar',
    this.action,
    this.onAction,
  });
  final String title, subtitle, icon;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext c) => Align(
    alignment: Alignment.center,
    heightFactor: 1,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: SeraColors.mint,
              shape: BoxShape.circle,
            ),
            child: SeraIcon(icon, size: 28),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 20 / 13,
                color: SeraColors.muted,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 24),
            SeraButton(action!, onPressed: onAction),
          ],
        ],
      ),
    ),
  );
}

class SeraProgress extends StatelessWidget {
  const SeraProgress(this.value, {super.key});
  final double value;
  @override
  Widget build(BuildContext c) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: LinearProgressIndicator(
      value: value.clamp(0, 1),
      minHeight: 6,
      color: SeraColors.brand,
      backgroundColor: SeraColors.line,
    ),
  );
}

class SeraTaskRow extends StatelessWidget {
  const SeraTaskRow(
    this.task, {
    super.key,
    this.entry,
    this.showDate = false,
    this.onTap,
    this.onDone,
  });
  final SeraTask task;
  final CalendarEntry? entry;
  final bool showDate;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onDone;
  @override
  Widget build(BuildContext c) {
    final timing = entry == null
        ? '待安排 · ${formatMinutes(task.estimatedMinutes)}'
        : '${formatEntryRange(entry!, showDate: showDate)}${entry!.minutes == task.estimatedMinutes ? '' : ' · 预计${formatMinutes(task.estimatedMinutes)}'}';
    final row = Material(
      color: SeraColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: SeraColors.line)),
          ),
          child: Row(
            children: [
              if (onDone != null)
                Checkbox(
                  value: task.done,
                  semanticLabel: '${task.done ? '恢复未完成' : '完成'} ${task.title}',
                  onChanged: (v) => onDone!(v ?? false),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  side: const BorderSide(color: SeraColors.control, width: 1.5),
                )
              else
                SizedBox(
                  width: 48,
                  child: ExcludeSemantics(
                    child: Icon(
                      task.done
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      size: 22,
                      color: task.done ? SeraColors.brand : SeraColors.control,
                    ),
                  ),
                ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                          decoration: task.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: task.done ? SeraColors.muted : SeraColors.ink,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        timing,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 20 / 13,
                          color: SeraColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (task.goalId != null)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SeraIcon('target', size: 18, color: SeraColors.muted),
                ),
              if (onTap != null)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SeraIcon('chevron', size: 16, color: SeraColors.muted),
                ),
            ],
          ),
        ),
      ),
    );
    if (onDone == null && onTap != null) {
      return Semantics(
        key: ValueKey('task-row-open:${task.id}'),
        button: true,
        enabled: true,
        label: '${task.title}${task.done ? '，已完成' : ''}\n$timing',
        onTap: onTap,
        excludeSemantics: true,
        child: row,
      );
    }
    return row;
  }
}

class SeraSettingRow extends StatelessWidget {
  const SeraSettingRow(
    this.title, {
    super.key,
    this.subtitle,
    this.icon = 'settings',
    this.onTap,
    this.trailing,
    this.color,
  });
  final String title, icon;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? color;
  @override
  Widget build(BuildContext c) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            SeraIcon(icon, size: 22, color: color ?? SeraColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color ?? SeraColors.ink,
                      fontSize: 15,
                      height: 22 / 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 20 / 13,
                        color: SeraColors.muted,
                      ),
                    ),
                ],
              ),
            ),
            trailing ??
                const SeraIcon('chevron', size: 17, color: SeraColors.muted),
          ],
        ),
      ),
    ),
  );
}

class SeraAgendaRow extends StatelessWidget {
  const SeraAgendaRow(
    this.entry, {
    super.key,
    this.onTap,
    this.showDate = false,
  });
  final CalendarEntry entry;
  final VoidCallback? onTap;
  final bool showDate;
  @override
  Widget build(BuildContext c) {
    final metadata = [
      formatEntryRange(entry, showDate: showDate),
      if (entry.place.isNotEmpty) entry.place,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SeraColors.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: SeraIcon(
                entry.isTask ? 'target' : 'calendar',
                size: 20,
                color: entry.isTask ? SeraColors.brand : SeraColors.muted,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    metadata,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: SeraColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Padding(
                padding: EdgeInsets.only(top: 3, left: 12),
                child: SeraIcon('chevron', size: 16, color: SeraColors.muted),
              ),
          ],
        ),
      ),
    );
  }
}
