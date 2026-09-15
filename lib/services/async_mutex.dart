import 'dart:async';

/// Serializes asynchronous actions in the order they are requested.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return predecessor.then((_) async {
      try {
        return await action();
      } finally {
        if (!release.isCompleted) release.complete();
      }
    });
  }
}
