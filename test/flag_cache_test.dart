import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/flag_cache.dart';

void main() {
  group('FlagCache', () {
    late FlagCache cache;

    setUp(() {
      cache = FlagCache();
    });

    test('starts empty', () {
      expect(cache.all(), isEmpty);
      expect(cache.get('any'), isNull);
    });

    test('setAll replaces all flags', () {
      cache.setAll({
        'a': const FlagValue(value: true, variation: 'v1', reason: 'RULE'),
        'b': const FlagValue(value: 'hello', variation: 'v1', reason: 'RULE'),
      });
      expect(cache.all().length, 2);
      expect(cache.get('a')!.value, isTrue);
      expect(cache.get('b')!.value, 'hello');
    });

    test('setAll overwrites previous flags', () {
      cache.setAll({
        'a': const FlagValue(value: true, variation: 'v1', reason: 'RULE'),
      });
      cache.setAll({
        'b': const FlagValue(value: false, variation: 'v2', reason: 'RULE'),
      });
      expect(cache.get('a'), isNull);
      expect(cache.get('b')!.value, isFalse);
    });

    test('all returns unmodifiable map', () {
      cache.setAll({
        'a': const FlagValue(value: true, variation: 'v1', reason: 'RULE'),
      });
      final flags = cache.all();
      expect(() => flags['b'] = const FlagValue(value: false, variation: 'v1', reason: 'RULE'),
          throwsA(isA<UnsupportedError>()));
    });
  });
}
