import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:sticker_manager/models.dart';
import 'package:sticker_manager/services/database.dart';
import 'package:sticker_manager/services/ranking_service.dart';

void main() {
  test('batch insert uses one transaction and ignores duplicate hashes',
      () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-db-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final now = DateTime(2026);
    Sticker sticker(String id, String hash) => Sticker(
          id: id,
          hash: hash,
          mediaType: StickerMediaType.image,
          filePath: '$id.image',
          thumbnailPath: '',
          source: StickerSource.manual,
          createdAt: now,
          updatedAt: now,
        );

    final inserted = await database.insertStickers([
      sticker('one', 'same-hash'),
      sticker('two', 'different-hash'),
      sticker('duplicate', 'same-hash'),
    ]);
    expect(inserted.map((item) => item.id), ['one', 'two']);

    await database.updateThumbnail(
        'one', 'one-thumb.png', StickerDatabase.currentThumbnailVersion);
    final loaded = await database.loadRanked();
    expect(loaded, hasLength(2));
    expect(
        loaded
            .singleWhere((item) => item.sticker.id == 'one')
            .sticker
            .thumbnailVersion,
        StickerDatabase.currentThumbnailVersion);
  });

  test('new databases include QQ 收藏 and preserve its source order', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-db-qq-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final groups = await database.loadGroups();
    expect(groups.map((group) => group.id), ['all', 'qq_favorites']);
    final now = DateTime(2026);
    Sticker sticker(String id, String hash, int order) => Sticker(
          id: id,
          hash: hash,
          mediaType: StickerMediaType.image,
          filePath: '$id.image',
          thumbnailPath: '',
          source: StickerSource.qq,
          sourceOrder: order,
          createdAt: now,
          updatedAt: now,
        );
    await database.insertStickers([
      sticker('late', 'late-hash', 4),
      sticker('early', 'early-hash', 1),
    ], groupIds: const [
      'all',
      'qq_favorites'
    ]);
    final ranked = UsageRankingService()
        .rank(await database.loadRanked(), groupId: 'qq_favorites');
    expect(ranked.map((entry) => entry.sticker.id), ['early', 'late']);
  });

  test('replacing sticker groups keeps the virtual all group', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-db-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    await database.createGroup('cats', '猫猫');
    await database.createGroup('favorites', '常用');
    final sticker = Sticker(
      id: 'sticker',
      hash: 'sticker-hash',
      mediaType: StickerMediaType.image,
      filePath: 'sticker.image',
      thumbnailPath: '',
      source: StickerSource.manual,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await database.insertSticker(sticker);
    await database.replaceStickerGroups(sticker.id, ['cats', 'favorites']);

    final entry = (await database.loadRanked()).single;
    expect(entry.groupIds, containsAll(<String>['all', 'cats', 'favorites']));
    await database.replaceStickerGroups(sticker.id, ['favorites']);
    expect((await database.loadRanked()).single.groupIds,
        containsAll(<String>['all', 'favorites']));
    expect(
        (await database.loadRanked()).single.groupIds, isNot(contains('cats')));

    final now = DateTime(2026);
    final second = Sticker(
      id: 'second',
      hash: 'second-hash',
      mediaType: StickerMediaType.image,
      filePath: 'second.image',
      thumbnailPath: '',
      source: StickerSource.manual,
      createdAt: now,
      updatedAt: now,
    );
    await database.insertSticker(second);
    await database.replaceStickerGroupsMany([sticker.id, second.id], ['cats']);
    final moved = await database.loadRanked();
    expect(moved.singleWhere((item) => item.sticker.id == sticker.id).groupIds,
        containsAll(<String>['all', 'cats']));
    expect(moved.singleWhere((item) => item.sticker.id == second.id).groupIds,
        containsAll(<String>['all', 'cats']));
  });

  test('recordUsage increments from the database value', () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-db-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final now = DateTime(2026, 1, 1, 12);
    final sticker = Sticker(
      id: 'usage',
      hash: 'usage-hash',
      mediaType: StickerMediaType.image,
      filePath: 'usage.image',
      thumbnailPath: '',
      source: StickerSource.manual,
      createdAt: now,
      updatedAt: now,
    );
    await database.insertSticker(sticker);
    await Future.wait([
      database.recordUsage(sticker.id, now),
      database.recordUsage(sticker.id, now),
    ]);

    final loaded = (await database.loadRanked()).single.sticker;
    expect(loaded.usageCount, 2);
    expect(loaded.lastUsedAt, now);

    final later = now.add(const Duration(seconds: 10));
    await database.recordUsage(sticker.id, later);
    await database.recordUsage(sticker.id, now);
    final afterOutOfOrder = (await database.loadRanked()).single.sticker;
    expect(afterOutOfOrder.usageCount, 4);
    expect(afterOutOfOrder.lastUsedAt, later);
  });

  test('recordUsageMany updates duplicate IDs in one logical operation',
      () async {
    final temporary = await Directory.systemTemp.createTemp('sticker-db-');
    final database =
        StickerDatabase(databasePath: path.join(temporary.path, 'stickers.db'));
    addTearDown(() async {
      await database.close();
      await temporary.delete(recursive: true);
    });

    final now = DateTime(2026, 1, 2, 8);
    final first = Sticker(
      id: 'first',
      hash: 'first-hash',
      mediaType: StickerMediaType.image,
      filePath: 'first.image',
      thumbnailPath: '',
      source: StickerSource.manual,
      createdAt: now,
      updatedAt: now,
    );
    final secondWithId = Sticker(
      id: 'second',
      hash: 'second-hash',
      mediaType: StickerMediaType.image,
      filePath: 'second.image',
      thumbnailPath: '',
      source: StickerSource.manual,
      createdAt: now,
      updatedAt: now,
    );
    await database.insertStickers([first, secondWithId]);
    await database.recordUsageMany([first.id, first.id, secondWithId.id], now);

    final loaded = await database.loadRanked();
    expect(
        loaded
            .singleWhere((item) => item.sticker.id == first.id)
            .sticker
            .usageCount,
        2);
    expect(
        loaded
            .singleWhere((item) => item.sticker.id == secondWithId.id)
            .sticker
            .usageCount,
        1);
  });
}
