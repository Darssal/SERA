import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Motion describes the destination's hierarchy, never a business operation.
enum SeraRouteMotion { primary, detail, editor, step, none }

abstract final class SeraMotion {
  static const primaryDuration = Duration(milliseconds: 160);
  static const routeDuration = Duration(milliseconds: 220);
  static const editorDuration = Duration(milliseconds: 240);
  static const stepDuration = Duration(milliseconds: 200);
  static const reverseDuration = Duration(milliseconds: 160);
  static const curve = Curves.easeOutCubic;
  static const reverseCurve = Curves.easeInCubic;

  static const _accountPaths = {
    '/login',
    '/register',
    '/account',
    '/verify-email',
    '/forgot-password',
    '/reset-password',
    '/phone-login',
    '/bind-phone',
    '/phone-identity',
    '/phone-email',
  };

  static String _screen(Uri uri) {
    final path = uri.path;
    final match = RegExp(r'^/(\d+)(?:-|$)').firstMatch(path);
    return match == null ? path : match[1]!.padLeft(2, '0');
  }

  static SeraRouteMotion motionFor(Uri uri) {
    if (uri.path == '/community') return SeraRouteMotion.primary;
    if (uri.path == '/community/compose') return SeraRouteMotion.editor;
    if (_accountPaths.contains(uri.path)) return SeraRouteMotion.none;
    final screen = _screen(uri);
    if (const {'04', '12', '13', '14', '17', '20', '37'}.contains(screen)) {
      return SeraRouteMotion.primary;
    }
    if (const {'09', '16', '19'}.contains(screen)) {
      return SeraRouteMotion.editor;
    }
    // These are full-page design states, not transparent modal routes.
    if (const {'43', '44', '45', '50'}.contains(screen)) {
      return SeraRouteMotion.editor;
    }
    if (const {'07', '39', '49', '51'}.contains(screen)) {
      return SeraRouteMotion.primary;
    }
    if (const {
      '01',
      '02',
      '03',
      '05',
      '06',
      '08',
      '10',
      '11',
      '22',
      '23',
      '52',
      '55',
    }.contains(screen)) {
      return SeraRouteMotion.step;
    }
    return SeraRouteMotion.detail;
  }

  /// Observe MediaQuery so toggling the system preference also updates an
  /// in-flight transition. reduceMotion is a separate engine flag on iOS.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

  static AnimationStyle dialogStyle(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: primaryDuration,
          reverseDuration: reverseDuration,
          curve: curve,
          reverseCurve: reverseCurve,
        );

  static AnimationStyle sheetStyle(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: editorDuration,
          reverseDuration: reverseDuration,
          curve: curve,
          reverseCurve: reverseCurve,
        );

  static Duration scrollDuration(BuildContext context) =>
      reduced(context) ? Duration.zero : primaryDuration;

  /// Keep the native picker content, validation, entry modes and result type.
  /// The convenience showDatePicker API has no animationStyle in this SDK.
  static Future<DateTime?> pickDate({
    required BuildContext context,
    required DateTime firstDate,
    required DateTime lastDate,
    DateTime? initialDate,
    DateTime? currentDate,
    String? helpText,
    String? cancelText,
    String? confirmText,
    DatePickerEntryMode initialEntryMode = DatePickerEntryMode.calendar,
    SelectableDayPredicate? selectableDayPredicate,
  }) {
    final first = DateUtils.dateOnly(firstDate);
    final last = DateUtils.dateOnly(lastDate);
    assert(!last.isBefore(first), 'lastDate must not precede firstDate');
    final initial = initialDate == null
        ? null
        : DateUtils.dateOnly(initialDate);
    // An imported existing date can lie outside the UI's default year window.
    // Keep that date visible/selectable, without clamping or saving a new date
    // merely because its picker was opened. Confirmation remains explicit.
    final effectiveFirst = initial != null && initial.isBefore(first)
        ? initial
        : first;
    final effectiveLast = initial != null && initial.isAfter(last)
        ? initial
        : last;
    return showDialog<DateTime>(
      context: context,
      animationStyle: dialogStyle(context),
      builder: (_) => DatePickerDialog(
        initialDate: initial,
        firstDate: effectiveFirst,
        lastDate: effectiveLast,
        currentDate: currentDate,
        helpText: helpText,
        cancelText: cancelText,
        confirmText: confirmText,
        initialEntryMode: initialEntryMode,
        selectableDayPredicate: selectableDayPredicate,
      ),
    );
  }

