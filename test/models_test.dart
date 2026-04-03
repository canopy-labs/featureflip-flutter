import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

void main() {
  group('FlagValue', () {
    test('fromJson parses correctly', () {
      final json = {
        'value': true,
        'variation': 'on',
        'reason': 'Fallthrough',
      };
      final flag = FlagValue.fromJson(json);
      expect(flag.value, isTrue);
      expect(flag.variation, 'on');
      expect(flag.reason, 'Fallthrough');
    });

    test('toJson roundtrips', () {
      const flag = FlagValue(value: 'hello', variation: 'v1', reason: 'RULE');
      final json = flag.toJson();
      expect(json['value'], 'hello');
      expect(json['variation'], 'v1');
      expect(json['reason'], 'RULE');
    });

    test('equality works', () {
      const a = FlagValue(value: true, variation: 'v1', reason: 'RULE');
      const b = FlagValue(value: true, variation: 'v1', reason: 'RULE');
      const c = FlagValue(value: false, variation: 'v1', reason: 'RULE');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('EvaluateResponse', () {
    test('fromJson parses flags map', () {
      final json = {
        'flags': {
          'flag-a': {'value': true, 'variation': 'on', 'reason': 'Fallthrough'},
          'flag-b': {'value': 'hello', 'variation': 'v2', 'reason': 'RuleMatch'},
        },
      };
      final response = EvaluateResponse.fromJson(json);
      expect(response.flags.length, 2);
      expect(response.flags['flag-a']!.value, isTrue);
      expect(response.flags['flag-b']!.value, 'hello');
    });
  });

  group('SdkEvent', () {
    test('toJson includes all non-null fields', () {
      const event = SdkEvent(
        type: 'purchase',
        flagKey: 'checkout',
        userId: 'u-123',
        variation: 'v1',
        timestamp: '2024-01-01T00:00:00Z',
        metadata: {'total': 99.99},
      );
      final json = event.toJson();
      expect(json['type'], 'purchase');
      expect(json['flagKey'], 'checkout');
      expect(json['userId'], 'u-123');
      expect(json['variation'], 'v1');
      expect(json['timestamp'], '2024-01-01T00:00:00Z');
      expect(json['metadata'], {'total': 99.99});
    });

    test('toJson excludes null fields', () {
      const event = SdkEvent(
        type: 'click',
        timestamp: '2024-01-01T00:00:00Z',
      );
      final json = event.toJson();
      expect(json.containsKey('flagKey'), isFalse);
      expect(json.containsKey('userId'), isFalse);
      expect(json.containsKey('variation'), isFalse);
      expect(json.containsKey('metadata'), isFalse);
    });
  });
}
