import 'dart:async';

/// Deliberately excludes account identifiers, credentials and user content.
class AccountEvent {
  const AccountEvent({required this.apiBaseUrl, required this.loggedIn});
  final String apiBaseUrl;
  final bool loggedIn;

  Map<String, Object> toJson() => {
    'apiBaseUrl': apiBaseUrl,
    'event': loggedIn ? 'logged-in' : 'logged-out',
  };

  static AccountEvent? fromJson(Object? value) {
    if (value is! Map ||
        value['apiBaseUrl'] is! String ||
        !const ['logged-in', 'logged-out'].contains(value['event'])) {
      return null;
    }
    return AccountEvent(
      apiBaseUrl: value['apiBaseUrl'] as String,
      loggedIn: value['event'] == 'logged-in',
    );
  }
}

abstract interface class AccountEventChannel {
  Stream<AccountEvent> get events;
  void publish(AccountEvent event);
  void dispose();
}
