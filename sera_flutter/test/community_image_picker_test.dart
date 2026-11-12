import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sera_flutter/data/auth_storage.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/platform/community_image_picker.dart';

class _Storage implements AuthSessionStorage {
  final values = <String, String>{};
  MapEntry<String, String>? saved;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    saved = MapEntry(key, value);
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
  void restoreMarker() => values[saved!.key] = saved!.value;
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jH9kAAAAASUVORK5CYII=',
);
XFile _file() => XFile.fromData(_png, name: 'photo.png', mimeType: 'image/png');
const _owner = '["https://community.test","account-a","session-1"]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('normal image selection records owner, detects bytes and clears only its marker', () async {
    final storage = _Storage();
    final selected = await pickCommunityImages(
      owner: _owner,
      storage: storage,
      pickImages: (limit) async {
        expect(limit, 3);
        final marker = jsonDecode(storage.values.values.single) as Map;
        expect(marker['owner'], _owner);
        expect(marker.keys, unorderedEquals(['owner', 'operation']));
        return [_file()];
      },
    );
    expect(selected.single.bytes, _png);
    expect(selected.single.mimeType, 'image/png');
    expect(selected.single.id, matches(RegExp(r'^image-[a-f0-9]{32}$')));
    expect(storage.values, isEmpty);
    final pending = Completer<List<XFile>>();
    final active = pickCommunityImages(
      owner: _owner,
      storage: storage,
      pickImages: (_) => pending.future,
    );
    while (storage.values.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final key = storage.values.keys.single;
    storage.values[key] = 'a newer owner selection marker';
    pending.complete([]);
    expect(await active, isEmpty);
    expect(storage.values[key], 'a newer owner selection marker');
  });

  test('cancel, denied access, unsupported files and oversized images leave no recovery marker', () async {
    final storage = _Storage();
    expect(
      await pickCommunityImages(
        owner: _owner,
        storage: storage,
        pickImages: (_) async => [],
      ),
      isEmpty,
    );
    expect(storage.values, isEmpty);
    for (final select in <Future<List<XFile>> Function(int)>[
      (_) async => throw PlatformException(code: 'photo_access_denied'),
      (_) async => [
        XFile.fromData(
          Uint8List.fromList([71, 73, 70]),
          name: 'not-a-jpeg.jpg',
        ),
      ],
      (_) async => [
        XFile.fromData(
          Uint8List(communityImageMaxBytes + 1),
          name: 'large.png',
        ),
      ],
      (_) async => [_file(), _file()],
    ]) {
      await expectLater(
        pickCommunityImages(
          owner: _owner,
          limit: 1,
          storage: storage,
          pickImages: select,
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(storage.values, isEmpty);
    }
  });

  test(
    'lost Android images recover only for their original restored session',
    () async {
      final storage = _Storage();
      await pickCommunityImages(
        owner: _owner,
        storage: storage,
        pickImages: (_) async => [],
      );
      storage.restoreMarker();
      var calls = 0;
      Future<LostDataResponse> recover() async {
        calls++;
        return LostDataResponse(files: [_file()]);
      }

      final images = await recoverCommunityImages(
        _owner,
        storage: storage,
        retrieveLostData: recover,
      );
      expect(images.single.bytes, _png);
      expect(storage.values, isEmpty);
      for (final other in [
        '["https://other.test","account-a","session-1"]',
        '["https://community.test","account-b","session-1"]',
        '["https://community.test","account-a","session-2"]',
      ]) {
        storage.restoreMarker();
        expect(
          await recoverCommunityImages(
            other,
            storage: storage,
            retrieveLostData: recover,
          ),
          isEmpty,
        );
        expect(storage.values, isEmpty);
      }
      expect(calls, 4);
      expect(
        await recoverCommunityImages(
          _owner,
          storage: storage,
          retrieveLostData: recover,
        ),
        isEmpty,
      );
      expect(
        calls,
        5,
        reason: 'unowned plugin results are consumed and discarded',
      );
    },
  );

  test(
    'active selection and a newer marker cannot be consumed by stale recovery',
    () async {
      final storage = _Storage();
      final pending = Completer<List<XFile>>();
      final active = pickCommunityImages(
        owner: _owner,
        storage: storage,
        pickImages: (_) => pending.future,
      );
      while (storage.values.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        await recoverCommunityImages(
          _owner,
          storage: storage,
          retrieveLostData: () async {
            fail('an active picker must not be consumed');
          },
        ),
        isEmpty,
      );
      pending.complete([]);
      await active;
      storage.restoreMarker();
      final response = Completer<LostDataResponse>();
      final started = Completer<void>();
      final recovering = recoverCommunityImages(
        _owner,
        storage: storage,
        retrieveLostData: () {
          started.complete();
          return response.future;
        },
      );
      await started.future;
      final key = storage.values.keys.single;
      storage.values[key] = 'new marker';
      response.complete(LostDataResponse(files: [_file()]));
      expect(await recovering, isEmpty);
      expect(storage.values[key], 'new marker');
    },
  );
}
