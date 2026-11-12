import 'dart:async';

import 'package:flutter/material.dart';

import 'sera_motion.dart';

/// A page owns this request so a detail push, rebuild or overlap change does not
/// repeat the initial reveal of an object the user has just saved.
class SeraRevealRequest {
  bool _revealed = false;
}

class SeraRevealOnce extends StatefulWidget {
  const SeraRevealOnce({super.key, this.request, required this.child});
  final SeraRevealRequest? request;
  final Widget child;

  @override
  State<SeraRevealOnce> createState() => _SeraRevealOnceState();
}

class _SeraRevealOnceState extends State<SeraRevealOnce> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    if (request != null && !request._revealed && !_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted ||
            !identical(widget.request, request) ||
            request._revealed ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        request._revealed = true;
        unawaited(
          Scrollable.ensureVisible(
            context,
            alignment: .35,
            duration: SeraMotion.scrollDuration(context),
            curve: SeraMotion.curve,
          ),
        );
      });
    }
    return widget.child;
  }
}
