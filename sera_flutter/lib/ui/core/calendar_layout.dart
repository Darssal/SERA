import '../../domain/models.dart';

/// A display-only slice. The original event and its exclusive end stay intact.
class CalendarDaySlice {
  const CalendarDaySlice(
    this.entry,
    this.startMinute,
    this.endMinute, {
    required this.continuesBefore,
    required this.continuesAfter,
  });
  final CalendarEntry entry;
  final int startMinute, endMinute;
  final bool continuesBefore, continuesAfter;
}

List<CalendarDaySlice> calendarDaySlices(
  Iterable<CalendarEntry> entries,
  DateTime day,
  String zone,
) {
  final start = dateOnly(inTimeZone(day, zone, wallClock: true));
  final end = calendarDay(start, 1);
  final slices = <CalendarDaySlice>[];
  for (final entry in entries) {
    final localStart = inTimeZone(entry.start, zone, wallClock: true);
    final localEnd = inTimeZone(entry.end, zone, wallClock: true);
    if (entry.allDay || !localStart.isBefore(end) || !localEnd.isAfter(start)) {
      continue;
    }
    final from = localStart.isBefore(start)
        ? 0
        : localStart.difference(start).inMinutes;
    final to = !localEnd.isBefore(end)
        ? end.difference(start).inMinutes
        : (localEnd.difference(start).inMicroseconds /
                  Duration.microsecondsPerMinute)
              .ceil();
    if (to <= from) continue;
    slices.add(
      CalendarDaySlice(
        entry,
        from,
        to,
        continuesBefore: localStart.isBefore(start),
        continuesAfter: localEnd.isAfter(end),
      ),
    );
  }
  slices.sort((a, b) {
    final startOrder = a.startMinute.compareTo(b.startMinute);
    if (startOrder != 0) return startOrder;
    final endOrder = b.endMinute.compareTo(a.endMinute);
    return endOrder != 0 ? endOrder : a.entry.id.compareTo(b.entry.id);
  });
  return slices;
}

class CalendarSlicePlacement {
  const CalendarSlicePlacement(
    this.slice,
    this.lane,
    this.lanes,
    this.topMinute,
    this.bottomMinute,
  );
  final CalendarDaySlice slice;
  final int lane, lanes;
  final double topMinute, bottomMinute;
}

class CalendarOverlapGroup {
  const CalendarOverlapGroup(
    this.placements,
    this.topMinute,
    this.bottomMinute,
  );
  final List<CalendarSlicePlacement> placements;
  final double topMinute, bottomMinute;
}

/// Group visual collisions as well as real overlaps, so short events retain a
/// tappable height without covering a later event. Packing never changes data.
List<CalendarOverlapGroup> calendarOverlapGroups(
  List<CalendarDaySlice> slices, {
  required double scale,
  double minHeight = 50,
}) {
  final groups = <CalendarOverlapGroup>[];
  var pending = <({CalendarDaySlice slice, double top, double bottom})>[];
  double groupEnd = -1;
  void flush() {
    if (pending.isEmpty) return;
    final ends = <double>[];
    final assigned =
        <({CalendarDaySlice slice, int lane, double top, double bottom})>[];
    for (final item in pending) {
      var lane = ends.indexWhere((end) => end <= item.top);
      if (lane < 0) {
        lane = ends.length;
        ends.add(item.bottom);
      } else {
        ends[lane] = item.bottom;
      }
      assigned.add((
        slice: item.slice,
        lane: lane,
        top: item.top,
        bottom: item.bottom,
      ));
    }
    groups.add(
      CalendarOverlapGroup(
        [
          for (final item in assigned)
            CalendarSlicePlacement(
              item.slice,
              item.lane,
              ends.length,
              item.top,
              item.bottom,
            ),
        ],
        pending.first.top,
        groupEnd,
      ),
    );
    pending = [];
  }

  for (final slice in slices) {
    final minMinutes = minHeight / scale;
    final bottom = slice.endMinute.toDouble();
    final top = slice.startMinute.toDouble();
    final displayEnd = (top + minMinutes).clamp(bottom, double.infinity);
    if (top >= groupEnd) flush();
    pending.add((slice: slice, top: top, bottom: displayEnd));
    if (displayEnd > groupEnd || pending.length == 1) groupEnd = displayEnd;
  }
  flush();
  return groups;
}
