import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:featureflip/src/models.dart';
import 'package:featureflip/src/streaming_data_source.dart';

void main() {
  group('StreamingDataSource', () {
    test('buildStreamUri encodes authorization and context', () {
      final uri = StreamingDataSource.buildStreamUri(
        'https://eval.example.com',
        'client-key-123',
        {'user_id': 'u1'},
      );

      expect(uri.path, '/v1/client/stream');
      expect(uri.queryParameters['authorization'], 'client-key-123');

      final encodedContext = uri.queryParameters['context']!;
      final decodedContext = utf8.decode(base64Decode(encodedContext));
      final context = jsonDecode(decodedContext) as Map<String, dynamic>;
      expect(context['user_id'], 'u1');
    });

    test('buildStreamUri handles empty context', () {
      final uri = StreamingDataSource.buildStreamUri(
        'https://eval.example.com',
        'key',
        {},
      );

      final encodedContext = uri.queryParameters['context']!;
      final decodedContext = utf8.decode(base64Decode(encodedContext));
      expect(decodedContext, '{}');
    });

    test('connectionId is null before connection-ready event', () {
      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
      );

      expect(ds.connectionId, isNull);
    });

    test('flags-updated with full=true replaces; without full merges', () async {
      final snapshots = <Map<String, FlagValue>>[];
      final deltas = <Map<String, FlagValue>>[];

      String flag(String key) =>
          '"$key":{"value":true,"variation":"on","reason":"FALLTHROUGH"}';
      // The connect-time snapshot carries `full: true` (#1873); deltas omit it. The
      // replace decision is keyed off the marker, not event order.
      final sse = 'event: connection-ready\ndata: {"connectionId":"c1"}\n\n'
          'event: flags-updated\ndata: {"full":true,"flags":{${flag("flag-a")}}}\n\n'
          'event: flags-updated\ndata: {"flags":{${flag("flag-b")}}}\n\n';

      final mockClient = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(sse)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (f) => deltas.add(f),
        onSnapshot: (f) => snapshots.add(f),
        client: mockClient,
      );
      ds.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ds.stop();

      expect(snapshots.length, 1);
      expect(snapshots.first.containsKey('flag-a'), isTrue);
      expect(deltas.length, 1);
      expect(deltas.first.containsKey('flag-b'), isTrue);
    });

    test('a stream that stays down arms the fallback once and keeps retrying',
        () async {
      // The fallback is ADDITIVE, never terminal (#3075). Returning out of the retry
      // path at the cap left the app blind to real-time updates — kill switches
      // included — until it was restarted, after ~31s of unreachability.
      var armings = 0;
      var attempts = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        attempts++;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 500);
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
        onFallbackToPolling: () => armings++,
        // Keep the 5-retry schedule but collapse its wall-clock.
        initialBackoff: const Duration(milliseconds: 1),
        client: mockClient,
      );
      ds.start();

      await _waitUntil(() => ds.hasFallenBackToPolling);
      expect(ds.hasFallenBackToPolling, isTrue,
          reason: 'the fallback should arm once the retry budget is spent');

      final atCap = attempts;
      await _waitUntil(
          () => ds.retryAttempts > StreamingDataSource.maxRetries + 2);
      final after = ds.retryAttempts;
      ds.stop();

      expect(after, greaterThan(StreamingDataSource.maxRetries),
          reason: 'the stream must keep retrying past the cap (attempts at '
              'arming: $atCap), not give up');
      expect(armings, 1,
          reason: 'the fallback arms once per outage, not once per retry');
    });

    test('a recovered stream retires the fallback on its first delivered frame',
        () async {
      var recoveries = 0;
      var armed = false;
      var attempts = 0;

      String flag(String key) =>
          '"$key":{"value":true,"variation":"on","reason":"FALLTHROUGH"}';
      final sse = 'event: flags-updated\n'
          'data: {"full":true,"flags":{${flag("flag-a")}}}\n\n'
          'event: flags-updated\ndata: {"flags":{${flag("flag-b")}}}\n\n';

      final mockClient = MockClient.streaming((request, bodyStream) async {
        attempts++;
        if (attempts <= StreamingDataSource.maxRetries) {
          return http.StreamedResponse(const Stream<List<int>>.empty(), 500);
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode(sse)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
        onFallbackToPolling: () => armed = true,
        onStreamRecovered: () => recoveries++,
        initialBackoff: const Duration(milliseconds: 1),
        client: mockClient,
      );
      ds.start();

      await _waitUntil(() => recoveries > 0);
      ds.stop();

      expect(armed, isTrue,
          reason: 'the fallback should arm while the stream is down');
      expect(recoveries, 1,
          reason: 'recovery is signalled once per outage, not once per frame — '
              'the stream delivered two frames');
      expect(ds.hasFallenBackToPolling, isFalse);
    });

    test('a stream that opens but delivers nothing still arms the fallback',
        () async {
      // Regression: resetting the retry counter on the 200 rather than on a
      // delivered frame let an accept-then-close server clear it every cycle, so the
      // budget was never exhausted, the fallback never armed, and the app saw
      // nothing at all for the whole outage (#3074).
      var armed = false;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
        onFallbackToPolling: () => armed = true,
        initialBackoff: const Duration(milliseconds: 1),
        client: mockClient,
      );
      ds.start();

      await _waitUntil(() => armed);
      ds.stop();

      expect(armed, isTrue,
          reason: 'a 200 that delivers no frame is not a recovery');
    });

    test('a stream that only ever sends connection-ready still arms the fallback',
        () async {
      // connection-ready is the client stream's FIRST frame and carries no config —
      // a ~40-byte handshake. Counting it as a recovery would let a server that
      // accepts, greets and dies reset the retry budget every cycle, which is exactly
      // the accept-then-close hole #3074 closed. The fleet keys this on delivered
      // CONFIG (js and java on `sync`, go on its first complete frame, which for the
      // server stream IS `sync`), so the mobile SDKs key on `flags-updated`.
      var armed = false;
      var recoveries = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(
              utf8.encode('event: connection-ready\ndata: {"connectionId":"c1"}\n\n')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
        onFallbackToPolling: () => armed = true,
        onStreamRecovered: () => recoveries++,
        initialBackoff: const Duration(milliseconds: 1),
        client: mockClient,
      );
      ds.start();

      await _waitUntil(() => armed);
      ds.stop();

      expect(armed, isTrue,
          reason: 'a greeting frame carrying no config is not a recovery');
      expect(recoveries, 0,
          reason: 'connection-ready must never retire the fallback poller');
    });

    test('a connection that errors and then closes spends exactly one retry',
        () async {
      // _scheduleRetry is wired to both onError and onDone, and cancelOnError
      // defaults to false — so this failure shape fired it twice and burned two of
      // the five retries, putting the effective budget below the documented cap.
      var attempts = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        attempts++;
        return http.StreamedResponse(
          _errorThenClose(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
        onSnapshot: (_) {},
        // Long enough that the legitimate NEXT retry cannot land inside the
        // assertion window, so a second count can only come from this connection.
        initialBackoff: const Duration(seconds: 10),
        client: mockClient,
      );
      ds.start();

      await _waitUntil(() => ds.retryAttempts >= 1);
      // Give the sibling callback every chance to land.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ds.stop();

      expect(ds.retryAttempts, 1,
          reason: 'onError and onDone from one connection must not each spend a '
              'retry');
      expect(attempts, 1,
          reason: 'a second _connect() must not be scheduled while the first '
              'connection is still being torn down');
    });

    test('a connect superseded while its request was in flight cannot feed the store',
        () async {
      // identify() takes exactly this path: updateContext() -> stop() then start(),
      // which can happen while the previous send is still in flight. Installing that
      // response's subscription afterwards left two live SSE connections with only
      // the newer one referenced — and the older, staler one could still write to
      // the store. `_retryTimer?.cancel()` cannot cancel an already-fired timer, so
      // the retry path reached the same state.
      final gate = Completer<void>();
      final stale = StreamController<List<int>>();
      var connects = 0;

      final mockClient = MockClient.streaming((request, bodyStream) async {
        connects++;
        if (connects == 1) {
          await gate.future; // hold the first attempt's request in flight
          return http.StreamedResponse(
            stale.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final snapshots = <Map<String, FlagValue>>[];
      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {'user_id': 'u1'},
        onChange: (_) {},
        onSnapshot: snapshots.add,
        initialBackoff: const Duration(seconds: 10),
        client: mockClient,
      );
      ds.start();
      await _waitUntil(() => connects == 1);

      ds.updateContext({'user_id': 'u2'});
      await _waitUntil(() => connects == 2);

      gate.complete(); // the superseded response finally arrives
      await Future<void>.delayed(const Duration(milliseconds: 20));
      stale.add(utf8.encode('event: flags-updated\n'
          'data: {"full":true,"flags":{"stale":{"value":true,"variation":"on",'
          '"reason":"FALLTHROUGH"}}}\n\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      ds.stop();
      await stale.close();

      expect(snapshots, isEmpty,
          reason: 'a superseded connection must never reach the store');
    });
  });

  group('reconnect jitter (#2508)', () {
    // The drops this backoff absorbs are fleet-wide: one edge event severs every
    // stream at once (#2457 — measured at a 2.5-3.0ms spread across both eval-api
    // pods), so every client re-enters the backoff together. A constant delay there
    // republishes the drop's own synchronisation as a reconnect spike one backoff
    // later.
    test('scatters a delay instead of returning it unchanged', () {
      const base = StreamingDataSource.initialBackoff;
      final samples = <Duration>{};
      for (var i = 0; i < 200; i++) {
        samples.add(StreamingDataSource.withJitter(base));
      }

      expect(
        samples.length,
        greaterThan(1),
        reason: 'reconnect delay is deterministic — a fleet-wide drop reconnects in lockstep',
      );
      for (final d in samples) {
        expect(d, greaterThanOrEqualTo(base ~/ 2));
        expect(d, lessThanOrEqualTo(base));
        expect(d, greaterThan(Duration.zero)); // anti-busy-loop
      }
    });

    test('caps and floors degenerate inputs', () {
      expect(StreamingDataSource.withJitter(Duration.zero), Duration.zero);
      final capped = StreamingDataSource.withJitter(StreamingDataSource.maxBackoff);
      expect(capped, greaterThanOrEqualTo(StreamingDataSource.maxBackoff ~/ 2));
      expect(capped, lessThanOrEqualTo(StreamingDataSource.maxBackoff));
    });
  });
}

/// Polls [cond] until it holds or the timeout elapses. Returns either way — the
/// caller asserts, so a timeout surfaces as the real expectation failing rather than
/// as an opaque "future did not complete".
Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A body that emits an error and then closes — the shape that fires `onError`
/// followed by `onDone` on one subscription (`cancelOnError` defaults to false).
Stream<List<int>> _errorThenClose() async* {
  yield utf8.encode('event: ping\n\n');
  throw Exception('stream broke');
}
