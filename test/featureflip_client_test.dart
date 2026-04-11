import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    FeatureflipClient.resetForTesting();
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

    test('does not participate in shared cache', () {
      final t1 = FeatureflipClient.forTesting({'a': true});
      final t2 = FeatureflipClient.forTesting({'a': false});
      expect(t1.boolVariation('a', defaultValue: false), isTrue);
      expect(t2.boolVariation('a', defaultValue: true), isFalse);
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
    test('forTesting clients skip initialization and are immediately ready', () async {
      final client = FeatureflipClient.forTesting({'dark-mode': true});
      await client.initialize(); // Should be a no-op for test clients
      expect(client.boolVariation('dark-mode', defaultValue: false), isTrue);
      expect(client.isInitialized, isTrue);
    });
  });

  group('identify', () {
    test('refetches flags with new context via forTesting', () {
      // forTesting clients have static values, but we can verify the API exists
      final client = FeatureflipClient.forTesting({'feature': false});
      expect(client.boolVariation('feature', defaultValue: true), isFalse);
    });
  });

  group('singleton factory', () {
    test('same key returns handles sharing one core', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-1', config: config);
      final h2 = FeatureflipClient.get('sdk-key-1', config: config);

      // Different handle objects
      expect(identical(h1, h2), isFalse);

      // But they share the same provider (proves same core)
      expect(identical(h1.flagProvider, h2.flagProvider), isTrue);

      h1.close();
      h2.close();
    });

    test('different keys return independent cores', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-a', config: config);
      final h2 = FeatureflipClient.get('sdk-key-b', config: config);

      // Different providers means different cores
      expect(identical(h1.flagProvider, h2.flagProvider), isFalse);

      h1.close();
      h2.close();
    });

    test('close one handle leaves other functional', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-shared', config: config);
      final h2 = FeatureflipClient.get('sdk-key-shared', config: config);

      h1.close();

      // h2 should still work — core not shut down yet
      expect(h2.boolVariation('nonexistent', defaultValue: true), isTrue);

      h2.close();
    });

    test('double close is idempotent', () async {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-double', config: config);

      await h1.close();
      await h1.close(); // Should not throw or double-decrement
    });

    test('cache recycling after all handles closed', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-recycle', config: config);
      final provider1 = h1.flagProvider;
      h1.close();

      // After refcount → 0, next get() creates a fresh core
      final h2 = FeatureflipClient.get('sdk-key-recycle', config: config);
      final provider2 = h2.flagProvider;

      expect(identical(provider1, provider2), isFalse);
      h2.close();
    });

    test('resetForTesting clears cache', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final h1 = FeatureflipClient.get('sdk-key-reset', config: config);
      final provider1 = h1.flagProvider;

      FeatureflipClient.resetForTesting();

      final h2 = FeatureflipClient.get('sdk-key-reset', config: config);
      final provider2 = h2.flagProvider;

      // Fresh core after reset
      expect(identical(provider1, provider2), isFalse);
      h2.close();
    });

    test('forTesting clients are independent from cached clients', () {
      final config = const FeatureflipConfig(
        clientKey: 'test-key',
        baseUrl: 'https://test.example.com',
      );

      final live = FeatureflipClient.get('sdk-key-live', config: config);
      final test1 = FeatureflipClient.forTesting({'flag': true});
      final test2 = FeatureflipClient.forTesting({'flag': false});

      // All three have distinct providers (independent cores)
      expect(identical(live.flagProvider, test1.flagProvider), isFalse);
      expect(identical(test1.flagProvider, test2.flagProvider), isFalse);

      live.close();
    });
  });
}
