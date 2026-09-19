import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:featureflip/src/http_client.dart';
import 'package:featureflip/src/models.dart';
import 'package:featureflip/src/polling_data_source.dart';

void main() {
  group('PollingDataSource', () {
    test('pollOnce fetches and calls onChange', () async {
      final received = <Map<String, FlagValue>>[];
      final mockClient = MockClient((request) async => http.Response(
            jsonEncode({
              'flags': {
                'feature': {
                  'value': true,
                  'variation': 'on',
                  'reason': 'FALLTHROUGH',
                }
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
          ));

      final poller = PollingDataSource(
        httpClient: FeatureflipHttpClient(
          baseUrl: 'https://eval.example.com',
          clientKey: 'key',
          client: mockClient,
        ),
        context: {'user_id': 'u1'},
        interval: const Duration(minutes: 1),
        onChange: received.add,
      );

      await poller.pollOnce();

      expect(received, hasLength(1));
      expect(received.first.containsKey('feature'), isTrue);
    });

    test('a poll already on the wire does not deliver after stop', () async {
      // Cancelling the timer cannot recall a request already in flight: the awaited
      // future still completes and onChange still fires. That is only harmless while
      // a poller is stopped alongside everything else — #3075 retires the fallback
      // poller while the recovered stream is live, so a late response would REPLACE
      // the store on top of the stream's fresher connect snapshot and stay wrong
      // until the flag next changed.
      final received = <Map<String, FlagValue>>[];
      var requests = 0;
      final mockClient = MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'flags': {
              'feature': {
                'value': true,
                'variation': 'on',
                'reason': 'FALLTHROUGH',
              }
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final poller = PollingDataSource(
        httpClient: FeatureflipHttpClient(
          baseUrl: 'https://eval.example.com',
          clientKey: 'key',
          client: mockClient,
        ),
        context: {'user_id': 'u1'},
        interval: const Duration(minutes: 1),
        onChange: received.add,
      );

      poller.stop();
      await poller.pollOnce();

      expect(received, isEmpty,
          reason: 'a response that arrives after stop() must not reach the store');
      expect(requests, 1,
          reason: 'the request itself is not recallable — only its delivery '
              'is suppressed');
    });
  });
}
