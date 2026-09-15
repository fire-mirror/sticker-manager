import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sticker_manager/models.dart';
import 'package:sticker_manager/services/import_source.dart';
import 'package:sticker_manager/services/database.dart';
import 'package:sticker_manager/services/media_store.dart';
import 'package:path/path.dart' as path;

void main() {
  test('automatic QQ import defaults to personal Ori only', () {
    expect(
      defaultSelectImportBatch(
          r'D:\QQ_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\personal_emoji\Ori'),
      isTrue,
    );
    expect(
      defaultSelectImportBatch(
          r'D:\QQ_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\emoji-recv'),
      isFalse,
    );
    expect(
      defaultSelectImportBatch(
          r'D:\QQ_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\marketface'),
      isFalse,
    );
    expect(
      defaultSelectImportBatch(r'D:\QQ\Image\Image\CustomFace'),
      isTrue,
    );
    expect(
      isReceivedOrMarketImportPath(r'C:\QQ\Image\Image\CustomFaceRecv\nested'),
      isTrue,
    );
    expect(
      defaultSelectImportFile(File(
          r'D:\QQ\_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\personal_emoji\Ori\a.png')),
      isTrue,
    );
    expect(
      defaultSelectImportFile(File(
          r'D:\QQ\_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\emoji-recv\chat.png')),
      isFalse,
    );
  });

  test('file-level import selection only returns checked files', () {
    final files = [
      File(r'C:\stickers\first.png'),
      File(r'C:\stickers\second.gif'),
      File(r'C:\stickers\third.jpg'),
    ];

    expect(selectImportFiles(files, {0, 2}), [files[0], files[2]]);
    expect(selectImportFiles(files, <int>{}), isEmpty);
  });

  test('sourceFor labels explicit QQ and WeChat emotion folders', () {
    final source = WindowsImportSource();

    expect(
      source.sourceFor(Directory(
          r'C:\Users\demo\Documents\Tencent Files\123\nt_qq\nt_data\Emoji\personal_emoji\Ori')),
      StickerSource.qq,
    );
    expect(
      source.sourceFor(Directory(
          r'C:\Users\demo\Documents\WeChat Files\wxid_demo\FileStorage\CustomEmotion')),
      StickerSource.wechat,
    );
    expect(
      source.sourceFor(Directory(
          r'D:\QQ_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\personal_emoji\Ori')),
      StickerSource.qq,
    );
    expect(
      source.sourceFor(Directory(
          r'D:\QQ\_NT\dialogue\Tencent Files\123456789\nt_qq\nt_data\Emoji\personal_emoji\Ori')),
      StickerSource.qq,
    );
    expect(
      source.sourceFor(Directory(r'D:\QQ_NT\dialogue\Tencent Files\123456789')),
      StickerSource.qq,
    );
    expect(
      source.sourceFor(Directory(r'D:\QQ_NT\dialogue\Tencent Files')),
      StickerSource.qq,
    );
    expect(source.sourceFor(Directory(r'C:\Projects\qq-images')),
        StickerSource.manual);
    expect(source.sourceFor(Directory(r'C:\Users\demo\Pictures')),
        StickerSource.manual);
  });

  test('scan filters non-media files and honors the automatic limit', () async {
    final temp = await Directory.systemTemp.createTemp('sticker-manager-');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory(
        '${temp.path}${Platform.pathSeparator}nt_qq${Platform.pathSeparator}nt_data${Platform.pathSeparator}Emoji${Platform.pathSeparator}personal_emoji${Platform.pathSeparator}Ori');
    await root.create(recursive: true);

    await File('${root.path}${Platform.pathSeparator}first.png')
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    await File('${root.path}${Platform.pathSeparator}second.gif')
        .writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    await File('${root.path}${Platform.pathSeparator}not-a-sticker.txt')
        .writeAsBytes(<int>[1]);
    await File('${root.path}${Platform.pathSeparator}invalid.jpg')
        .writeAsBytes(<int>[1]);
    await File('${root.path}${Platform.pathSeparator}extensionless')
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    await File('${root.path}${Platform.pathSeparator}unexpected.dat')
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

    final files = await WindowsImportSource().scan(root, maxFiles: 10);
    expect(files, hasLength(4));
    expect(files.any((file) => file.path.endsWith('extensionless')), isTrue);
    expect(files.any((file) => file.path.endsWith('unexpected.dat')), isTrue);
    expect(
        files.any((file) => file.path.endsWith('not-a-sticker.txt')), isFalse);

    final parentFiles = await WindowsImportSource().scan(
      Directory(path.join(temp.path, 'nt_qq', 'nt_data', 'Emoji')),
      maxFiles: 10,
    );
    expect(
        parentFiles.any((file) => file.path.endsWith('extensionless')), isTrue);

    final accountRoot =
        Directory(path.join(temp.path, 'Tencent Files', '123456789'));
    final accountEmotionRoot = Directory(path.join(accountRoot.path, 'nt_qq',
        'nt_data', 'Emoji', 'personal_emoji', 'Ori'));
    await accountEmotionRoot.create(recursive: true);
    await File(path.join(accountEmotionRoot.path, 'account-emotion.png'))
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final chatImages = Directory(
        path.join(accountRoot.path, 'nt_qq', 'nt_data', 'ChatImages'));
    await chatImages.create(recursive: true);
    await File(path.join(chatImages.path, 'chat.png'))
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final accountFiles =
        await WindowsImportSource().scan(accountRoot, maxFiles: 10);
    expect(
        accountFiles.any((file) => file.path.endsWith('account-emotion.png')),
        isTrue);
    expect(accountFiles.any((file) => file.path.endsWith('chat.png')), isFalse);

    final tencentFilesRoot = Directory(path.join(temp.path, 'Tencent Files'));
    final rootChat = Directory(path.join(
        tencentFilesRoot.path, '123456789', 'nt_qq', 'nt_data', 'ChatImages'));
    await rootChat.create(recursive: true);
    await File(path.join(rootChat.path, 'root-chat.png'))
        .writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final tencentParentFiles = await WindowsImportSource().scan(
      tencentFilesRoot,
      maxFiles: 10,
    );
    expect(
        tencentParentFiles
            .any((file) => file.path.endsWith('account-emotion.png')),
        isTrue);
    expect(
        tencentParentFiles.any((file) => file.path.endsWith('root-chat.png')),
        isFalse);
  });

  test('records are committed before thumbnails and damaged images are kept',
      () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-import-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    final mediaDirectory = Directory(path.join(temporary.path, 'media'));
    final store = MediaStore(database, mediaDirectory: mediaDirectory);
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final valid = File(path.join(temporary.path, 'valid.png'))
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
    final damaged = File(path.join(temporary.path, 'damaged.jpg'))
      ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xe0, 0x00]);
    final invalid = File(path.join(temporary.path, 'invalid.gif'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    var committed = false;
    final result = await store.importFiles(
      [valid, damaged, invalid],
      onRecordsCommitted: (_) async {
        committed = (await database.loadRanked()).length == 2;
      },
    );

    expect(committed, isTrue);
    expect(result.added, 2);
    expect(result.skipped, 1);
    expect(result.thumbnailsGenerated, 1);
    final damagedEntry = (await database.loadRanked())
        .singleWhere((entry) => entry.sticker.note == 'damaged');
    expect(damagedEntry.sticker.thumbnailPath, isEmpty);
  });

  test('imports new stickers into the selected group and all', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-group-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    final mediaDirectory = Directory(path.join(temporary.path, 'media'));
    final store = MediaStore(database, mediaDirectory: mediaDirectory);
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    await database.createGroup('favorites', '常用');
    final source = File(path.join(temporary.path, 'sticker.png'))
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));

    final result = await store.importFiles(
      [source],
      groupIds: const ['all', 'favorites'],
    );

    expect(result.added, 1);
    final entry = (await database.loadRanked()).single;
    expect(entry.groupIds, containsAll(<String>['all', 'favorites']));
  });

  test('rebuilds thumbnails from an older generation version', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-thumb-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    final mediaDirectory = Directory(path.join(temporary.path, 'media'));
    final store = MediaStore(database, mediaDirectory: mediaDirectory);
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final source = File(path.join(temporary.path, 'legacy.png'))
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
    final oldThumbnail = File(path.join(mediaDirectory.path, 'old-thumb.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final now = DateTime.now();
    await database.insertSticker(Sticker(
      id: 'legacy',
      hash: 'a' * 64,
      mediaType: StickerMediaType.image,
      filePath: source.path,
      thumbnailPath: oldThumbnail.path,
      thumbnailVersion: 1,
      source: StickerSource.manual,
      createdAt: now,
      updatedAt: now,
    ));

    final generated = await store.rebuildLegacyThumbnails();
    final restored = (await database.loadRanked()).single.sticker;
    expect(generated, 1);
    expect(restored.thumbnailVersion, StickerDatabase.currentThumbnailVersion);
    expect(restored.thumbnailPath, isNot(oldThumbnail.path));
    expect(await File(restored.thumbnailPath).exists(), isTrue);
  });
}
