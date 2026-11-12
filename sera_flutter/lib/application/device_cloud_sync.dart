import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/auth_repository.dart';
import '../data/device_cloud_merge.dart';
import '../data/device_workspace_repository.dart';
import '../data/workspace_repository.dart';
import '../domain/change_history.dart';
import '../domain/models.dart';
import 'sera_controller.dart';

/// A device copy remains independent of account caches. Only an explicit
/// sign-in/import entry point invokes synchronize; session restoration merely
/// inspects the receipt and never starts an import.
class DeviceCloudSync extends ChangeNotifier {
  DeviceCloudSync({
    required this.device,
    required this.controller,
    required this.auth,
    required this.isCurrent,
  }) : _owner = auth.sessionOwner,
       _accountId = auth.session?.user.id {
    unawaited(refreshPending());
  }

  final DeviceWorkspaceRepository device;
  final SeraController controller;
  final AuthRepository auth;
  final bool Function() isCurrent;
  final Object _owner;
  final String? _accountId;
  bool _disposed = false, _hasPending = false, _busy = false;
  int _conflictCount = 0;
  String? _message;
  bool get hasPending => _hasPending;
  bool get busy => _busy;
  bool get hasConflicts => _conflictCount > 0;
  int get conflictCount => _conflictCount;
  String? get message => _message;

  bool get _current =>
      !_disposed &&
      isCurrent() &&
      auth.signedIn &&
      _accountId != null &&
      auth.session?.user.id == _accountId &&
      controller.accountId == _accountId &&
      auth.sessionOwner == _owner;

  void _notify() {
    if (_current) notifyListeners();
  }

  bool get _pendingUpload {
    final repository = controller.repository;
    if (repository is! SynchronizingWorkspaceRepository) return false;
    final synchronizing = repository as SynchronizingWorkspaceRepository;
    return synchronizing.pendingCount > 0 || synchronizing.syncConflict != null;
  }

  String _contentDigest(Workspace value) => historyEntityDigest(
    value.toJson()
      ..remove('revision')
      ..remove('entityVersions'),
  );

  Future<void> _validateMerge(Workspace before, Workspace candidate) async {
    // The local CAS counter deliberately differs from the server revision.
    // Read the actual server projection rather than treating a local revision
    // as an optimistic server-write token.
    final state = await auth.authenticatedRequest('GET', '/api/v1/sync/state');
    if (!_current) return;
    final raw = state['workspace'];
    if (raw is! Map) {
      throw const RepositoryException('云端记录尚未就绪，请重试同步。');
    }
    final server = Workspace.fromJson(Map<String, dynamic>.from(raw));
    if (_pendingUpload || _contentDigest(before) != _contentDigest(server)) {
      throw const RepositoryException('云端记录已更新，请重试同步。', conflict: true);
    }
    final result = await auth.authenticatedRequest(
      'POST',
      '/api/v1/workspace/validate-merge',
      data: {
        'workspace': candidate.copyWith(revision: server.revision).toJson(),
        'expectedRevision': server.revision,
      },
    );
    if (!_current) return;
    if (result['valid'] != true || result['revision'] != server.revision) {
      throw const RepositoryException('云端未确认这次合并，本机记录仍保留。');
    }
  }

  Future<bool> _deviceChangedSince(String fingerprint) async {
    final latest = await device.load();
    if (!_current) return false;
    return latest != null &&
        deviceCloudHasContent(latest) &&
        deviceCloudFingerprint(latest) != fingerprint;
  }

  Future<void> refreshPending() async {
    if (!_current || _busy) return;
    try {
      final local = await device.load();
      if (!_current || _busy) return;
      final receipt = await device.cloudReceipt(_accountId!);
      if (!_current || _busy) return;
      _hasPending =
          _pendingUpload ||
          local != null &&
              deviceCloudHasContent(local) &&
              (receipt?['accountId'] != _accountId ||
                  receipt?['schemaVersion'] != 1 ||
                  deviceCloudFingerprint(local) !=
                      receipt?['inputFingerprint']);
      _notify();
    } catch (_) {
      if (!_current || _busy) return;
      _message = '暂时无法读取本机记录，请重试。';
      _notify();
    }
  }

