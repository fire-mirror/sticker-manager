import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../models.dart';
import 'media_store.dart';
import 'package_codec.dart';
import 'repository.dart';

class ExportPackageService {
  ExportPackageService(this.database);

  final StickerRepository database;
  final EncryptedPackageCodec _codec = EncryptedPackageCodec();

  Future<void> exportTo(File destination, String password) async {
    final output = await buildPackage(password);
    await destination.writeAsBytes(output, flush: true);
  }

  Future<Uint8List> buildPackage(String password) async {
    if (password.length < 8) throw ArgumentError('密码至少需要 8 个字符');
    final stickers = await database.loadRanked();
    final groups = await database.loadGroups();
    final archive = Archive();
    final manifest = <String, Object?>{
      'formatVersion': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'groups': groups
          .map((group) => {
                'id': group.id,
                'name': group.name,
                'createdAt': group.createdAt.toIso8601String(),
              })
          .toList(),
      'stickers': stickers
          .map((entry) => {
                'id': entry.sticker.id,
                'hash': entry.sticker.hash,
                'mediaType': enumValue(entry.sticker.mediaType),
                'source': enumValue(entry.sticker.source),
                'note': entry.sticker.note,
                'createdAt': entry.sticker.createdAt.toIso8601String(),
                'updatedAt': entry.sticker.updatedAt.toIso8601String(),
                'lastUsedAt': entry.sticker.lastUsedAt?.toIso8601String(),
                'usageCount': entry.sticker.usageCount,
                'isPinned': entry.sticker.isPinned,
                'thumbnailVersion': entry.sticker.thumbnailVersion,
                'sourceOrder': entry.sticker.sourceOrder,
                'groups': entry.groupIds.toList(),
              })
          .toList(),
    };
    archive.addFile(ArchiveFile(
        'manifest.json',
        utf8.encode(jsonEncode(manifest)).length,
        utf8.encode(jsonEncode(manifest))));
    for (final entry in stickers) {
      final media = File(entry.sticker.filePath);
      if (await media.exists()) {
        final bytes = await media.readAsBytes();
        archive.addFile(ArchiveFile(
            'media/${path.basename(media.path)}', bytes.length, bytes));
      }
      final thumbnail = File(entry.sticker.thumbnailPath);
      if (await thumbnail.exists()) {
        final bytes = await thumbnail.readAsBytes();
        archive.addFile(ArchiveFile(
            'thumbnails/${path.basename(thumbnail.path)}',
            bytes.length,
            bytes));
      }
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw StateError('无法创建迁移包');
    final zipped = Uint8List.fromList(encoded);
    return _codec.encrypt(zipped, password);
  }

  Future<Archive> decrypt(File source, String password) async {
    final bytes = await source.readAsBytes();
    final plain = await _codec.decrypt(bytes, password);
    return ZipDecoder().decodeBytes(plain);
  }

  Future<ImportResult> importFrom(
      File source, String password, MediaStore mediaStore) async {
    final archive = await decrypt(source, password);
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('迁移包缺少 manifest.json');
    }
    final manifest =
        jsonDecode(utf8.decode(List<int>.from(manifestFile.content)))
            as Map<String, dynamic>;
    if (manifest['formatVersion'] != 1) {
      throw const FormatException('不支持的迁移包版本');
    }
    final temporary =
        await Directory.systemTemp.createTemp('sticker-manager-import-');
    var added = 0;
    var duplicates = 0;
    var skipped = 0;
    var thumbnailsGenerated = 0;
    try {
      for (final raw in (manifest['groups'] as List<dynamic>?) ?? const []) {
        final group = raw as Map<String, dynamic>;
        if (group['id'] == 'all') continue;
        try {
          await database.createGroup(
              group['id'] as String, group['name'] as String);
        } on Object {
          // Existing groups are safe to keep when importing a package twice.
        }
      }
      final restorable = <_RestorableSticker>[];
      final extractedFiles = <File>[];
      final sourceByPath = <String, StickerSource>{};
      for (final raw in (manifest['stickers'] as List<dynamic>?) ?? const []) {
        final entry = raw as Map<String, dynamic>;
        final hash = entry['hash'] as String;
        final mediaType = entry['mediaType'] as String;
        final fileNames = <String>[
          '$hash.${mediaType == 'gif' ? 'gif' : 'image'}',
          '$hash.${mediaType == 'gif' ? 'gif' : 'png'}',
        ];
        ArchiveFile? archived;
        for (final fileName in fileNames) {
          archived = archive.findFile('media/$fileName');
          if (archived != null) break;
        }
        if (archived == null) {
          skipped++;
          continue;
        }
        final archivedBytes =
            Uint8List.fromList(List<int>.from(archived.content));
        final actualHash = sha256.convert(archivedBytes).toString();
        if (actualHash != hash) {
          // A valid encrypted container can still contain a malformed or
          // mismatched manifest. Do not import media under the wrong identity.
          skipped++;
          continue;
        }
        final extracted = File(path.join(
            temporary.path, '$hash.${mediaType == 'gif' ? 'gif' : 'png'}'));
        await extracted.writeAsBytes(archivedBytes, flush: true);
        restorable.add(_RestorableSticker(hash: hash, manifest: entry));
        extractedFiles.add(extracted);
        sourceByPath[extracted.path] =
            sourceFrom(entry['source'] as String? ?? 'manual');
      }

      if (extractedFiles.isNotEmpty) {
        final result = await mediaStore.importFiles(
          extractedFiles,
          sourceForFile: (file) =>
              sourceByPath[file.path] ?? StickerSource.manual,
        );
        added = result.added;
        duplicates = result.duplicates;
        skipped += result.skipped;
        thumbnailsGenerated = result.thumbnailsGenerated;

        final ranked = await database.loadRanked();
        final byHash = <String, Sticker>{
          for (final item in ranked) item.sticker.hash: item.sticker,
        };
        for (final item in restorable) {
          final sticker = byHash[item.hash];
          if (sticker == null) continue;
          final entry = item.manifest;
          final restored = sticker.copyWith(
            createdAt: DateTime.tryParse(entry['createdAt'] as String? ?? '') ??
                sticker.createdAt,
            note: entry['note'] as String? ?? sticker.note,
            usageCount: entry['usageCount'] as int? ?? sticker.usageCount,
            isPinned: entry['isPinned'] as bool? ?? sticker.isPinned,
            lastUsedAt: entry['lastUsedAt'] == null
                ? sticker.lastUsedAt
                : DateTime.tryParse(entry['lastUsedAt'] as String),
            updatedAt: DateTime.tryParse(entry['updatedAt'] as String? ?? '') ??
                sticker.updatedAt,
            sourceOrder:
                (entry['sourceOrder'] as num?)?.toInt() ?? sticker.sourceOrder,
          );
          await database.updateSticker(restored);
          for (final groupId
              in (entry['groups'] as List<dynamic>?)?.whereType<String>() ??
                  const <String>[]) {
            try {
              await database.attachGroup(sticker.id, groupId);
            } on Object {
              // A duplicate membership does not make the package invalid.
            }
          }
        }
      }
    } finally {
      await temporary.delete(recursive: true);
    }
    return ImportResult(
      added: added,
      duplicates: duplicates,
      skipped: skipped,
      thumbnailsGenerated: thumbnailsGenerated,
    );
  }
}

class _RestorableSticker {
  const _RestorableSticker({required this.hash, required this.manifest});

  final String hash;
  final Map<String, dynamic> manifest;
}
