import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/sera_controller.dart';
import '../../data/auth_repository.dart';
import '../../domain/models.dart';
import 'calendar_layout.dart';
import 'sera_motion.dart';
import 'sera_scroll_reveal.dart';
import 'sera_widgets.dart';

/// A day is a readable list of its actual entries, without empty hourly rows.
class SeraCalendarAgenda extends StatefulWidget {
  const SeraCalendarAgenda({
    super.key,
    required this.controller,
    required this.day,
    this.focusEntryId,
  });

  final SeraController controller;
  final DateTime day;
  final String? focusEntryId;

  @override
  State<SeraCalendarAgenda> createState() => _SeraCalendarAgendaState();
}

class _SeraCalendarAgendaState extends State<SeraCalendarAgenda> {
  SeraRevealRequest _focusRequest = SeraRevealRequest();

  @override
  void didUpdateWidget(covariant SeraCalendarAgenda oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusEntryId != widget.focusEntryId ||
        !identical(oldWidget.controller, widget.controller)) {
      _focusRequest = SeraRevealRequest();
    }
  }

  @override
  Widget build(BuildContext context) {
    final zone = widget.controller.data.preferences.timeZone;
    final entries = widget.controller.entriesOn(widget.day);
    final allDay = entries.where((entry) => entry.allDay).toList();
    final timed = calendarDaySlices(entries, widget.day, zone);
    return Column(
      key: const ValueKey('calendar-day-agenda'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (allDay.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '全天',
              style: TextStyle(fontSize: 13, color: SeraColors.muted),
            ),
          ),
          for (final entry in allDay)
            _row(
              context,
              entry,
              ValueKey('all-day:${entry.id}'),
              formatEntryRange(entry),
            ),
          if (timed.isNotEmpty) const SizedBox(height: 16),
        ],
        for (final slice in timed)
          _row(
            context,
            slice.entry,
            ValueKey('calendar-event:${slice.entry.id}:${slice.startMinute}'),
            _sliceRange(slice, zone),
          ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    CalendarEntry entry,
    Key key,
    String range,
  ) {
    final done = widget.controller.task(entry.taskId)?.done == true;
    final metadata = [
      range,
      if (entry.place.isNotEmpty) entry.place,
    ].join(' · ');
    return SeraRevealOnce(
      request: entry.id == widget.focusEntryId ? _focusRequest : null,
      child: Column(
        children: [
          InkWell(
            key: key,
            onTap: () => openScreen(
              context,
              entry.isTask ? '18' : '15',
              taskId: entry.taskId,
              eventId: entry.id,
            ),
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 12),
                      child: done
                          ? const Icon(
                              Icons.check_circle_outline,
                              size: 20,
                              color: SeraColors.muted,
                            )
                          : SeraIcon(
                              entry.isTask ? 'target' : 'calendar',
                              size: 20,
                              color: entry.isTask
                                  ? SeraColors.brand
                                  : SeraColors.muted,
                            ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.title,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: done ? SeraColors.muted : SeraColors.ink,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
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
                    const Padding(
                      padding: EdgeInsets.only(top: 4, left: 8),
                      child: SeraIcon(
                        'chevron',
                        size: 16,
                        color: SeraColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

String _sliceRange(CalendarDaySlice slice, String zone) {
  final entry = slice.entry.copyWith(
    start: inTimeZone(slice.entry.start, zone, wallClock: true),
    end: inTimeZone(slice.entry.end, zone, wallClock: true),
  );
  if (dateOnly(entry.start) == dateOnly(entry.end)) {
    return formatRange(entry.start, entry.end);
  }
  if (entry.start.year == entry.end.year &&
      calendarDay(dateOnly(entry.start), 1) == dateOnly(entry.end)) {
    return '${slice.continuesBefore ? '昨日' : ''}${formatTime(entry.start)}–${slice.continuesBefore ? '' : '次日'}${formatTime(entry.end)}';
  }
  return formatEntryRange(entry, showDate: true);
}

class SeraCalendarTimeGrid extends StatefulWidget {
  const SeraCalendarTimeGrid({
    super.key,
    required this.controller,
    required this.days,
    this.focusEntryId,
  });
  final SeraController controller;
  final List<DateTime> days;
  final String? focusEntryId;

  @override
  State<SeraCalendarTimeGrid> createState() => _SeraCalendarTimeGridState();
}

class _SeraCalendarTimeGridState extends State<SeraCalendarTimeGrid> {
  SeraController get controller => widget.controller;
  List<DateTime> get days => widget.days;
  SeraRevealRequest _focusRequest = SeraRevealRequest();
  final ScrollController _timeScroll = ScrollController(
    keepScrollOffset: false,
  );
  DateTime? _timeWindowDay;

  @override
  void dispose() {
    _timeScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SeraCalendarTimeGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusEntryId != widget.focusEntryId ||
        !identical(oldWidget.controller, controller)) {
      _focusRequest = SeraRevealRequest();
    }
    if (!identical(oldWidget.controller, controller)) _timeWindowDay = null;
  }

  Widget _timeViewport(
    BuildContext context, {
    required double contentHeight,
    required Widget child,
  }) {
    if (days.length == 1) return child;
    final height = math.min(
      contentHeight,
      (MediaQuery.sizeOf(context).height * .4).clamp(240.0, 380.0),
    );
    final day = dateOnly(days.first);
    if (_timeWindowDay != day) {
      _timeWindowDay = day;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _timeWindowDay != day || !_timeScroll.hasClients) {
          return;
        }
        _timeScroll.jumpTo(0);
      });
    }
    return SizedBox(
      key: const ValueKey('calendar-week-time-viewport'),
      height: height,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _timeScroll,
          thumbVisibility: contentHeight > height,
          thickness: 3,
          radius: const Radius.circular(3),
          child: SingleChildScrollView(
            key: const ValueKey('calendar-week-time-scroll'),
            controller: _timeScroll,
            primary: false,
            child: child,
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, CalendarEntry entry) => openScreen(
    context,
    entry.isTask ? '18' : '15',
    taskId: entry.taskId,
    eventId: entry.id,
  );

  Future<void> _showEntries(
    BuildContext context,
    DateTime day,
    List<CalendarEntry> entries,
  ) async {
    final route = ModalRoute.of(context);
    final auth = context.read<AuthRepository?>();
    final owner = auth?.sessionOwner;
    final selected = await showModalBottomSheet<CalendarEntry>(
      context: context,
      sheetAnimationStyle: SeraMotion.sheetStyle(context),
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            children: [
              Text(
                formatDate(day),
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              for (final entry in entries)
                SeraAgendaRow(entry, onTap: () => Navigator.pop(sheet, entry)),
            ],
          ),
        ),
      ),
    );
    if (selected != null &&
        context.mounted &&
        route?.isCurrent == true &&
        identical(context.read<SeraController>(), controller) &&
        identical(context.read<AuthRepository?>(), auth) &&
        auth?.sessionOwner == owner &&
        controller.entriesOn(day).any((e) => e.id == selected.id)) {
      _open(context, selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final week = days.length > 1;
    final scale = week ? 1.15 : 1.2;
    final textScale = MediaQuery.textScalerOf(context);
    final minimumBlockHeight = 20 + textScale.scale(13) * (1.35 + 20 / 13);
    final zone = controller.data.preferences.timeZone;
    final axisDay = dateOnly(inTimeZone(days.first, zone, wallClock: true));
    final dayMinutes = calendarDay(axisDay, 1).difference(axisDay).inMinutes;
    String hourLabel(int minute) {
      if (minute == dayMinutes) return '24:00';
      final instant = axisDay.add(Duration(minutes: minute));
      return dayMinutes == 1440
          ? formatTime(instant)
          : '${formatTime(instant)}\n${instant.timeZoneName}';
    }

    final perDay = [for (final day in days) controller.entriesOn(day)];
    final focusDay = perDay.indexWhere(
      (entries) => entries.any((entry) => entry.id == widget.focusEntryId),
    );
    Widget reveal(Widget child, int day, Iterable<CalendarEntry> entries) =>
        SeraRevealOnce(
          request:
              day == focusDay &&
                  entries.any((entry) => entry.id == widget.focusEntryId)
              ? _focusRequest
              : null,
          child: child,
        );
    final slices = [
      for (var i = 0; i < days.length; i++)
        calendarDaySlices(perDay[i], days[i], zone),
    ];
    final groups = [
      for (final day in slices)
        calendarOverlapGroups(day, scale: scale, minHeight: minimumBlockHeight),
    ];
    final allDay = [
      for (final day in perDay) day.where((e) => e.allDay).toList(),
    ];
    final allSlices = slices.expand((day) => day).toList();
    if (allSlices.isEmpty) _timeWindowDay = null;
    final firstMinute = allSlices.fold<int>(
      week && allSlices.isNotEmpty
          ? math.max(
              0,
              allSlices.map((slice) => slice.startMinute).reduce(math.min) ~/
                      60 *
                      60 -
                  60,
            )
          : atMinute(axisDay, 540).difference(axisDay).inMinutes,
      (from, item) => math.min(from, item.startMinute ~/ 60 * 60),
    );
    final lastMinute = groups
        .expand((day) => day)
        .fold<double>(
          week
              ? 0
              : atMinute(
                  axisDay,
                  1080,
                ).difference(axisDay).inMinutes.toDouble(),
          (to, item) => math.max(to, (item.bottomMinute / 60).ceil() * 60),
        );
    final height = (lastMinute - firstMinute) * scale;
    return LayoutBuilder(
      builder: (context, viewport) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(
            viewport.maxWidth,
            week
                ? 42 +
                      days.length *
                          math.max(56.0, textScale.scale(12) * 3.1 + 19)
                : viewport.maxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (week)
                Padding(
                  padding: const EdgeInsets.only(left: 42, bottom: 16),
                  child: Row(
                    children: [
                      for (final day in days)
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              controller.setSelectedDate(day);
                              context.go('/12');
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 56),
                              child: Column(
                                children: [
                                  Text(
                                    '周${['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1]}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: SeraColors.muted,
                                    ),
                                  ),
                                  Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: dateOnly(day) == controller.today
                                          ? SeraColors.brand
                                          : SeraColors.ink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (allDay.any((entries) => entries.isNotEmpty)) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(
                      width: 42,
                      child: Padding(
                        padding: EdgeInsets.only(top: 14),
                        child: Text(
                          '全天',
                          style: TextStyle(
                            fontSize: 12,
                            color: SeraColors.muted,
                          ),
                        ),
                      ),
                    ),
                    for (var i = 0; i < days.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4, right: 3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (week && allDay[i].isNotEmpty)
                                reveal(
                                  _groupButton(
                                    context,
                                    allDay[i].length == 1
                                        ? allDay[i].single.title
                                        : '${allDay[i].length} 项',
                                    () {
                                      if (allDay[i].length == 1) {
                                        _open(context, allDay[i].single);
                                      } else {
                                        _showEntries(
                                          context,
                                          days[i],
                                          allDay[i],
                                        );
                                      }
                                    },
                                    key: ValueKey(
                                      'all-day:${calendarDateString(days[i])}',
                                    ),
                                    semanticLabel:
                                        '${formatDate(days[i])}，全天，${allDay[i].map((entry) => entry.title).join('，')}',
                                  ),
                                  i,
                                  allDay[i],
                                ),
                              if (!week)
                                for (final entry in allDay[i])
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: reveal(
                                      _groupButton(
                                        context,
                                        entry.title,
                                        () => _open(context, entry),
                                        key: ValueKey('all-day:${entry.id}'),
                                      ),
                                      i,
                                      [entry],
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (allSlices.isNotEmpty)
                _timeViewport(
                  context,
                  contentHeight: height + 20,
                  child: SizedBox(
                    height: height + 20,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final column = (box.maxWidth - 42) / days.length;
                        return Stack(
                          children: [
                            for (
                              var minute = firstMinute;
                              minute <= math.min(lastMinute, dayMinutes);
                              minute += 60
                            )
                              Positioned(
                                top: (minute - firstMinute) * scale,
                                left: 0,
                                right: 0,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 42,
                                      child: Text(
                                        hourLabel(minute),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          height: 1,
                                          color: SeraColors.muted,
                                        ),
                                      ),
                                    ),
                                    const Expanded(child: Divider(height: 1)),
                                  ],
                                ),
                              ),
                            for (var i = 0; i < days.length; i++) ...[
                              if (week)
                                Positioned(
                                  left: 42 + i * column,
                                  top: 0,
                                  bottom: 20,
                                  child: Container(
                                    width: 1,
                                    color: SeraColors.line,
                                  ),
                                ),
                              for (final group in groups[i])
                                if (group.placements.length > 1 &&
                                    column / group.placements.first.lanes <
                                        (week ? 84 : 90))
                                  Positioned(
                                    left: 46 + i * column,
                                    top:
                                        (group.topMinute - firstMinute) *
                                            scale +
                                        1,
                                    width: column - 7,
                                    height: math.max(
                                      48,
                                      (group.bottomMinute - group.topMinute) *
                                              scale -
                                          2,
                                    ),
                                    child: reveal(
                                      _groupButton(
                                        context,
                                        '${group.placements.length} 项',
                                        () => _showEntries(
                                          context,
                                          days[i],
                                          group.placements
                                              .map((p) => p.slice.entry)
                                              .toList(),
                                        ),
                                        key: ValueKey(
                                          'calendar-group:${calendarDateString(days[i])}:${group.placements.first.slice.entry.id}',
                                        ),
                                        semanticLabel:
                                            '${formatDate(days[i])}，${group.placements.length} 项安排，${group.placements.map((p) => p.slice.entry.title).join('，')}',
                                      ),
                                      i,
                                      group.placements.map(
                                        (p) => p.slice.entry,
                                      ),
                                    ),
                                  )
                                else
                                  for (final placement in group.placements)
                                    Positioned(
                                      left:
                                          46 +
                                          i * column +
                                          placement.lane *
                                              (column - 4) /
                                              placement.lanes,
                                      top:
                                          (placement.topMinute - firstMinute) *
                                              scale +
                                          1,
                                      width: (column - 4) / placement.lanes - 3,
                                      height: math.max(
                                        48,
                                        (placement.bottomMinute -
                                                    placement.topMinute) *
                                                scale -
                                            2,
                                      ),
                                      child: reveal(
                                        _event(context, placement, scale),
                                        i,
                                        [placement.slice.entry],
                                      ),
                                    ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupButton(
    BuildContext context,
    String title,
    VoidCallback onTap, {
    Key? key,
    String? semanticLabel,
  }) => TextButton(
    key: key,
    onPressed: onTap,
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.all(8),
      backgroundColor: const Color(0xFFEDF0EF),
      foregroundColor: SeraColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: Text(
      title,
      semanticsLabel: semanticLabel,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget _event(
    BuildContext context,
    CalendarSlicePlacement placement,
    double scale,
  ) {
    final slice = placement.slice;
    final entry = slice.entry;
    final textScale = MediaQuery.textScalerOf(context);
    final week = days.length > 1;
    final tall =
        (placement.bottomMinute - placement.topMinute) * scale >=
        16 + textScale.scale(13) * 2 * 1.35 + textScale.scale(12) * 1.3;
    final crossDay = dateOnly(entry.start) != dateOnly(entry.end);
    final nextDay =
        calendarDay(dateOnly(entry.start), 1) == dateOnly(entry.end);
    final range = !crossDay
        ? formatRange(entry.start, entry.end)
        : nextDay
        ? '${slice.continuesBefore ? '昨日' : ''}${formatTime(entry.start)}–${slice.continuesBefore ? '' : '次日'}${formatTime(entry.end)}'
        : formatEntryRange(entry, showDate: true);
    return Semantics(
      button: true,
      label: '${entry.title}，${formatEntryRange(entry, showDate: true)}',
      excludeSemantics: true,
      onTap: () => _open(context, entry),
      child: Tooltip(
        message: '${entry.title}\n${formatEntryRange(entry, showDate: true)}',
        excludeFromSemantics: true,
        child: Material(
          color: entry.isTask ? SeraColors.mint : const Color(0xFFEDF0EF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: entry.isTask
                  ? SeraColors.brand.withValues(alpha: .3)
                  : SeraColors.line,
            ),
          ),
          child: InkWell(
            key: ValueKey('calendar-event:${entry.id}:${slice.startMinute}'),
            onTap: () => _open(context, entry),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.all(week ? 6 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: tall ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                        color: entry.isTask ? SeraColors.brand : SeraColors.ink,
                      ),
                    ),
                  ),
                  if (week || tall || crossDay)
                    Text(
                      week
                          ? slice.continuesBefore
                                ? '延续'
                                : formatTime(entry.start)
                          : range,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: SeraColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
