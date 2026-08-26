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
