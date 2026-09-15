import 'dart:io';

import '../models.dart';

/// Platform-independent contract for discovering media files and classifying
/// their origin before they enter the managed library.
abstract interface class ImportSource {
  Future<List<File>> scan(Directory root, {int maxFiles = 1000});

  StickerSource sourceFor(Directory root);
}

/// Returns true for QQ folders that contain received chat or marketplace
/// media rather than the user's personal sticker collection.
bool isReceivedOrMarketImportPath(String label) {
  final normalized = label.toLowerCase().replaceAll('/', '\\');
  return RegExp(
    r'(?:^|\\)(?:emoji-recv|customfacerecv|marketface)(?:\\|$)',
  ).hasMatch(normalized);
}

bool defaultSelectImportBatch(String label) =>
    !isReceivedOrMarketImportPath(label);

/// Applies the same safety rule to files when a user selects a parent folder
/// such as `Tencent Files`. A single batch can then contain both personal
/// stickers and received/market media, so selection must be decided per file.
bool defaultSelectImportFile(File file) =>
    !isReceivedOrMarketImportPath(file.path);

List<File> selectImportFiles(List<File> files, Set<int> selectedIndexes) {
  if (selectedIndexes.isEmpty) return const <File>[];
  return [
    for (var index = 0; index < files.length; index++)
      if (selectedIndexes.contains(index)) files[index],
  ];
}
