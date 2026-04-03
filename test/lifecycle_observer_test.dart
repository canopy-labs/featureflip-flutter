import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/src/lifecycle_observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('onBackground callback type accepts async functions', () {
    // LifecycleObserver.onBackground must be typed as Future<void> Function()
    // so the returned future is not silently dropped.
    final observer = LifecycleObserver(
      onForeground: () {},
      onBackground: () async {
        await Future<void>.delayed(Duration.zero);
      },
    );

    // Verify the callback is stored with async-aware type
    expect(observer.onBackground, isA<Future<void> Function()>());

    observer.register();
    observer.unregister();
  });

  test('didChangeAppLifecycleState tracks pending background future', () async {
    final completer = Completer<void>();
    var backgroundStarted = false;
    var backgroundCompleted = false;

    final observer = LifecycleObserver(
      onForeground: () {},
      onBackground: () async {
        backgroundStarted = true;
        await completer.future;
        backgroundCompleted = true;
      },
    );
    observer.register();

    // Trigger background
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);

    // Allow microtasks to run
    await Future<void>.delayed(Duration.zero);

    expect(backgroundStarted, isTrue);
    expect(backgroundCompleted, isFalse,
        reason: 'Background callback should still be in progress');

    // pendingBackground should expose the running future
    expect(observer.pendingBackground, isNotNull);

    // Store reference before completing (it will be cleared on completion)
    final pending = observer.pendingBackground!;

    // Complete the async work
    completer.complete();
    await pending;

    expect(backgroundCompleted, isTrue);
    expect(observer.pendingBackground, isNull,
        reason: 'pendingBackground should be cleared after completion');

    observer.unregister();
  });
}
