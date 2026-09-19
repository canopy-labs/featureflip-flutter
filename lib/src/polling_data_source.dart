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

  // Cancelling the timer cannot recall a poll already on the wire: the awaited
  // future still completes and onChange still fires. That used to be harmless,
  // because a poller was only ever stopped alongside everything else — but #3075
  // retires the fallback poller while the recovered stream is live, so a response
  // still in flight would REPLACE the store on top of the stream's fresher connect
  // snapshot. Any flag that changed between the two server-side evaluations would
  // revert, and because the stream already delivered that change IN the snapshot,
  // later deltas would merge on top of the stale value and never correct it.
  bool _stopped = false;

  /// Starts periodic polling. Polls once immediately, then on interval.
  void start() {
    stop();
    _stopped = false;
    pollOnce();
    _timer = Timer.periodic(_interval, (_) => pollOnce());
  }

  /// Stops polling.
  void stop() {
    _stopped = true;
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
      if (_stopped) return;
      onChange(result.flags);
    } catch (_) {
      // Silent — don't crash on network errors
    }
  }
}
