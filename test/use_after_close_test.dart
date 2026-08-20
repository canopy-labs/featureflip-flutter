import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

/// `close()` releases the core — stopping streaming, flushing events, unregistering
/// the lifecycle observer — but the in-memory cache stays readable, so a closed
/// handle kept serving a frozen snapshot that can never update again, and reported
/// `isInitialized == true` while doing it (#2291).
///
/// The contract settled in #2313 for the server SDKs: a closed handle returns the
/// caller's default and reports not-initialized. This applies it to flutter.
///
/// Note the fixture deliberately seeds real values via `forTesting`. A client whose
/// fetch failed has an empty cache, so it would return defaults either way and the
/// test would pass without the fix — the stale value has to exist for the assertion
/// to mean anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    FeatureflipClient.resetForTesting();
  });

  test('serves real values while open', () async {
    final client = FeatureflipClient.forTesting({
      'bool-flag': true,
      'string-flag': 'served',
      'number-flag': 42.0,
    });

    expect(client.boolVariation('bool-flag', defaultValue: false), isTrue);
    expect(client.stringVariation('string-flag', defaultValue: 'fallback'), 'served');
    expect(client.numberVariation('number-flag', defaultValue: 0.0), 42.0);
    expect(client.isInitialized, isTrue);

    await client.close();
  });

  test('a closed handle serves the caller default, not the stale value', () async {
    final client = FeatureflipClient.forTesting({
      'bool-flag': true,
      'string-flag': 'served',
      'number-flag': 42.0,
      'json-flag': {'a': 1},
    });

    await client.close();

    // Each default is deliberately the opposite of the cached value, so a stale
    // read is distinguishable from a correct default.
    expect(client.boolVariation('bool-flag', defaultValue: false), isFalse);
    expect(client.stringVariation('string-flag', defaultValue: 'fallback'), 'fallback');
    expect(client.numberVariation('number-flag', defaultValue: 0.0), 0.0);
    expect(client.jsonVariation('json-flag', defaultValue: null), isNull);
  });

  test('a closed handle reports not-initialized', () async {
    final client = FeatureflipClient.forTesting({'bool-flag': true});

    expect(client.isInitialized, isTrue);
    await client.close();

    expect(client.isInitialized, isFalse);
  });

  test('a closed handle exposes no flags', () async {
    final client = FeatureflipClient.forTesting({'bool-flag': true});

    expect(client.allFlags(), isNotEmpty);
    await client.close();

    expect(client.allFlags(), isEmpty);
  });

  test('close stays idempotent', () async {
    final client = FeatureflipClient.forTesting({'bool-flag': true});

    await client.close();
    await client.close();

    expect(client.boolVariation('bool-flag', defaultValue: false), isFalse);
  });
}
