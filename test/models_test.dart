import 'package:flutter_test/flutter_test.dart';

import 'package:sticker_manager/models.dart';

void main() {
  test('enum values round trip through portable strings', () {
    expect(enumValue(StickerMediaType.gif), 'gif');
    expect(mediaTypeFrom('gif'), StickerMediaType.gif);
    expect(sourceFrom('wechat'), StickerSource.wechat);
  });

  test('copyWith updates metadata while preserving media identity', () {
    final original = Sticker(
      id: 'id',
      hash: 'hash',
      mediaType: StickerMediaType.image,
      filePath: 'file',
      thumbnailPath: 'thumb',
      source: StickerSource.manual,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final createdAt = DateTime(2025, 1, 1);
    final updated =
        original.copyWith(createdAt: createdAt, note: 'hello', usageCount: 1);
    expect(updated.createdAt, createdAt);
    expect(updated.id, original.id);
    expect(updated.hash, original.hash);
    expect(updated.note, 'hello');
    expect(updated.usageCount, 1);
  });

  test('clipboard compatibility records round trip and reject malformed data',
      () {
    final record = ClipboardCompatibilityRecord(
      targetApplication: 'QQ.exe',
      mediaType: StickerMediaType.gif,
      status: 'sent',
      createdAt: DateTime(2026, 1, 2, 3, 4),
      message: 'ok',
    );
    final restored = ClipboardCompatibilityRecord.fromJson(record.toJson());
    expect(restored?.targetApplication, 'QQ.exe');
    expect(restored?.mediaType, StickerMediaType.gif);
    expect(restored?.status, 'sent');
    expect(restored?.message, 'ok');
    expect(ClipboardCompatibilityRecord.fromJson({'status': 'sent'}), isNull);
  });
}
