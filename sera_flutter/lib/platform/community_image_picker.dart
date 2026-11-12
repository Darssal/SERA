import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/auth_storage.dart';
import '../data/workspace_repository.dart';
import '../domain/community_models.dart';

class CommunityImageSelection {
  const CommunityImageSelection({
    required this.id,
    required this.bytes,
    required this.name,
    required this.mimeType,
  });
  final String id, name, mimeType;
  final Uint8List bytes;
}

/// Files stay in the current compose session; no filesystem path is persisted.
Future<List<CommunityImageSelection>> pickCommunityImages({
  required String owner,
  int limit = 3,
  Future<List<XFile>> Function(int limit)? pickImages,
  AuthSessionStorage? storage,
}) async {
  if (limit < 1) return const [];
  final maximum = min(limit, 3);
  try {
    final marker = jsonEncode({'owner': owner, 'operation': _selectionId()});
    final store =
        storage ?? PreferencesSessionStorage(SharedPreferencesAsync());
    if (_android) {
      await store.write(_pendingKey, marker);
      _activeMarkers.add(marker);
    }
    try {
      final files = await (pickImages != null
          ? pickImages(maximum)
          : ImagePicker().pickMultiImage(
              limit: maximum,
              maxWidth: 1600,
              maxHeight: 1600,
              imageQuality: 85,
              requestFullMetadata: false,
            ));
      return await _selections(files, maximum);
    } finally {
      _activeMarkers.remove(marker);
      if (_android) await _clearMarker(store, marker);
    }
  } on RepositoryException {
    rethrow;
  } on PlatformException catch (error) {
    throw RepositoryException(
      error.code == 'photo_access_denied' || error.code == 'permission_denied'
          ? '无法访问照片，请允许选择照片后重试。'
          : '暂时无法打开照片，请重试。',
    );
  } catch (_) {
    throw const RepositoryException('图片读取失败，请重新选择。');
  }
}

const _pendingKey = 'sera.community.image-picker.pending.v1';
final _activeMarkers = <String>{};
bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> _clearMarker(AuthSessionStorage store, String marker) async {
  if (await store.read(_pendingKey) == marker) await store.delete(_pendingKey);
}

/// Only a restored session matching the pending selection can receive its files.
/// The compose screen also guards its owner after this await and never publishes automatically.
Future<List<CommunityImageSelection>> recoverCommunityImages(
  String owner, {
  int limit = 3,
  Future<LostDataResponse> Function()? retrieveLostData,
  AuthSessionStorage? storage,
}) async {
  if (!_android) return const [];
  final store = storage ?? PreferencesSessionStorage(SharedPreferencesAsync());
  String? marker;
  try {
    marker = await store.read(_pendingKey);
    if (_activeMarkers.contains(marker)) return const [];
    final response = await (retrieveLostData != null
        ? retrieveLostData()
        : ImagePicker().retrieveLostData());
    if (marker == null || await store.read(_pendingKey) != marker) {
      return const [];
    }
    final saved = jsonDecode(marker);
    if (saved is! Map || saved['owner'] != owner || limit < 1) return const [];
    if (response.isEmpty) return const [];
    if (response.exception != null) throw response.exception!;
    return await _selections(response.files ?? const [], min(limit, 3));
  } on RepositoryException {
    rethrow;
  } catch (_) {
    throw const RepositoryException('上次选择的图片未能恢复，请重新选择。');
  } finally {
    if (marker != null && !_activeMarkers.contains(marker)) {
      await _clearMarker(store, marker);
    }
  }
}

String _selectionId() {
  final random = Random.secure();
  return 'image-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

Future<List<CommunityImageSelection>> _selections(
  List<XFile> files,
  int maximum,
) async {
  if (files.length > maximum) {
    throw RepositoryException('本次最多还能选择 $maximum 张图片，请重新选择。');
  }
  final images = <CommunityImageSelection>[];
  for (final file in files) {
    if (await file.length() > communityImageMaxBytes) {
      throw const RepositoryException('每张图片不能超过 8 MiB，请缩小图片后重试。');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > communityImageMaxBytes) {
      throw const RepositoryException('图片为空或超过 8 MiB，请重新选择。');
    }
    final mimeType = _mimeType(bytes);
    if (mimeType == null) {
      throw const RepositoryException('请选择 JPG、PNG 或 WebP 图片。');
    }
    images.add(
      CommunityImageSelection(
        id: _selectionId(),
        bytes: bytes,
        name: file.name,
        mimeType: mimeType,
      ),
    );
  }
  return List.unmodifiable(images);
}

String? _mimeType(Uint8List bytes) {
  bool matches(int offset, List<int> signature) =>
      bytes.length >= offset + signature.length &&
      List.generate(
        signature.length,
        (index) => index,
      ).every((index) => bytes[offset + index] == signature[index]);
  if (matches(0, [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (matches(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (matches(0, [0x52, 0x49, 0x46, 0x46]) &&
      matches(8, [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return null;
}
