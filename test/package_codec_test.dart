import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sticker_manager/services/database.dart';
import 'package:sticker_manager/services/export_service.dart';
import 'package:sticker_manager/services/media_store.dart';
import 'package:sticker_manager/services/package_codec.dart';

void main() {
  test('encrypted package round trips with the correct password', () async {
    final codec = EncryptedPackageCodec();
    final encrypted = await codec.encrypt([1, 2, 3, 4], 'correct horse');
    expect(await codec.decrypt(encrypted, 'correct horse'), [1, 2, 3, 4]);
  });

  test('wrong password cannot decrypt the package', () async {
    final codec = EncryptedPackageCodec();
    final encrypted = await codec.encrypt([1, 2, 3, 4], 'correct horse');
    expect(() => codec.decrypt(encrypted, 'wrong password'), throwsA(anything));
  });

  test('tampering is detected by authenticated encryption', () async {
    final codec = EncryptedPackageCodec();
    final encrypted = await codec.encrypt([1, 2, 3, 4], 'correct horse');
    encrypted[encrypted.length - 1] ^= 1;
    expect(() => codec.decrypt(encrypted, 'correct horse'), throwsA(anything));
  });

  test('media hash mismatch is rejected before package import', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-package-');
    final database = StickerDatabase(
        databasePath: '${temporary.path}${Platform.pathSeparator}db.sqlite');
    final store = MediaStore(database,
        mediaDirectory:
            Directory('${temporary.path}${Platform.pathSeparator}media'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final media = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]);
    final manifest = jsonEncode({
      'formatVersion': 1,
      'groups': <Object?>[],
      'stickers': [
        {
          'id': '0000000000000000',
          'hash': '0' * 64,
          'mediaType': 'image',
          'source': 'manual',
          'note': '',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'usageCount': 0,
          'isPinned': false,
          'groups': <String>[],
        }
      ],
    });
    final archive = Archive()
      ..addFile(ArchiveFile(
        'manifest.json',
        utf8.encode(manifest).length,
        utf8.encode(manifest),
      ))
      ..addFile(ArchiveFile('media/${'0' * 64}.image', media.length, media));
    final zipped = ZipEncoder().encode(archive);
    expect(zipped, isNotNull);
    final source =
        File('${temporary.path}${Platform.pathSeparator}hash-mismatch.smp');
    final codec = EncryptedPackageCodec();
    await source.writeAsBytes(await codec.encrypt(zipped!, 'password123'),
        flush: true);

    final result = await ExportPackageService(database)
        .importFrom(source, 'password123', store);

    expect(result.added, 0);
    expect(result.skipped, 1);
    expect(await database.loadRanked(), isEmpty);
    // Keep the actual hash in the test data explicit so this test cannot pass
    // because the deliberately wrong hash happens to match the payload.
    expect(sha256.convert(media).toString(), isNot('0' * 64));
  });

  test('package import restores ranking metadata and groups', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-package-');
    final sourceDatabase = StickerDatabase(
        databasePath: pathJoin(temporary.path, 'source.sqlite'));
    final sourceStore = MediaStore(sourceDatabase,
        mediaDirectory: Directory(pathJoin(temporary.path, 'source-media')));
    final destinationDatabase = StickerDatabase(
        databasePath: pathJoin(temporary.path, 'destination.sqlite'));
    final destinationStore = MediaStore(destinationDatabase,
        mediaDirectory:
            Directory(pathJoin(temporary.path, 'destination-media')));
    addTearDown(() async {
      await sourceDatabase.close();
      await destinationDatabase.close();
      await temporary.delete(recursive: true);
    });

    final media = File(pathJoin(temporary.path, 'source.png'))
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
    final imported = await sourceStore.importFiles([media]);
    expect(imported.added, 1);
    await sourceDatabase.createGroup('favorites', '常用');
    final original = (await sourceDatabase.loadRanked()).single.sticker;
    final createdAt = DateTime(2024, 5, 6, 7, 8, 9, 10);
    final lastUsedAt = DateTime(2025, 6, 7, 8, 9, 10, 11);
    await sourceDatabase.updateSticker(original.copyWith(
      createdAt: createdAt,
      updatedAt: lastUsedAt,
      lastUsedAt: lastUsedAt,
      usageCount: 17,
      isPinned: true,
      note: '迁移备注',
    ));
    await sourceDatabase.replaceStickerGroups(original.id, ['favorites']);

    final package = File(pathJoin(temporary.path, 'metadata.smp'));
    await ExportPackageService(sourceDatabase).exportTo(package, 'password123');
    final result = await ExportPackageService(destinationDatabase)
        .importFrom(package, 'password123', destinationStore);

    expect(result.added, 1);
    final restored = (await destinationDatabase.loadRanked()).single;
    expect(restored.sticker.createdAt, createdAt);
    expect(restored.sticker.updatedAt, lastUsedAt);
    expect(restored.sticker.lastUsedAt, lastUsedAt);
    expect(restored.sticker.usageCount, 17);
    expect(restored.sticker.isPinned, isTrue);
    expect(restored.sticker.note, '迁移备注');
    expect(restored.groupIds, containsAll(<String>['all', 'favorites']));
  });
}

String pathJoin(String first, String second) =>
    '$first${Platform.pathSeparator}$second';
