import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'sera_theme.dart';

/// Tasks and goals share one primary planning surface and retain their links.
class SeraPlanSwitcher extends StatelessWidget {
  const SeraPlanSwitcher({super.key, required this.goals});

  final bool goals;

  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
    key: const ValueKey('plan-switcher'),
    expandedInsets: EdgeInsets.zero,
    segments: const [
      ButtonSegment(value: false, label: Text('任务')),
      ButtonSegment(value: true, label: Text('目标')),
    ],
    selected: {goals},
    showSelectedIcon: false,
    onSelectionChanged: (selection) {
      final nextGoals = selection.single;
      if (nextGoals == goals) return;
      FocusManager.instance.primaryFocus?.unfocus();
      context.go(nextGoals ? '/20' : '/17?filter=todo');
    },
    style: SegmentedButton.styleFrom(
      minimumSize: const Size(88, 48),
      selectedBackgroundColor: SeraColors.brand,
      selectedForegroundColor: Colors.white,
    ),
  );
}