  static Future<TimeOfDay?> pickTime({
    required BuildContext context,
    required TimeOfDay initialTime,
    String? helpText,
    String? cancelText,
    String? confirmText,
    TimePickerEntryMode initialEntryMode = TimePickerEntryMode.dial,
  }) => showDialog<TimeOfDay>(
    context: context,
    animationStyle: dialogStyle(context),
    builder: (_) => _SeraPickerViewport(
      child: TimePickerDialog(
        initialTime: initialTime,
        helpText: helpText,
        cancelText: cancelText,
        confirmText: confirmText,
        initialEntryMode: initialEntryMode,
      ),
    ),
  );

  /// Keep GoRouter's imperative instance key as well as the semantic identity.
  /// A /:screen match alone cannot distinguish two objects or two screen IDs.
  /// Ordinary repository notifications and keystrokes do not change this key.
  static LocalKey routeKey({required LocalKey routerKey, required Uri uri}) {
    final screen = _screen(uri);
    final query = uri.queryParameters;
    final identity = <String, String>{
      for (final field in const [
        'taskId',
        'eventId',
        'draftId',
        'goalId',
        'sessionId',
      ])
        if (query[field] case final String value) field: value,
    };
    if (const {'05', '06'}.contains(screen)) {
      for (final field in const ['new', 'prompt']) {
        if (query[field] case final String value) identity[field] = value;
      }
    }
    if ((screen == '19' &&
            query['taskId'] == null &&
            query['draftId'] == null) ||
        (screen == '16' && query['eventId'] == null)) {
      for (final field in const [
        'title',
        'notes',
        'estimatedMinutes',
        'dueAt',
        'dueDate',
        'start',
        'end',
        'fromAi',
        'manual',
        'fromEvent',
        'requiresTimeConfirmation',
      ]) {
        if (query[field] case final String value) identity[field] = value;
      }
    }
    if (const {
      '/verify-email',
      '/reset-password',
      '/phone-email',
    }.contains(screen)) {
      if (query['token'] case final String value) identity['token'] = value;
    }
    return _SeraPageKey(routerKey, screen, identity);
  }

  static CustomTransitionPage<T> page<T>({
    required BuildContext context,
    required GoRouterState state,
    required Widget child,
  }) {
    final type = motionFor(state.uri);
    final immediate = type == SeraRouteMotion.none || reduced(context);
    final duration = switch (type) {
      SeraRouteMotion.primary => primaryDuration,
      SeraRouteMotion.detail => routeDuration,
      SeraRouteMotion.editor => editorDuration,
      SeraRouteMotion.step => stepDuration,
      SeraRouteMotion.none => Duration.zero,
    };
    // Always use the same Page class. An accessibility toggle must not remount
    // a form or replay a page's automatic startup work.
    return CustomTransitionPage<T>(
      key: routeKey(routerKey: state.pageKey, uri: state.uri),
      name: state.name ?? state.path,
      maintainState: true,
      transitionDuration: immediate ? Duration.zero : duration,
      reverseTransitionDuration: immediate ? Duration.zero : reverseDuration,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          SeraRouteTransition(animation: animation, type: type, child: child),
    );
  }
}

/// Give the native dialog room to lay out before scrolling its complete card
/// above the keyboard. The SDK input picker otherwise combines a 196 px
/// minimum target with an internal 216 px minimum when the viewport is short.
/// Keep this structure for all heights so keyboard changes retain its State.
class _SeraPickerViewport extends StatelessWidget {
  const _SeraPickerViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) => SingleChildScrollView(
      // Empty space still belongs to the route's dismissible ModalBarrier.
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: viewport.hasBoundedHeight ? viewport.maxHeight : 0,
        ),
        // Dialog itself applies viewInsets once and retains native semantics.
        child: child,
      ),
    ),
  );
}

/// Holds query identity privately; diagnostic keys must not print prompts,
/// email credentials, or recovery tokens. Map order does not affect equality.
class _SeraPageKey extends LocalKey {
  _SeraPageKey(this.routerKey, this.screen, Map<String, String> identity)
    : _identity = Map.unmodifiable(identity);

  final LocalKey routerKey;
  final String screen;
  final Map<String, String> _identity;

  @override
  bool operator ==(Object other) =>
      other is _SeraPageKey &&
      other.routerKey == routerKey &&
      other.screen == screen &&
      mapEquals(other._identity, _identity);

  @override
  int get hashCode => Object.hash(
    routerKey,
    screen,
    Object.hashAllUnordered(
      _identity.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() => '[SeraPage:$screen]';
}

/// Apply compact motion to all disclosures, including existing raw
/// ExpansionTiles, without replacing their form children or state.
class SeraMotionScope extends StatefulWidget {
  const SeraMotionScope({super.key, required this.child});
  final Widget child;

  @override
  State<SeraMotionScope> createState() => _SeraMotionScopeState();
}

class _SeraMotionScopeState extends State<SeraMotionScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExpansionTileTheme(
    data: ExpansionTileTheme.of(context)
        .copyWith(expansionAnimationStyle: SeraMotion.dialogStyle(context)),
    child: widget.child,
  );
}

class SeraRouteTransition extends StatefulWidget {
  const SeraRouteTransition({
    super.key,
    required this.animation,
    required this.type,
    required this.child,
  });

