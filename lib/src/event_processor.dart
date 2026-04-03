import 'dart:async';

import 'http_client.dart';
import 'models.dart';

/// Batches analytics events and flushes them to the evaluation API.
class EventProcessor {
  final FeatureflipHttpClient _httpClient;
  final int _batchSize;
  final Duration _flushInterval;
  static const _maxBufferSize = 1000;
  List<SdkEvent> _buffer = [];
  Timer? _flushTimer;

  EventProcessor({
    required FeatureflipHttpClient httpClient,
    required Duration flushInterval,
    required int batchSize,
  })  : _httpClient = httpClient,
        _flushInterval = flushInterval,
        _batchSize = batchSize;

  /// Starts the periodic flush timer.
  void start() {
    _flushTimer = Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Enqueues an event. Flushes immediately if batch size is reached.
  void enqueue(SdkEvent event) {
    _buffer.add(event);
    if (_buffer.length >= _batchSize) {
      flush();
    }
  }

  /// Flushes all buffered events. Re-enqueues on failure to avoid event loss.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final events = _buffer;
    _buffer = [];
    try {
      await _httpClient.postEvents(events);
    } catch (_) {
      // Re-enqueue failed events, but cap buffer to prevent unbounded growth
      _buffer.insertAll(0, events);
      if (_buffer.length > _maxBufferSize) {
        _buffer = _buffer.sublist(_buffer.length - _maxBufferSize);
      }
    }
  }

  /// Stops the flush timer and flushes remaining events.
  Future<void> stop() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }
}
