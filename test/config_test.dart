import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

void main() {
  group('FeatureflipConfig', () {
    test('has sensible defaults', () {
      const config = FeatureflipConfig(clientKey: 'test-key');
      expect(config.clientKey, 'test-key');
      expect(config.baseUrl, 'https://eval.featureflip.io');
      expect(config.context, isEmpty);
      expect(config.streaming, isTrue);
      expect(config.pollIntervalSeconds, 30);
      expect(config.flushIntervalSeconds, 30);
      expect(config.flushBatchSize, 100);
      expect(config.initTimeoutSeconds, 10);
    });

    test('accepts custom values', () {
      const config = FeatureflipConfig(
        clientKey: 'my-key',
        baseUrl: 'https://custom.example.com',
        context: {'user_id': '123'},
        streaming: false,
        pollIntervalSeconds: 60,
        flushIntervalSeconds: 15,
        flushBatchSize: 50,
        initTimeoutSeconds: 5,
      );
      expect(config.clientKey, 'my-key');
      expect(config.baseUrl, 'https://custom.example.com');
      expect(config.context, {'user_id': '123'});
      expect(config.streaming, isFalse);
      expect(config.pollIntervalSeconds, 60);
      expect(config.flushIntervalSeconds, 15);
      expect(config.flushBatchSize, 50);
      expect(config.initTimeoutSeconds, 5);
    });
  });
}
