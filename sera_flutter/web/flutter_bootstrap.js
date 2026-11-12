{{flutter_js}}
{{flutter_build_config}}
// SERA owns its Service Worker and authenticated Push lifecycle.
Promise.resolve(window.seraOfflineReady).then(() => _flutter.loader.load());
