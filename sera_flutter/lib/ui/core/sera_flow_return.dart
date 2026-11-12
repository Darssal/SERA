import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Business surfaces that can continue a journey after its form or flow ends.
/// Drafts are opt-in: a committed draft must not become a completion target.
bool isSeraFlowReturnPage(Uri uri) => const {
  '04',
  '12',
  '13',
  '14',
  '15',
  '17',
  '18',
  '20',
  '21',
  '30',
  '34',
  '35',
  // Legacy empty/loading routes display the Today home once ready.
  '37',
  '49',
}.contains(seraScreenId(uri));

String seraScreenId(Uri uri) =>
    uri.pathSegments.firstOrNull?.split('-').first.padLeft(2, '0') ?? '';

/// An explicit optional view action confirms saves outside the origin's active
/// filter/date, without sending every user through a compulsory detail page.
void showSeraSavedFeedback({
  required ScaffoldMessengerState messenger,
  required GoRouter router,
  required String message,
  required String location,
  required bool Function() canOpen,
}) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: '查看',
        onPressed: () {
          if (messenger.mounted && canOpen()) router.push(location);
        },
      ),
    ),
  );
}

Uri _visibleUri(RouteMatchList matches) {
  final last = matches.last;
  return last is ImperativeRouteMatch ? last.matches.uri : matches.uri;
}

/// Finds an existing origin, retaining its page keys and in-memory UI state.
/// Only the current router stack is inspected; no arbitrary return URL or
/// persisted snapshot can restore a page from another account or app session.
RouteMatchList? findSeraFlowReturn(
  BuildContext context, {
  bool Function(Uri)? accepts,
}) {
  var matches = GoRouter.of(context).routerDelegate.currentConfiguration;
  if (matches.isEmpty) return null;
  matches = matches.remove(matches.last);
  while (matches.isNotEmpty) {
    final uri = _visibleUri(matches);
    if ((accepts ?? isSeraFlowReturnPage)(uri)) return matches;
    matches = matches.remove(matches.last);
  }
  return null;
}

/// Completes a successful operation without adding another success/detail page.
/// Call only after the caller has checked ownership and successful persistence.
/// A cold deep link has no origin and uses the supplied business fallback.
bool finishSeraFlow(
  BuildContext context, {
  required String fallback,
  bool Function(Uri)? accepts,
}) {
  final router = GoRouter.of(context);
  final previous = router.routerDelegate.currentConfiguration;
  final origin = findSeraFlowReturn(context, accepts: accepts);
  FocusManager.instance.primaryFocus?.unfocus();
  Router.neglect(context, () {
    if (origin == null) {
      router.go(fallback);
    } else {
      router.restore(origin);
    }
  });
  // restore() retains the origin's State, while GoRouter's ordinary go/restore
  // does not settle the Futures returned by removed push() calls. Release
  // those callers only after removal, so they can reset loading/focus state.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final retained = router.routerDelegate.currentConfiguration.matches;
    for (final match in previous.matches.whereType<ImperativeRouteMatch>()) {
      if (!retained.contains(match) && !match.completer.isCompleted) {
        match.complete();
      }
    }
  });
  return origin != null;
}
