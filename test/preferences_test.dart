import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sticker_manager/models.dart';
import 'package:sticker_manager/services/preferences.dart';

void main() {
  test('compatibility records persist newest first and cap at 100', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = AppPreferences();
    final base = DateTime(2026, 1, 1);

    for (var index = 0; index < 105; index++) {
      await preferences.recordCompatibility(ClipboardCompatibilityRecord(
        targetApplication: 'target-$index.exe',
        mediaType: StickerMediaType.image,
        status: 'sent',
        createdAt: base.add(Duration(minutes: index)),
      ));
    }

    final records = await preferences.compatibilityRecords();
    expect(records, hasLength(100));
    expect(records.first.targetApplication, 'target-104.exe');
    expect(records.last.targetApplication, 'target-5.exe');
  });
}