  final Animation<double> animation;
  final SeraRouteMotion type;
  final Widget child;

  @override
  State<SeraRouteTransition> createState() => _SeraRouteTransitionState();
}

/// Resize a small status banner without switching or duplicating the router
/// subtree below it. Initial state is immediate; only later visibility changes
/// animate. This is deliberately separate from forms and business lifecycles.
class SeraBannerTransition extends StatefulWidget {
  const SeraBannerTransition({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;

  @override
  State<SeraBannerTransition> createState() => _SeraBannerTransitionState();
}

class _SeraBannerTransitionState extends State<SeraBannerTransition>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SeraMotion.primaryDuration,
    reverseDuration: SeraMotion.reverseDuration,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _size = _controller.drive(
    CurveTween(curve: SeraMotion.curve),
  );
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _readMotionPreference() {
    _reduced = SeraMotion.reduced(context);
    if (_reduced) _controller.value = widget.visible ? 1 : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readMotionPreference();
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (mounted) setState(_readMotionPreference);
  }

  @override
  void didUpdateWidget(covariant SeraBannerTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (_reduced) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _size,
    alignment: Alignment.topCenter,
    child: IgnorePointer(
      ignoring: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: ExcludeFocus(excluding: !widget.visible, child: widget.child),
      ),
    ),
  );
}

class _SeraRouteTransitionState extends State<SeraRouteTransition>
    with WidgetsBindingObserver {
  bool _hasKeyboardDecision = false;
  bool _keyboardOpen = false;
  bool _suppressTranslation = false;
  bool _skipCurrentTransition = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.animation.addStatusListener(_animationStatusChanged);
  }

  void _animationStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      // The keyboard may have closed during entry. At the endpoint changing
      // the next transition's decision cannot cause a visible position jump.
      _suppressTranslation = _keyboardOpen;
      _skipCurrentTransition = false;
    }
  }

  @override
  void didUpdateWidget(covariant SeraRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_animationStatusChanged);
      widget.animation.addStatusListener(_animationStatusChanged);
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    // MediaQuery has no reduceMotion field, so its inherited notifications
    // alone cannot observe a change to that separate engine preference.
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (!_hasKeyboardDecision ||
        widget.animation.status == AnimationStatus.completed ||
        widget.animation.status == AnimationStatus.dismissed) {
      _suppressTranslation = _keyboardOpen;
      _hasKeyboardDecision = true;
    }
    // A keyboard closing halfway through entry must not suddenly introduce
    // an offset. Freeze that decision for the running transition.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.animation.removeStatusListener(_animationStatusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = widget.animation;
    final type = widget.type;
    final reducedRequested =
        type == SeraRouteMotion.none || SeraMotion.reduced(context);
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    return AnimatedBuilder(
      animation: animation,
      child: widget.child,
      builder: (context, child) {
        final transitioning =
            animation.status == AnimationStatus.forward ||
            animation.status == AnimationStatus.reverse;
        if (transitioning && reducedRequested) {
          _skipCurrentTransition = true;
        }
        // Enabling reduced motion finishes this visual transition. Turning
        // it off again before the controller settles must not resurrect an
        // exiting page, move an already presented form or re-lock touches.
        final immediate =
            reducedRequested || (transitioning && _skipCurrentTransition);
        final moving =
            !immediate && animation.status != AnimationStatus.completed;
        // One value mapping in both directions avoids a discontinuity when
        // the user presses back before the entering transition has finished.
        final progress = immediate
            ? 1.0
            : SeraMotion.curve.transform(animation.value);
        final distance = _suppressTranslation
            ? Offset.zero
            : switch (type) {
                SeraRouteMotion.detail => const Offset(18, 0),
                SeraRouteMotion.editor => const Offset(0, 16),
                SeraRouteMotion.step => const Offset(12, 0),
                _ => Offset.zero,
              };
        // The constant child keeps forms, timers and request startup outside
        // animation rebuilds. Only the current settled route accepts touches;
        // the OS/browser back action can still interrupt a transition.
        // A route installed before reduced motion was enabled can still have
        // a nonzero internal reverse controller. Hide its exiting subtree
        // immediately, including hit testing, while Navigator cleans it up.
        return Offstage(
          offstage: immediate && animation.status == AnimationStatus.reverse,
          child: AbsorbPointer(
            absorbing: !isCurrent || moving,
            child: ExcludeSemantics(
              excluding: !isCurrent,
              child: ClipRect(
                child: Opacity(
                  opacity: progress,
                  child: Transform.translate(
                    offset: distance * (1 - progress),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
