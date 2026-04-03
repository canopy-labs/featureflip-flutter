import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/src/streaming_data_source.dart';

void main() {
  group('StreamingDataSource', () {
    test('buildStreamUri encodes authorization and context', () {
      final uri = StreamingDataSource.buildStreamUri(
        'https://eval.example.com',
        'client-key-123',
        {'user_id': 'u1'},
      );

      expect(uri.path, '/v1/client/stream');
      expect(uri.queryParameters['authorization'], 'client-key-123');

      final encodedContext = uri.queryParameters['context']!;
      final decodedContext = utf8.decode(base64Decode(encodedContext));
      final context = jsonDecode(decodedContext) as Map<String, dynamic>;
      expect(context['user_id'], 'u1');
    });

    test('buildStreamUri handles empty context', () {
      final uri = StreamingDataSource.buildStreamUri(
        'https://eval.example.com',
        'key',
        {},
      );

      final encodedContext = uri.queryParameters['context']!;
      final decodedContext = utf8.decode(base64Decode(encodedContext));
      expect(decodedContext, '{}');
    });

    test('connectionId is null before connection-ready event', () {
      final ds = StreamingDataSource(
        baseUrl: 'https://eval.example.com',
        clientKey: 'key',
        context: {},
        onChange: (_) {},
      );

      expect(ds.connectionId, isNull);
    });
  });
}
