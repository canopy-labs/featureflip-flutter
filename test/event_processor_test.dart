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
  });
}
