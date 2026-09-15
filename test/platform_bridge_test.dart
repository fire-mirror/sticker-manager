import 'package:flutter_test/flutter_test.dart';

import 'package:sticker_manager/platform/platform_bridge.dart';

void main() {
  test('copy-only and pasted results carry distinct usage semantics', () {
    expect(const StickerUseResult.copied().didPaste, isFalse);
    expect(const StickerUseResult.copied(didPaste: true).didPaste, isTrue);
    expect(const StickerUseResult.sent().didPaste, isTrue);
  });
}
