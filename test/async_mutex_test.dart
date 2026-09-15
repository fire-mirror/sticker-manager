import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_manager/services/async_mutex.dart';

void main() {
  test('serializes actions and releases after an exception', () async {
    final mutex = AsyncMutex();
    final events = <String>[];
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();

    final first = mutex.protect(() async {
      events.add('first-start');
      firstStarted.complete();
      await releaseFirst.future;
      events.add('first-end');
      return 1;
    });
    await firstStarted.future;

    final second = mutex.protect(() async {
      events.add('second');
      return 2;
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);

    releaseFirst.complete();
    expect(await Future.wait([first, second]), [1, 2]);
    expect(events, ['first-start', 'first-end', 'second']);

    final failing = mutex.protect(() async {
      throw StateError('expected');
    });
    final afterFailure = mutex.protect(() async => 3);
    await expectLater(failing, throwsStateError);
    expect(await afterFailure, 3);
  });
}
