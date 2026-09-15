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

  static const maxArchiveEntries = 10000;
  static const maxManifestBytes = 16 * 1024 * 1024;
  static const maxArchiveFileBytes = 64 * 1024 * 1024;
  static const maxArchiveUncompressedBytes = 512 * 1024 * 1024;
  static const maxGroups = 2000;
  static const maxStickers = 10000;

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
    if (stickers.length > maxStickers) {
      throw StateError('表情数量超过迁移包限制');
    }
    if (groups.length > maxGroups) {
      throw StateError('分组数量超过迁移包限制');
    }
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
    final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
    if (manifestBytes.length > maxManifestBytes) {
      throw StateError('迁移包 manifest 超过允许的大小');
    }
    archive.addFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    for (final entry in stickers) {
      final media = File(entry.sticker.filePath);
      if (await media.exists()) {
        final length = await media.length();
        if (length > maxArchiveFileBytes) {
          throw StateError('表情媒体文件超过允许的大小');
        }
        final bytes = await media.readAsBytes();
        archive.addFile(ArchiveFile(
            'media/${path.basename(media.path)}', bytes.length, bytes));
      }
      final thumbnail = File(entry.sticker.thumbnailPath);
      if (await thumbnail.exists()) {
        final length = await thumbnail.length();
        if (length > maxArchiveFileBytes) {
          throw StateError('表情缩略图超过允许的大小');
        }
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
    _validateArchive(archive);
    if (zipped.length > EncryptedPackageCodec.maxPlainBytes) {
      throw StateError('迁移包超过允许的大小');
    }
    return _codec.encrypt(zipped, password);
  }

  Future<Archive> decrypt(File source, String password) async {
    final sourceLength = await source.length();
    if (sourceLength > EncryptedPackageCodec.maxEncryptedBytes) {
      throw const FormatException('迁移包超过允许的大小');
    }
    final bytes = await source.readAsBytes();
    final plain = await _codec.decrypt(bytes, password);
    final archive = ZipDecoder().decodeBytes(plain);
    _validateArchive(archive);
    return archive;
  }

  Future<ImportResult> importFrom(
      File source, String password, MediaStore mediaStore) async {
    final archive = await decrypt(source, password);
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('迁移包缺少 manifest.json');
    }
    if (manifestFile.size > maxManifestBytes) {
      throw const FormatException('迁移包 manifest 超过允许的大小');
    }
    final manifest =
        jsonDecode(utf8.decode(List<int>.from(manifestFile.content)))
            as Map<String, dynamic>;
    manifestFile.clear();
    if (manifest['formatVersion'] != 1) {
      throw const FormatException('不支持的迁移包版本');
    }
    final groups = manifest['groups'];
    final stickers = manifest['stickers'];
    if (groups != null && groups is! List) {
      throw const FormatException('迁移包 groups 格式无效');
    }
    if (stickers != null && stickers is! List) {
      throw const FormatException('迁移包 stickers 格式无效');
    }
    final groupList = groups as List<dynamic>?;
    final stickerList = stickers as List<dynamic>?;
    if (groupList != null && groupList.length > maxGroups) {
      throw const FormatException('迁移包分组数量超过限制');
    }
    if (stickerList != null && stickerList.length > maxStickers) {
      throw const FormatException('迁移包表情数量超过限制');
    }
    _validateManifestEntries(groupList ?? const [], stickerList ?? const []);
    final temporary =
        await Directory.systemTemp.createTemp('sticker-manager-import-');
    var added = 0;
    var duplicates = 0;
    var skipped = 0;
    var thumbnailsGenerated = 0;
    try {
      for (final raw in groupList ?? const []) {
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
      for (final raw in stickerList ?? const []) {
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
        // ArchiveFile keeps decompressed content cached. Release it after the
        // hash check so a large package does not retain every media payload in
        // memory while the import is written to its temporary directory.
        archived.clear();
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

  void _validateArchive(Archive archive) {
    if (archive.numberOfFiles() > maxArchiveEntries) {
      throw const FormatException('迁移包文件数量超过限制');
    }
    var total = 0;
    for (final file in archive.files) {
      if (file.size < 0 || file.size > maxArchiveFileBytes) {
        throw const FormatException('迁移包中的文件超过大小限制');
      }
      total += file.size;
      if (total > maxArchiveUncompressedBytes) {
        throw const FormatException('迁移包解压后超过允许的大小');
      }
      final normalized = file.name.replaceAll('\\', '/');
      if (normalized.startsWith('/') || normalized.split('/').contains('..')) {
        throw const FormatException('迁移包包含无效路径');
      }
    }
  }

  void _validateManifestEntries(List<dynamic> groups, List<dynamic> stickers) {
    final safeId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    final safeHash = RegExp(r'^[0-9a-fA-F]{64}$');
    for (final raw in groups) {
      if (raw is! Map) {
        throw const FormatException('迁移包分组记录格式无效');
      }
      final id = raw['id'];
      final name = raw['name'];
      if (id is! String ||
          !safeId.hasMatch(id) ||
          name is! String ||
          name.length > 256) {
        throw const FormatException('迁移包分组字段无效');
      }
    }
    for (final raw in stickers) {
      if (raw is! Map) {
        throw const FormatException('迁移包表情记录格式无效');
      }
      final id = raw['id'];
      final hash = raw['hash'];
      final mediaType = raw['mediaType'];
      if (id is! String ||
          !safeId.hasMatch(id) ||
          hash is! String ||
          !safeHash.hasMatch(hash) ||
          mediaType is! String ||
          (mediaType != 'image' && mediaType != 'gif')) {
        throw const FormatException('迁移包表情字段无效');
      }
      final note = raw['note'];
      if (note != null && (note is! String || note.length > 4096)) {
        throw const FormatException('迁移包备注字段无效');
      }
      final membership = raw['groups'];
      if (membership is! List) {
        throw const FormatException('迁移包分组关系格式无效');
      }
      for (final groupId in membership) {
        if (groupId is! String || !safeId.hasMatch(groupId)) {
          throw const FormatException('迁移包分组关系无效');
        }
      }
    }
  }
}

class _RestorableSticker {
  const _RestorableSticker({required this.hash, required this.manifest});

  final String hash;
  final Map<String, dynamic> manifest;
}
