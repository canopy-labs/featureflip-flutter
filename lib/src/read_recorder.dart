import 'models.dart';

/// Reports the flags application code actually reads, at most once per
/// (flag, variation, user) per [window].
///
/// Featureflip uses these `Evaluation` events to tell which flags deployed code
/// still reads. A flag only needs to be seen as read, so repeats inside a window
/// are dropped rather than counted.
///
/// [record] sits on every flag read, including widget rebuilds, so a REPEAT read
/// must stay O(1) and allocation-free: one monotonic clock read and three hash
/// lookups, with no key string, record or event built. Only the first read in a
/// window allocates, reads the wall clock and calls the sink.
class ReadRecorder {
  /// How long one report of a (flag, variation, user) stands. Fixed: rollups are
  /// hourly buckets and the archive guard looks back 24 h, so re-reporting hourly
  /// loses nothing, and it bounds a long session to one event per read per hour.
  static const window = Duration(hours: 1);
  static const _windowMs = 60 * 60 * 1000; // window.inMilliseconds, as a const

  /// Stands in for a null variation or user id in the lookup maps. A const
  /// literal, so mapping null to it allocates nothing.
  static const _absent = '';

  /// [sink] receives the first read of each (flag, variation, user) in a window.
  /// [nowMs] is a monotonic millisecond clock, for tests; it defaults to a
  /// [Stopwatch] started here. A monotonic clock, not `DateTime.now()`: it is
  /// cheaper per read, and a user setting the device clock back cannot freeze the
  /// window. It does NOT advance while an iOS/Android device sleeps, so the
  /// owner must call [resetWindow] when the app resumes.
  ReadRecorder({
    required void Function(SdkEvent event) sink,
    int Function()? nowMs,
  }) : this._(sink, nowMs ?? _monotonicMs());

  ReadRecorder._(void Function(SdkEvent event) sink, int Function() nowMs)
      : _sink = sink,
        _nowMs = nowMs,
        _windowStartMs = nowMs();

  final void Function(SdkEvent event) _sink;
  final int Function() _nowMs;
  int _windowStartMs;

  /// userId -> flagKey -> variations already reported this window.
  Map<String, Map<String, Set<String>>> _seen = <String, Map<String, Set<String>>>{};

  static int Function() _monotonicMs() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  /// Starts a new window now, with nothing seen: the next read of every
  /// (flag, variation, user) is reported again. The client calls this when the
  /// app resumes, because the monotonic clock stood still while the device
  /// slept. Without it, a read reported before a 30 h sleep would stay deduped
  /// after waking and the server's last report would be older than the archive
  /// guard's 24 h. Off the hot path.
  void resetWindow() {
    _seen = <String, Map<String, Set<String>>>{};
    _windowStartMs = _nowMs();
  }

  /// Records one read of [flagKey]. [variation] is the served variation key, or
  /// null when the flag is absent from the snapshot. [userId] is the current
  /// context's `user_id`.
  void record(String flagKey, String? variation, String? userId) {
    final now = _nowMs();
    if (now - _windowStartMs >= _windowMs) {
      // Replaced rather than cleared, so maps grown in a busy hour don't keep
      // their capacity forever.
      _seen = <String, Map<String, Set<String>>>{};
      _windowStartMs = now;
    }

    final user = userId ?? _absent;
    final arm = variation ?? _absent;
    final byFlag = _seen[user];
    if (byFlag == null) {
      _seen[user] = <String, Set<String>>{
        flagKey: <String>{arm},
      };
    } else {
      final arms = byFlag[flagKey];
      if (arms == null) {
        byFlag[flagKey] = <String>{arm};
      } else if (arms.contains(arm)) {
        return; // The hot path: a repeat read. Nothing allocated, nothing sent.
      } else {
        arms.add(arm);
      }
    }

    _sink(SdkEvent(
      type: 'Evaluation',
      flagKey: flagKey,
      userId: userId,
      variation: variation,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    ));
  }
}
