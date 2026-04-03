import 'dart:async';

import 'http_client.dart';
import 'models.dart';

/// Periodically fetches evaluated flags via HTTP polling.
class PollingDataSource {
  final FeatureflipHttpClient _httpClient;
  Map<String, dynamic> _context;
  final Duration _interval;
  final void Function(Map<String, FlagValue> flags) onChange;
  Timer? _timer;

  PollingDataSource({
    required FeatureflipHttpClient httpClient,
    required Map<String, dynamic> context,
    required Duration interval,
    required this.onChange,
  })  : _httpClient = httpClient,
        _context = Map.of(context),
        _interval = interval;

  /// Starts periodic polling. Polls once immediately, then on interval.
  void start() {
    stop();
    pollOnce();
    _timer = Timer.periodic(_interval, (_) => pollOnce());
  }

  /// Stops polling.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Updates the context used for future polls.
  void updateContext(Map<String, dynamic> context) {
    _context = Map.of(context);
  }

  /// Polls the evaluation API once.
  Future<void> pollOnce() async {
    try {
      final result = await _httpClient.evaluate(_context);
      onChange(result.flags);
    } catch (_) {
      // Silent — don't crash on network errors
    }
  }
}
