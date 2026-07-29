import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

void main() {
  group('flutter inspectors', () {
    test('fires once per accessor with served value and verbatim reason', () {
      final events = <EvaluationEvent>[];
      final client = FeatureflipClient.forTesting(
        {'stub-flag': true},
        inspectors: [events.add],
      );

      expect(client.boolVariation('stub-flag', defaultValue: false), isTrue);
      expect(events, hasLength(1));
      expect(events[0].flagKey, 'stub-flag');
      expect(events[0].value, isTrue);
      expect(events[0].variationKey, 'override');
      expect(events[0].reason, 'TEST');
      expect(events[0].ruleId, isNull);
      expect(DateTime.parse(events[0].timestamp).isUtc, isTrue);
    });

    test('reports flag-not-found for an absent flag', () {
      final events = <EvaluationEvent>[];
      final client = FeatureflipClient.forTesting({}, inspectors: [events.add]);

      expect(client.boolVariation('nope', defaultValue: true), isTrue);
      expect(events[0].reason, 'flag-not-found');
      expect(events[0].value, isTrue);
      expect(events[0].variationKey, isNull);
    });

    test('on type mismatch reports the default but keeps the server reason', () {
      final events = <EvaluationEvent>[];
      final client = FeatureflipClient.forTesting(
        {'stub-flag': 'a string'},
        inspectors: [events.add],
      );

      expect(client.boolVariation('stub-flag', defaultValue: false), isFalse);
      expect(events[0].value, isFalse);
      expect(events[0].reason, 'TEST');
      expect(events[0].variationKey, 'override');
    });

    test('fires exactly once per accessor across all four', () {
      final events = <EvaluationEvent>[];
      final client = FeatureflipClient.forTesting(
        {'stub-flag': true},
        inspectors: [events.add],
      );

      client.boolVariation('stub-flag', defaultValue: false);
      expect(events, hasLength(1));
      client.stringVariation('stub-flag', defaultValue: '');
      expect(events, hasLength(2));
      client.numberVariation('stub-flag', defaultValue: 0);
      expect(events, hasLength(3));
      client.jsonVariation('stub-flag', defaultValue: null);
      expect(events, hasLength(4));
    });

    test('isolates a throwing inspector from the value and from siblings', () {
      final seen = <String>[];
      final logged = <String>[];
      final client = FeatureflipClient.forTesting(
        {'stub-flag': true},
        inspectors: [
          (e) => throw StateError('boom'),
          (e) => seen.add(e.flagKey),
        ],
      );

      // The throwing inspector logs a warning via print(); capture it in a
      // zone instead of letting it leak into the test's stdout, and assert
      // it fired so the isolation contract is actually verified, not just
      // silenced.
      late final bool result;
      runZoned(
        () => result = client.boolVariation('stub-flag', defaultValue: false),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logged.add(line),
        ),
      );

      expect(result, isTrue);
      expect(seen, ['stub-flag']);
      expect(logged, hasLength(1));
      expect(logged.single, contains('evaluation inspector threw'));
    });

    test('hands over a context copy', () {
      final events = <EvaluationEvent>[];
      final client = FeatureflipClient.forTesting(
        {'stub-flag': true},
        inspectors: [events.add],
      );

      client.boolVariation('stub-flag', defaultValue: false);
      events[0].context['injected'] = 'mallory';
      client.boolVariation('stub-flag', defaultValue: false);

      expect(events[1].context.containsKey('injected'), isFalse);
    });

    test('is a no-op with no inspectors configured', () {
      final client = FeatureflipClient.forTesting({'stub-flag': true});
      expect(client.boolVariation('stub-flag', defaultValue: false), isTrue);
    });
  });
}
