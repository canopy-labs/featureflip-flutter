import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'models.dart';

/// Connects to the evaluation API SSE stream for real-time flag updates.
class StreamingDataSource {
  static const initialBackoff = Duration(seconds: 1);
  static const maxBackoff = Duration(seconds: 30);
  static const maxRetries = 5;

  final String baseUrl;
  final String clientKey;
  Map<String, dynamic> _context;
  final void Function(Map<String, FlagValue> flags) onChange;
  // Full snapshot the server sends first on every (re)connect -> apply as a REPLACE.
  final void Function(Map<String, FlagValue> flags)? onSnapshot;
  final void Function()? onMaxRetriesReached;
  final http.Client _client;

  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  Duration _backoff = initialBackoff;
  int _retryCount = 0;
  bool _closed = false;
  String? _connectionId;

  StreamingDataSource({
    required this.baseUrl,
    required this.clientKey,
    required Map<String, dynamic> context,
    required this.onChange,
    this.onSnapshot,
    this.onMaxRetriesReached,
    http.Client? client,
  })  : _context = Map.of(context),
        _client = client ?? http.Client();

  /// Builds the SSE stream URL with authorization and context query params.
  static Uri buildStreamUri(
    String baseUrl,
    String clientKey,
    Map<String, dynamic> context,
  ) {
    final contextJson = jsonEncode(context);
    final encodedContext = base64Encode(utf8.encode(contextJson));
    return Uri.parse('$baseUrl/v1/client/stream').replace(
      queryParameters: {
        'authorization': clientKey,
        'context': encodedContext,
      },
    );
  }

  /// Starts the SSE connection. Cancels any existing connection first.
  void start() {
    stop();
    _closed = false;
    _retryCount = 0;
    _backoff = initialBackoff;
    _connect();
  }

  /// Stops the SSE connection.
  void stop() {
    _closed = true;
    _connectionId = null;
    _subscription?.cancel();
    _subscription = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Updates the context and reconnects.
  void updateContext(Map<String, dynamic> context) {
    _context = Map.of(context);
    stop();
    start();
  }

  bool get isMaxRetriesReached => _retryCount >= maxRetries;

  /// The connection ID received from the server via connection-ready event.
  String? get connectionId => _connectionId;

  void _connect() {
    if (_closed) return;

    final uri = buildStreamUri(baseUrl, clientKey, _context);
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream';

    _client.send(request).then((response) {
      if (response.statusCode != 200) {
        _scheduleRetry();
        return;
      }

      // Reset backoff on successful connection.
      _backoff = initialBackoff;
      _retryCount = 0;

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      final buffer = <String>[];
      _subscription = lines.listen(
        (line) {
          if (line.isEmpty) {
            if (buffer.isNotEmpty) {
              _handleEventLines(buffer);
              buffer.clear();
            }
          } else {
            buffer.add(line);
          }
        },
        onError: (_) => _scheduleRetry(),
        onDone: () => _scheduleRetry(),
      );
    }).catchError((_) {
      _scheduleRetry();
    });
  }

  void _scheduleRetry() {
    if (_closed) return;

    // Cancel any existing timer to prevent overlapping retries
    _retryTimer?.cancel();
    _retryTimer = null;

    _retryCount++;
    if (_retryCount >= maxRetries) {
      onMaxRetriesReached?.call();
      return;
    }

    // The ladder state (_backoff) stays un-jittered so the doubling is exact;
    // only the scheduled wait is scattered.
    _retryTimer = Timer(withJitter(_backoff), () {
      _backoff = _nextBackoff(_backoff);
      _connect();
    });
  }

  static Duration _nextBackoff(Duration current) {
    final next = current * 2;
    return next > maxBackoff ? maxBackoff : next;
  }

  /// Returns a value in [d/2, d] to de-correlate reconnects across many SDK
  /// instances (thundering-herd avoidance after a shared outage).
  ///
  /// Applied to EVERY reconnect, including the first. The drops this absorbs are
  /// fleet-wide — one edge event severs every stream at once (#2457) — so every
  /// client re-enters the backoff together. Scheduling the raw [_backoff] there
  /// republished the drop's own synchronisation as a reconnect spike one backoff
  /// later (#2508). The band stays strictly positive, so a stream that fails
  /// immediately still cannot busy-loop.
  static Duration withJitter(Duration d) {
    if (d <= Duration.zero) return d;
    final half = d.inMicroseconds ~/ 2;
    return Duration(microseconds: half + _random.nextInt(half + 1));
  }

  static final _random = math.Random();

  void _handleEventLines(List<String> lines) {
    String? eventType;
    final dataParts = <String>[];

    for (final line in lines) {
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trimLeft();
      } else if (line.startsWith('data:')) {
        dataParts.add(line.substring(5).trimLeft());
      }
    }

    final data = dataParts.join('\n');
    if (data.isEmpty) return;

    if (eventType == 'connection-ready') {
      try {
        final parsed = jsonDecode(data) as Map<String, dynamic>;
        _connectionId = parsed['connectionId'] as String?;
      } catch (_) {}
      return;
    }

    if (eventType != 'flags-updated') return;

    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final response = EvaluateResponse.fromJson(json);
      // The connect-time snapshot is marked `full: true` (#1873) -> REPLACE the store
      // (drops flags deleted during the outage). Deltas omit it -> MERGE. Keyed off the
      // explicit marker, not event order, so a delta racing ahead of the snapshot can't
      // be mistaken for a full replace.
      if (json['full'] == true) {
        (onSnapshot ?? onChange)(response.flags);
      } else {
        onChange(response.flags);
      }
    } catch (_) {
      // Ignore parse errors
    }
  }
}
