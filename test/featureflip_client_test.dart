import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/http_client.dart';

Map<String, dynamic> _makeFlagsJson(Map<String, FlagValue> flags) {
  return {
    'flags': flags.map((k, v) => MapEntry(k, v.toJson())),
  };
}

FlagValue _boolFlag(bool value) =>
    FlagValue(value: value, variation: 'v1', reason: 'RULE');



void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // Reset singleton
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      FeatureflipClient.configure(const FeatureflipConfig(clientKey: 'reset'));
    } catch (_) {}
  });

  group('forTesting', () {
    test('returns overridden bool values', () {
      final client = FeatureflipClient.forTesting({'dark-mode': true});
      expect(client.boolVariation('dark-mode', defaultValue: false), isTrue);
    });

    test('returns overridden string values', () {
      final client = FeatureflipClient.forTesting({'greeting': 'hello'});
      expect(client.stringVariation('greeting', defaultValue: 'bye'), 'hello');
    });

    test('returns overridden int values as double', () {
      final client = FeatureflipClient.forTesting({'rate-limit': 42});
      expect(client.numberVariation('rate-limit', defaultValue: 0.0), 42.0);
    });

    test('returns overridden double values', () {
      final client = FeatureflipClient.forTesting({'pi': 3.14});
      expect(client.numberVariation('pi', defaultValue: 0.0), 3.14);
    });

    test('returns default for missing flags', () {
      final client = FeatureflipClient.forTesting({});
      expect(client.boolVariation('nonexistent', defaultValue: false), isFalse);
      expect(client.stringVariation('nonexistent', defaultValue: 'default'), 'default');
      expect(client.numberVariation('nonexistent', defaultValue: 5.0), 5.0);
    });

    test('returns default for wrong type', () {
      final client = FeatureflipClient.forTesting({'flag': 'hello'});
      expect(client.boolVariation('flag', defaultValue: false), isFalse);
    });

    test('is immediately initialized', () {
      final client = FeatureflipClient.forTesting({'flag': true});
      expect(client.isInitialized, isTrue);
    });

    test('supports multiple flag types', () {
      final client = FeatureflipClient.forTesting({
        'bool-flag': true,
        'string-flag': 'value',
        'int-flag': 99,
        'double-flag': 3.14,
      });

      expect(client.boolVariation('bool-flag', defaultValue: false), isTrue);
      expect(client.stringVariation('string-flag', defaultValue: 'default'), 'value');
      expect(client.numberVariation('int-flag', defaultValue: 0.0), 99.0);
      expect(client.numberVariation('double-flag', defaultValue: 0.0), 3.14);
      expect(client.boolVariation('missing', defaultValue: false), isFalse);
    });
  });

  group('boolVariation', () {
    test('returns default when flag is missing', () {
      final client = FeatureflipClient.forTesting({});
      expect(client.boolVariation('nonexistent', defaultValue: false), isFalse);
      expect(client.boolVariation('nonexistent', defaultValue: true), isTrue);
    });
  });

  group('jsonVariation', () {
    test('returns the raw value', () {
      final client = FeatureflipClient.forTesting({'key': 'value'});
      expect(client.jsonVariation('key', defaultValue: null), 'value');
    });

    test('returns default for missing flag', () {
      final client = FeatureflipClient.forTesting({});
      expect(client.jsonVariation('missing', defaultValue: false), isFalse);
    });
  });

  group('allFlags', () {
    test('returns all flags', () {
      final client = FeatureflipClient.forTesting({
        'a': true,
        'b': 'hello',
      });

      final flags = client.allFlags();
      expect(flags.length, 2);
      expect(flags.containsKey('a'), isTrue);
      expect(flags.containsKey('b'), isTrue);
    });
  });

  group('initialize', () {
    test('fetches flags from server', () async {
      final flags = {'dark-mode': _boolFlag(true)};
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode(_makeFlagsJson(flags)),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final httpClient = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'test-key',
        client: mockClient,
      );

      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
        streaming: false,
      );

      final client = FeatureflipClient.withHttpClient(
        config: config,
        httpClient: httpClient,
      );

      await client.initialize();

      expect(client.boolVariation('dark-mode', defaultValue: false), isTrue);
      expect(client.isInitialized, isTrue);

      await client.close();
    });
  });

  group('identify', () {
    test('refetches flags with new context', () async {
      int callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        final flags = callCount <= 2
            ? {'feature': _boolFlag(false)}
            : {'feature': _boolFlag(true)};
        return http.Response(
          jsonEncode(_makeFlagsJson(flags)),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final httpClient = FeatureflipHttpClient(
        baseUrl: 'https://test.example.com',
        clientKey: 'test-key',
        client: mockClient,
      );

      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
        streaming: false,
      );

      final client = FeatureflipClient.withHttpClient(
        config: config,
        httpClient: httpClient,
      );

      await client.initialize();
      expect(client.boolVariation('feature', defaultValue: true), isFalse);

      await client.close();

      await client.identify({'user_id': 'new-user'});
      expect(client.boolVariation('feature', defaultValue: false), isTrue);
    });
  });
}
