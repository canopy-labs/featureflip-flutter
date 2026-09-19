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
  // Required, not nullable-falling-back-to-onChange: an omitted snapshot handler would
  // silently merge the connect snapshot and resurrect flags deleted during the outage
  // (#1873), and no dispatch test can see that -- they all pass it explicitly.
  final void Function(Map<String, FlagValue> flags) onSnapshot;
  // Invoked ONCE per outage, when the stream has failed [maxRetries] times, so the
  // core can start polling ALONGSIDE this still-retrying stream. Never a terminal
  // give-up: retries continue at the capped backoff (#3075).
  final void Function()? onFallbackToPolling;
  // Invoked when a stream that had fallen back delivers a frame again, so the core
  // can retire the fallback poller.
  final void Function()? onStreamRecovered;
  final http.Client _client;

  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  // The delay the first reconnect waits, and the value backoff resets to. Held as an
  // instance field (rather than reading the static) so tests can drive the retry cap
  // without waiting out the real 1s-and-doubling schedule — mirrors the android
  // source's `initialBackoffMs` and swift's `initialBackoff`.
  final Duration _baseBackoff;
  Duration _backoff;
  int _retryCount = 0;
  // True between arming the polling fallback and the next delivered frame. Gates both
  // callbacks so each fires once per outage rather than once per retry.
  //
  // Deliberately NOT cleared by [start]: that is reachable from the core's foreground
  // handler and [updateContext] while a fallback poller is live, and clearing it there
  // would lose the only record that a poller is waiting to be retired — leaving it
  // running beside a recovered stream forever, which is the defect this fixes.
  bool _fallbackActive = false;
  bool _closed = false;
  // Identity of the current connection attempt, bumped by [_connect] and again by
  // [_scheduleRetry]. Callbacks carry the generation they were registered under, so a
  // superseded or already-retired connection cannot act on this source.
  int _connectionGeneration = 0;
  String? _connectionId;

  StreamingDataSource({
    required this.baseUrl,
    required this.clientKey,
    required Map<String, dynamic> context,
    required this.onChange,
    required this.onSnapshot,
    this.onFallbackToPolling,
    this.onStreamRecovered,
    Duration initialBackoff = StreamingDataSource.initialBackoff,
    http.Client? client,
  })  : _context = Map.of(context),
        _baseBackoff = initialBackoff,
        _backoff = initialBackoff,
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
    _backoff = _baseBackoff;
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

  /// Whether the polling fallback is currently armed — i.e. the stream has exhausted
  /// its retry budget and has not delivered a frame since. Visible for testing; the
  /// stream keeps retrying regardless.
  bool get hasFallenBackToPolling => _fallbackActive;

  /// Consecutive failed connect attempts. Visible for testing, so a test can show the
  /// source still reconnecting past [maxRetries].
  int get retryAttempts => _retryCount;

  /// The connection ID received from the server via connection-ready event.
  String? get connectionId => _connectionId;

  void _connect() {
    if (_closed) return;

    // Every attempt gets an identity, and every callback carries it. That is what
    // makes a connection able to spend exactly one retry, and what stops a response
    // that arrives after its attempt was superseded from installing itself.
    final generation = ++_connectionGeneration;

    final uri = buildStreamUri(baseUrl, clientKey, _context);
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream';

    _client.send(request).then((response) {
      if (_closed || generation != _connectionGeneration) {
        // stop(), updateContext() or a retry superseded this attempt while its
        // request was still in flight. Installing its subscription here would leave
        // TWO live SSE connections — the older one unreferenced, so nothing could
        // ever stop it — both feeding the store, the older with staler evaluations.
        // Cancel rather than ignore, or the socket is held open for nothing.
        response.stream.listen(null).cancel();
        return;
      }
      if (response.statusCode != 200) {
        _scheduleRetry(generation);
        return;
      }

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
        onError: (_) => _scheduleRetry(generation),
        onDone: () => _scheduleRetry(generation),
      );
    }).catchError((_) {
      _scheduleRetry(generation);
    });
  }

  /// Schedules the reconnect for the connection identified by [generation].
  ///
  /// At most ONE retry per connection. A stream that errors and then closes fires
  /// both `onError` and `onDone` — `cancelOnError` defaults to false — and the send
  /// future's `catchError` can fire alongside either. Without this, one failed
  /// connection spent two of the five retries, so the effective budget was below the
  /// documented cap in that failure shape; it mattered more once the counter stopped
  /// resetting on every 200 (#3075). Worse, the second call also scheduled a second
  /// [_connect] while the first was still in flight, and `_retryTimer?.cancel()`
  /// cannot cancel a timer that has already fired — which is how two live SSE
  /// connections became representable, only the newer one referenced.
  ///
  /// Bumping the generation is what enforces it: every later callback from this
  /// connection sees a stale identity and returns.
  void _scheduleRetry(int generation) {
    if (_closed) return;
    if (generation != _connectionGeneration) return;
    _connectionGeneration++;

    // This connection is finished with; releasing it here is also what stops its
    // sibling callback ever running.
    _subscription?.cancel();
    _subscription = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    _retryCount++;
    // The fallback is ADDITIVE, never terminal (#3075). Polling covers the outage
    // while this source keeps retrying the stream underneath at the capped backoff,
    // and the next delivered frame retires the poller. Returning here instead left
    // the app polling — and blind to real-time updates, kill switches included —
    // until it was restarted, after only ~31s of unreachability.
    if (_retryCount >= maxRetries && !_fallbackActive) {
      _fallbackActive = true;
      onFallbackToPolling?.call();
    }

    // The ladder state (_backoff) stays un-jittered so the doubling is exact;
    // only the scheduled wait is scattered.
    _retryTimer = Timer(withJitter(_backoff), () {
      _backoff = _nextBackoff(_backoff);
      _connect();
    });
  }

  /// DELIVERED CONFIG — not merely an accepted socket — is what proves the stream
  /// healthy, and it is the condition the rest of the fleet resets on (js and java on
  /// `sync`, go on its first complete frame, which for the server stream *is* `sync`).
  /// Resetting on the 200 instead let an accept-then-close server clear the counter
  /// every cycle, so the retry budget was never exhausted, the polling fallback could
  /// never arm, and the app saw nothing at all for the duration of such an outage
  /// (#3074).
  ///
  /// Reached only from the `flags-updated` branch, never from `connection-ready`: the
  /// client stream's FIRST frame is that ~40-byte handshake and it carries no config,
  /// so a server that accepts, greets and dies would otherwise reset the budget
  /// forever and re-open exactly the hole above. Deliberately still counted when the
  /// payload fails to parse — the stream itself is demonstrably up, the store keeps
  /// its last-known-good, and the parse failure is reported on its own path.
  ///
  /// Recovery is signalled from HERE rather than from the retry path: a healthy
  /// stream's subscription stays open indefinitely, so waiting for it to close before
  /// reaping would leave the poller alive that entire time, its periodic whole-store
  /// replaces reverting the deltas this stream applies.
  void _configDelivered() {
    _retryCount = 0;
    _backoff = _baseBackoff;
    if (!_fallbackActive) return;
    _fallbackActive = false;
    onStreamRecovered?.call();
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
        onSnapshot(response.flags);
      } else {
        onChange(response.flags);
      }
    } catch (_) {
      // Ignore parse errors
    }

    // AFTER the store has been updated, never before: retiring the fallback poller is
    // what this signals, and a poller retired one frame early can still land an older
    // whole-store replace on top of the snapshot just applied.
    _configDelivered();
  }
}
