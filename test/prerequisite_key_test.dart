import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/flag_cache.dart';

void main() {
  group('FlagValue.prerequisiteKey', () {
    test('decodes when present', () {
      final flag = FlagValue.fromJson({
        'value': false,
        'variation': 'off',
        'reason': 'prerequisite-failed',
        'prerequisiteKey': 'billing-enabled',
      });

      expect(flag.variation, 'off');
      expect(flag.reason, 'prerequisite-failed');
      expect(flag.prerequisiteKey, 'billing-enabled');
    });

    test('is null when absent', () {
      final flag = FlagValue.fromJson({
        'value': true,
        'variation': 'on',
        'reason': 'fallthrough',
      });

      expect(flag.prerequisiteKey, isNull);
    });

    test('is null when server sends null', () {
      final flag = FlagValue.fromJson({
        'value': true,
        'variation': 'on',
        'reason': 'fallthrough',
        'prerequisiteKey': null,
      });

      expect(flag.prerequisiteKey, isNull);
    });
  });

  group('EvaluateResponse with prerequisiteKey', () {
    test('decodes prerequisiteKey across the flag map', () {
      final response = EvaluateResponse.fromJson({
        'flags': {
          'premium-feature': {
            'value': false,
            'variation': 'off',
            'reason': 'prerequisite-failed',
            'prerequisiteKey': 'subscription-active',
          },
          'dark-mode': {
            'value': true,
            'variation': 'on',
            'reason': 'fallthrough',
          },
        },
      });

      expect(response.flags['premium-feature']!.prerequisiteKey,
          'subscription-active');
      expect(response.flags['dark-mode']!.prerequisiteKey, isNull);
    });
  });

  group('FlagValue.toJson with prerequisiteKey', () {
    test('round-trips prerequisiteKey through fromJson/toJson', () {
      const original = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'parent-flag',
      );

      final decoded = FlagValue.fromJson(original.toJson());

      expect(decoded, equals(original));
      expect(decoded.prerequisiteKey, 'parent-flag');
    });

    test('omits prerequisiteKey when null', () {
      const flag = FlagValue(
        value: true,
        variation: 'on',
        reason: 'fallthrough',
      );

      final json = flag.toJson();

      expect(json.containsKey('prerequisiteKey'), isFalse);
    });

    test('includes prerequisiteKey when set', () {
      const flag = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'parent',
      );

      final json = flag.toJson();

      expect(json['prerequisiteKey'], 'parent');
    });
  });

  group('FlagValue equality with prerequisiteKey', () {
    test('values differing only in prerequisiteKey are not equal', () {
      const a = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'alpha',
      );
      const b = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'beta',
      );
      const c = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
      );

      expect(a, isNot(equals(b)));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('values matching including prerequisiteKey are equal', () {
      const a = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'parent',
      );
      const b = FlagValue(
        value: false,
        variation: 'off',
        reason: 'prerequisite-failed',
        prerequisiteKey: 'parent',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('FlagCache preserves prerequisiteKey', () {
    test('round-trips prerequisiteKey through setAll/get', () {
      final cache = FlagCache();
      cache.setAll({
        'premium': const FlagValue(
          value: false,
          variation: 'off',
          reason: 'prerequisite-failed',
          prerequisiteKey: 'subscription',
        ),
        'vanilla': const FlagValue(
          value: true,
          variation: 'on',
          reason: 'fallthrough',
        ),
      });

      expect(cache.get('premium')!.prerequisiteKey, 'subscription');
      expect(cache.get('vanilla')!.prerequisiteKey, isNull);
      expect(cache.all()['premium']!.prerequisiteKey, 'subscription');
    });
  });
}
