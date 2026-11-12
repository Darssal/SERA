/// Native sync also wakes when the app resumes; periodic sync remains a fallback.
Stream<void> get networkRestored => const Stream<void>.empty();
