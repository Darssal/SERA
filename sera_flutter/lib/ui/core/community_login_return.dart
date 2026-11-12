/// Only vetted local community/management destinations survive optional sign-in.
/// An external URL or arbitrary application route can never become a redirect.
String? communityLoginReturn(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.path != value) {
    return null;
  }
  if (const [
    '/community',
    '/community/compose',
    '/community/manage',
    '/admin',
    '/admin/overview',
    '/admin/posts',
    '/admin/publish',
    '/admin/team',
    '/admin/users',
    '/admin/audit',
    '/admin/status',
  ].contains(value)) {
    return value;
  }
  return RegExp(r'^/community/post/[A-Za-z0-9_-]{1,100}$').hasMatch(value)
      ? value
      : null;
}

String communityAuthLink(String path, String? returnTo) {
  final destination = communityLoginReturn(returnTo);
  return destination == null
      ? path
      : Uri(path: path, queryParameters: {'returnTo': destination}).toString();
}