  Future<void> synchronize({bool? preferDevice}) async {
    if (!_current || _busy) return;
    _busy = true;
    _message = null;
    _conflictCount = 0;
    _notify();
    var locallyMerged = false;
    try {
      final local = await device.load();
      if (!_current) return;
      if (local == null || !deviceCloudHasContent(local)) {
        _hasPending = false;
        return;
      }
      final receipt = await device.cloudReceipt(_accountId!);
      if (!_current) return;
      final fingerprint = deviceCloudFingerprint(local);
      // A response-lost retry must flush the existing account journal, rather
      // than creating new IDs or repeating the import/history mutation.
      if (receipt?['accountId'] != _accountId ||
          receipt?['schemaVersion'] != 1 ||
          receipt?['inputFingerprint'] != fingerprint) {
        _hasPending = true;
        // Refresh before computing conflicts; OfflineWorkspaceRepository keeps
        // its durable local projection when transport is unavailable.
        await controller.refresh();
        if (!_current) return;
        final before = controller.data;
        final baseDigest = historyEntityDigest(before.toJson());
        final merge = mergeDeviceCloud(
          device: local,
          cloud: before,
          accountId: _accountId,
          previousReceipt: receipt,
          preferDevice: preferDevice,
        );
        if (merge.conflicts.isNotEmpty && preferDevice == null) {
          _conflictCount = merge.conflicts.length;
          _message = '有 $_conflictCount 项记录存在差异，请选择保留哪一份。';
          return;
        }
        if (merge.changed) {
          await _validateMerge(before, merge.workspace);
          if (!_current) return;
        }
        await controller.mergeDeviceRecords((current) {
          if (historyEntityDigest(current.toJson()) != baseDigest) {
            throw const RepositoryException('记录已有更新，请重试同步。', conflict: true);
          }
          return merge.changed ? merge.workspace : null;
        }, isCurrent: () => _current);
        if (!_current) return;
        // Store only after the account's durable save. A receipt is not proof
        // of a remote acknowledgement, and the original device copy is kept.
        locallyMerged = true;
        await device.saveCloudReceipt(_accountId, merge.receipt);
        if (!_current) return;
      } else {
        locallyMerged = true;
      }
      final repository = controller.repository;
      if (repository is SynchronizingWorkspaceRepository) {
        final synchronizing = repository as SynchronizingWorkspaceRepository;
        await synchronizing.synchronize();
        if (!_current) return;
        if (synchronizing.pendingCount > 0 ||
            synchronizing.isOffline ||
            synchronizing.syncConflict != null) {
          _hasPending = true;
          _message = '本机已合并，仍有记录待上传。';
          return;
        }
        await controller.refresh();
        if (!_current) return;
        final newDeviceContent = await _deviceChangedSince(fingerprint);
        if (!_current) return;
        _hasPending = _pendingUpload || newDeviceContent;
        if (_hasPending) {
          _message = newDeviceContent ? '已有新的本机记录待同步。' : '本机已合并，仍有记录待上传。';
          return;
        }
        _message = '本机记录已同步到云端。';
      } else {
        // Custom/local repositories have no remote acknowledgement contract.
        _hasPending = await _deviceChangedSince(fingerprint);
        if (!_current) return;
        _message = _hasPending ? '已有新的本机记录待同步。' : '本机记录已合并。';
      }
    } catch (error) {
      if (!_current) return;
      _hasPending = true;
      _message = locallyMerged
          ? '本机已合并，云端同步待重试。'
          : error is RepositoryException
          ? error.message
          : '同步未完成，本机记录仍保留。';
    } finally {
      if (_current) {
        _busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
