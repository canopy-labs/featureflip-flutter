import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:featureflip/src/event_processor.dart';
import 'package:featureflip/src/http_client.dart';
import 'package:featureflip/src/models.dart';

void main() {
  group('EventProcessor', () {
    test('flush sends buffered events', () async {
      List<dynamic>? sentEvents;
      final mockClient = http_testing.MockClient((request) async {
        final body = jsonDecode(request.body);
        sentEvents = body['events'] as List<dynamic>;
        return http.Response('', 202);
      });

      final httpClient = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: mockClient,
      );

      final processor = EventProcessor(
        httpClient: httpClient,
        flushInterval: const Duration(minutes: 10),
        batchSize: 100,
      );

      processor.enqueue(const SdkEvent(
        type: 'purchase',
        timestamp: '2024-01-01T00:00:00Z',
      ));

      await processor.flush();

      expect(sentEvents, isNotNull);
      expect(sentEvents!.length, 1);
      expect(sentEvents![0]['type'], 'purchase');
    });

    test('flush does nothing when buffer is empty', () async {
      bool wasCalled = false;
      final mockClient = http_testing.MockClient((_) async {
        wasCalled = true;
        return http.Response('', 202);
      });

      final httpClient = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: mockClient,
      );

      final processor = EventProcessor(
        httpClient: httpClient,
        flushInterval: const Duration(minutes: 10),
        batchSize: 100,
      );

      await processor.flush();
      expect(wasCalled, isFalse);
    });

    test('auto-flushes when batch size is reached', () async {
      List<dynamic>? sentEvents;
      final mockClient = http_testing.MockClient((request) async {
        final body = jsonDecode(request.body);
        sentEvents = body['events'] as List<dynamic>;
        return http.Response('', 202);
      });

      final httpClient = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: mockClient,
      );

      final processor = EventProcessor(
        httpClient: httpClient,
        flushInterval: const Duration(minutes: 10),
        batchSize: 2,
      );

      processor.enqueue(const SdkEvent(type: 'a', timestamp: '2024-01-01T00:00:00Z'));
      processor.enqueue(const SdkEvent(type: 'b', timestamp: '2024-01-01T00:00:01Z'));

      // Give the fire-and-forget future a moment to complete
      await Future.delayed(const Duration(milliseconds: 50));

      expect(sentEvents, isNotNull);
      expect(sentEvents!.length, 2);
    });

    /// Regression guards for #2456.
    ///
    /// The buffer is emptied before the send, so everything here turns on what
    /// happens in the `catch`. Flutter already restored the batch — unlike the
    /// server SDKs, which dropped it — but it restored on ANY error and had no
    /// guard on the size trigger, so a failing endpoint got one request per
    /// recorded event.

    FeatureflipHttpClient clientReturning(
      int status, {
      List<int>? statuses,
      List<int>? batchSizes,
      int? failFirst,
    }) {
      var call = 0;
      return FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: http_testing.MockClient((request) async {
          final body = jsonDecode(request.body);
          final events = body['events'] as List<dynamic>;
          call++;
          final code = statuses != null && call <= statuses.length
              ? statuses[call - 1]
              : (failFirst != null && call <= failFirst ? status : 202);
          if (code >= 200 && code < 300) batchSizes?.add(events.length);
          return http.Response('', code);
        }),
      );
    }

    EventProcessor processorFor(
      FeatureflipHttpClient client, {
      int batchSize = 100,
      Duration flushInterval = const Duration(minutes: 10),
    }) =>
        EventProcessor(
          httpClient: client,
          flushInterval: flushInterval,
          batchSize: batchSize,
        );

    SdkEvent evt(String type) =>
        SdkEvent(type: type, timestamp: '2024-01-01T00:00:00Z');

    test('a 503 keeps the batch for the next flush', () async {
      final sizes = <int>[];
      final processor = processorFor(
        clientReturning(503, statuses: [503, 202], batchSizes: sizes),
      );

      processor.enqueue(evt('a'));
      await processor.flush();
      await processor.flush();

      expect(sizes, [1], reason: 'the retried batch must arrive exactly once');
    });

    test('a permanently rejected batch is dropped rather than retried forever',
        () async {
      var calls = 0;
      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: http_testing.MockClient((_) async {
          calls++;
          return http.Response('', 401);
        }),
      );
      final processor = processorFor(client);

      processor.enqueue(evt('a'));
      await processor.flush();
      await processor.flush();

      // Retrying a rejected SDK key forever would pin the buffer at its bound
      // and starve every later event.
      expect(calls, 1);
    });

    test('a failing endpoint does not get one request per recorded event',
        () async {
      var calls = 0;
      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: http_testing.MockClient((_) async {
          calls++;
          return http.Response('', 503);
        }),
      );
      // batchSize 1: every enqueue trips the size trigger.
      final processor = processorFor(client, batchSize: 1);

      for (var i = 0; i < 10; i++) {
        processor.enqueue(evt('e$i'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls, 1,
          reason: 'the re-queued batch leaves the buffer at the batch size, so '
              'without a backoff every later event starts another flush');
    });

    test('never puts more than a batch in one request', () async {
      final sizes = <int>[];
      // First send fails, so a backlog builds behind the backoff gate.
      final client = clientReturning(503, statuses: [503], batchSizes: sizes);
      final processor = processorFor(client, batchSize: 2);

      for (var i = 0; i < 5; i++) {
        processor.enqueue(evt('e$i'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await processor.flush();

      expect(sizes.isNotEmpty, isTrue);
      // A backlog must never go out as one oversized request: a 413 is
      // non-retryable, so the path preserving it would be the one discarding it.
      for (final n in sizes) {
        expect(n, lessThanOrEqualTo(2), reason: 'a request carried $n events');
      }
      expect(sizes.fold<int>(0, (a, b) => a + b), 5);
    });

    test('stop() returns even while the endpoint is down', () async {
      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'key',
        client: http_testing.MockClient((_) async => http.Response('', 503)),
      );
      final processor = processorFor(client);
      processor.enqueue(evt('a'));

      // Nothing flushes after stop, so a still-failing endpoint must not hang
      // shutdown by looping until the buffer empties.
      await expectLater(processor.stop(), completes);
    });
  });
}
