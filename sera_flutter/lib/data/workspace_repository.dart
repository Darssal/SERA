import '../domain/models.dart';

/// A single source of truth; implementations must reject stale revisions.
abstract interface class WorkspaceRepository {
  String get mode;
  Future<Workspace?> load();
  Future<Workspace> save(Workspace workspace, {required int expectedRevision});
  Future<void> clear();
}

class RepositoryException implements Exception {
  const RepositoryException(
    this.message, {
    this.conflict = false,
    this.offline = false,
    this.details = const {},
  });
  final String message;
  final bool conflict, offline;
  final Json details;
  @override
  String toString() => message;
}

abstract interface class SynchronizingWorkspaceRepository {
  int get pendingCount;
  bool get isOffline;
  Json? get syncConflict;
  Future<Workspace?> synchronize();
  Future<Workspace?> resolveConflict({required bool keepLocal});
}

/// A durable local projection that can be read without waiting for transport.
/// Notifications carry no snapshot: consumers read the latest committed state.
abstract interface class LocalWorkspaceCache {
  Future<Workspace?> loadLocal();
  Stream<void> get localChanges;
}
