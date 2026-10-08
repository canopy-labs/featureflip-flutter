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

    test('postEvents sends events to /v1/client/events', () async {
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

      expect(capturedRequest!.url.path, '/v1/client/events');
      expect(capturedRequest!.headers['Authorization'], 'sdk-key-123');
    });

    group('X-Featureflip-Reports-Evaluations', () {
      const header = 'X-Featureflip-Reports-Evaluations';

      Future<http.Request> capture(
        Future<void> Function(FeatureflipHttpClient client) call, {
        required bool reportsEvaluations,
      }) async {
        http.Request? captured;
        final client = FeatureflipHttpClient(
          baseUrl: 'https://test.example.com',
          clientKey: 'sdk-key-123',
          reportsEvaluations: reportsEvaluations,
          client: http_testing.MockClient((request) async {
            captured = request;
            return request.url.path == '/v1/client/events'
                ? http.Response('', 202)
                : http.Response(jsonEncode({'flags': <String, dynamic>{}}), 200);
          }),
        );
        await call(client);
        return captured!;
      }

      test('the name matches the server contract exactly', () {
        expect(FeatureflipHttpClient.reportsEvaluationsHeader, header);
      });

      test('evaluate sends it when the client reports its reads', () async {
        final request = await capture((c) => c.evaluate({'user_id': 'u1'}), reportsEvaluations: true);
        expect(request.url.path, '/v1/client/evaluate');
        expect(request.headers[header], '1');
      });

      test('identify sends it when the client reports its reads', () async {
        final request = await capture((c) => c.identify({'user_id': 'u1'}), reportsEvaluations: true);
        expect(request.url.path, '/v1/client/identify');
        expect(request.headers[header], '1');
      });

      test('identify keeps X-Connection-Id alongside it', () async {
        final request = await capture(
          (c) => c.identify({'user_id': 'u1'}, connectionId: 'conn-abc-123'),
          reportsEvaluations: true,
        );
        expect(request.headers['X-Connection-Id'], 'conn-abc-123');
        expect(request.headers[header], '1');
        expect(request.headers['Authorization'], 'sdk-key-123');
      });

      test('evaluate and identify omit it when the client does not report its reads', () async {
        final evaluate = await capture((c) => c.evaluate({}), reportsEvaluations: false);
        final identify = await capture((c) => c.identify({}), reportsEvaluations: false);
        expect(evaluate.headers.containsKey(header), isFalse);
        expect(identify.headers.containsKey(header), isFalse);
      });

      test('postEvents never sends it', () async {
        final request = await capture((c) => c.postEvents([]), reportsEvaluations: true);
        expect(request.url.path, '/v1/client/events');
        expect(request.headers.containsKey(header), isFalse);
      });
    });
  });
}
