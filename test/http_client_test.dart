import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:featureflip/src/http_client.dart';

void main() {
  group('FeatureflipHttpClient', () {
    test('evaluate sends POST with correct headers and body', () async {
      http.Request? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'flags': {
              'flag': {'value': true, 'variation': 'v1', 'reason': 'RULE'}
            }
          }),
          200,
        );
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'sdk-key-123',
        client: mockClient,
      );

      final response = await client.evaluate({'user_id': 'u1'});

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.url.path, '/v1/client/evaluate');
      expect(capturedRequest!.headers['Authorization'], 'sdk-key-123');
      expect(capturedRequest!.headers['Content-Type'], 'application/json');

      final body = jsonDecode(capturedRequest!.body);
      expect(body['context']['user_id'], 'u1');
      expect(response.flags['flag']!.value, isTrue);
    });

    test('identify sends POST to /v1/client/identify', () async {
      http.Request? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'flags': {
              'flag': {'value': 'new', 'variation': 'v2', 'reason': 'RuleMatch'}
            }
          }),
          200,
        );
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'sdk-key-123',
        client: mockClient,
      );

      final response = await client.identify({'user_id': 'u2'});

      expect(capturedRequest!.url.path, '/v1/client/identify');
      expect(response.flags['flag']!.value, 'new');
    });

    test('identify sends X-Connection-Id header when connectionId provided', () async {
      http.Request? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'flags': {
              'flag': {'value': true, 'variation': 'v1', 'reason': 'RULE'}
            }
          }),
          200,
        );
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'sdk-key-123',
        client: mockClient,
      );

      await client.identify({'user_id': 'u1'}, connectionId: 'conn-abc-123');

      expect(capturedRequest!.headers['X-Connection-Id'], 'conn-abc-123');
    });

    test('identify omits X-Connection-Id header when connectionId is null', () async {
      http.Request? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'flags': {
              'flag': {'value': true, 'variation': 'v1', 'reason': 'RULE'}
            }
          }),
          200,
        );
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'sdk-key-123',
        client: mockClient,
      );

      await client.identify({'user_id': 'u1'});

      expect(capturedRequest!.headers['X-Connection-Id'], isNull);
    });

    test('throws on non-2xx response', () async {
      final mockClient = http_testing.MockClient((_) async {
        return http.Response('Unauthorized', 401);
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'bad-key',
        client: mockClient,
      );

      expect(
        () => client.evaluate({}),
        throwsA(isA<FeatureflipHttpException>()),
      );
    });

    test('postEvents sends events to /v1/sdk/events', () async {
      http.Request? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 202);
      });

      final client = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'sdk-key-123',
        client: mockClient,
      );

      await client.postEvents([]);

      expect(capturedRequest!.url.path, '/v1/sdk/events');
      expect(capturedRequest!.headers['Authorization'], 'sdk-key-123');
    });
  });
}
