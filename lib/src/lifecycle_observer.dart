import 'package:flutter/widgets.dart';

/// Observes app lifecycle events and calls handlers for foreground/background transitions.
class LifecycleObserver with WidgetsBindingObserver {
  final VoidCallback onForeground;
  final Future<void> Function() onBackground;

  /// The future from the most recent background callback, or `null` once complete.
  /// Callers (e.g. `close()`) can await this to ensure background work completes.
  Future<void>? pendingBackground;

  LifecycleObserver({
    required this.onForeground,
    required this.onBackground,
  });

  /// Registers this observer with [WidgetsBinding].
  void register() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Removes this observer from [WidgetsBinding].
  void unregister() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onForeground();
        break;
      case AppLifecycleState.paused:
        final future = onBackground();
        pendingBackground = future;
        future.whenComplete(() => pendingBackground = null);
        break;
      default:
        break;
    }
  }
}
