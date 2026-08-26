import 'dart:async';

import 'package:flutter/foundation.dart';

import 'http_client.dart';
import 'models.dart';

/// Batches analytics events and flushes them to the evaluation API.
class EventProcessor {
  final FeatureflipHttpClient _httpClient;
  final int _batchSize;
  final Duration _flushInterval;

  /// Upper bound on buffered events.
  ///
  /// Deliberately lower than the 10,000 the server SDKs use. This is a mobile
  /// client: memory is tighter and event volume is far lower. What matters for
  /// cross-SDK parity is the rule — shed the OLDEST first — not the number.
  static const _maxBufferSize = 1000;

  List<SdkEvent> _buffer = [];
  Timer? _flushTimer;

  /// When the batch-size trigger may next start a flush.
  ///
  /// A re-queued batch leaves the buffer at or above [_batchSize], so without
  /// this gate every subsequent [enqueue] would start another flush — turning a
  /// failing endpoint into one request per recorded event, which is worse for
  /// the server than losing the events would be. The periodic timer is the
  /// retry vehicle; this only suppresses the size trigger between its ticks.
  DateTime? _nextAutoFlushAt;

  /// True while a size-triggered flush is running.
  ///
  /// The gate above is only armed once a flush has already FAILED, and the size
  /// trigger fires again long before the first round-trip returns — so without
  /// this latch a burst of events still starts a flush each.
  bool _autoFlushInFlight = false;

  /// The drain currently running, if any.
  ///
  /// [_autoFlushInFlight] above only ever guarded the SIZE trigger. Nothing
  /// stopped the periodic timer, an explicit `FeatureflipClient.flush()` and a
  /// size-triggered flush from entering the loop together — two request streams
  /// against the endpoint the backoff gate exists to protect, and a success in
  /// one clearing the gate a failure in the other had just armed, which
  /// re-opens the one-request-per-event behaviour outright (#2477).
  Future<void>? _inFlightDrain;

  bool _closed = false;

  EventProcessor({
    required FeatureflipHttpClient httpClient,
    required Duration flushInterval,
    required int batchSize,
  })  : _httpClient = httpClient,
        _flushInterval = flushInterval,
        // Clamped: [flush] loops on this, so a non-positive value would take
        // nothing per pass and spin on a non-empty buffer.
        _batchSize = batchSize >= 1 ? batchSize : 1;

  /// Starts the periodic flush timer.
  void start() {
    _flushTimer = Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Enqueues an event. Flushes immediately if batch size is reached.
  void enqueue(SdkEvent event) {
    if (_closed) return;
    _buffer.add(event);
    _trimToBound();
    if (_buffer.length >= _batchSize && _canAutoFlush()) {
      _autoFlushInFlight = true;
      unawaited(flush().whenComplete(() => _autoFlushInFlight = false));
    }
  }

  bool _canAutoFlush() {
    if (_autoFlushInFlight) return false;
    final gate = _nextAutoFlushAt;
    return gate == null || !DateTime.now().isBefore(gate);
  }

  /// Flushes buffered events, one request per batch.
  ///
  /// Sending the whole buffer in one request only became a risk once failures
  /// started being re-queued: a backlog can now reach [_maxBufferSize], and a
  /// body that size invites a 413 — which is not retryable, so the path meant
  /// to preserve the backlog would be the one that discarded it.
  ///
  /// At most one drain runs at a time. A caller arriving while one is already
  /// going awaits it and returns — it does NOT start its own, and it does NOT
  /// return early, because a caller that awaited `flush()` is asking for its
  /// events to be sent. Matches the js/node SDKs, whose `flush()` has always
  /// returned the in-flight promise.
  Future<void> flush() async {
    final existing = _inFlightDrain;
    if (existing != null) {
      await existing;
      return;
    }

    final drain = _drain();
    _inFlightDrain = drain;
    try {
      await drain;
    } finally {
      _inFlightDrain = null;
    }
  }

  /// The drain loop itself, callable when coalescing must be bypassed.
  Future<void> _drain() async {
    while (_buffer.isNotEmpty) {
      final take = _buffer.length < _batchSize ? _buffer.length : _batchSize;
      final batch = _buffer.sublist(0, take);
      _buffer = _buffer.sublist(take);

      try {
        await _httpClient.postEvents(batch);
        _nextAutoFlushAt = null;
      } on FeatureflipHttpException catch (err) {
        if (_isRetryableStatus(err.statusCode)) {
          _requeue(batch, err);
          return;
        }
        // A 401/403 means the key was rejected and a 400 means the body is
        // malformed; both fail identically next time. Dropping shrinks the
        // buffer, so the loop still ends, and moving on means one poison batch
        // cannot block the backlog queued behind it.
        debugPrint('[featureflip] dropped ${batch.length} analytics event(s) '
            'the events endpoint rejected permanently: $err');
        if (_closed) return;
      } catch (err) {
        // Anything that is not an HTTP answer is a transport fault or timeout,
        // which a later flush may well get past.
        _requeue(batch, err);
        return;
      }
    }
  }

  static bool _isRetryableStatus(int status) => status >= 500 || status == 429;

  /// Returns a batch that failed to send to the FRONT of the buffer.
  ///
  /// Deliberately not an inline retry: the batch is back in the buffer [flush]
  /// is draining, so re-sending here would spin for as long as the outage
  /// lasted. Handing it back bounds every attempt to one round-trip.
  void _requeue(List<SdkEvent> batch, Object err) {
    if (_closed) {
      // Nothing will flush again, so buffering here would only lose them later.
      debugPrint('[featureflip] dropped ${batch.length} analytics event(s): '
          'shutting down and will not flush again: $err');
      return;
    }
    _nextAutoFlushAt = DateTime.now().add(_flushInterval);
    _buffer.insertAll(0, batch);
    _trimToBound();
    debugPrint('[featureflip] failed to flush ${batch.length} analytics '
        'event(s); re-queued for the next flush: $err');
  }

  /// Sheds oldest-first until the buffer fits [_maxBufferSize].
  void _trimToBound() {
    final overflow = _buffer.length - _maxBufferSize;
    if (overflow <= 0) return;
    _buffer = _buffer.sublist(overflow);
    debugPrint('[featureflip] event buffer is full; dropped $overflow of the '
        'oldest analytics event(s)');
  }

  /// Stops the flush timer and makes one final attempt to deliver.
  Future<void> stop() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    // Set before the flush so a failure inside it discards rather than
    // re-queueing into a buffer nothing will ever drain.
    _closed = true;
    // _drain, not flush: shutdown must never be the call that gets coalesced
    // away. If a periodic drain happens to be in flight, flush() would await it
    // and return, and anything enqueued after that loop's last look at the
    // buffer would be discarded unsent. Two drains overlapping is safe here
    // precisely because [_closed] is already set, so neither can re-queue and
    // there is no backoff left to disarm.
    await _drain();
    _buffer = [];
  }
}
