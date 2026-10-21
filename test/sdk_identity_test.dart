import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/anonymous_key_store.dart';
import 'package:featureflip/src/http_client.dart';
import 'package:featureflip/src/sdk_identity.dart';
import 'package:featureflip/src/streaming_data_source.dart';

/// Every request names the SDK and its version so the Evaluation API can count
/// usage (#4143, contract in #4138). Native builds sent `Dart/<x> (dart:io)`, the
/// same for every Dart client; web builds sent nothing at all. The identity now
/// travels in User-Agent (honoured off the web) and in X-Featureflip-SDK (the only
/// carrier a browser allows). Tests run off the web, so both are asserted.
class _MemoryStore implements AnonymousKeyStore {
  String? _value = 'anon';

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sdkToken = 'featureflip-flutter/$sdkVersion';

  tearDown(FeatureflipClient.resetForTesting);

  http.Response flags() => http.Response(
        jsonEncode({
          'flags': {
            'f': {'value': true, 'variation': 'on', 'reason': 'RULE'}
          }
        }),
        200,
      );

  void expectIdentity(Map<String, String> headers, String expected) {
    expect(headers['User-Agent'], expected);
    expect(headers['X-Featureflip-SDK'], expected);
  }

  test('sdkVersion is the version in pubspec.yaml', () {
    // publish-flutter-sdk.yml rewrites both from the tag; this keeps them equal
    // between releases so the constant cannot drift the way literals did (#2141).
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(pubspec)!.group(1);

    expect(sdkVersion, version);
  });

  test('evaluate, identify and events carry the SDK token by default', () async {
    final seen = <String, Map<String, String>>{};
    final client = FeatureflipHttpClient(
      baseUrl: 'https://eval.test',
      clientKey: 'k',
      client: MockClient((request) async {
        seen[request.url.path] = request.headers;
        return request.url.path.endsWith('/events') ? http.Response('', 202) : flags();
      }),
    );

    await client.evaluate({'user_id': 'u'});
    await client.identify({'user_id': 'u'});
    await client.postEvents([const SdkEvent(type: 'Custom', flagKey: 'f', timestamp: '2026-10-20T00:00:00Z')]);

    for (final path in ['/v1/client/evaluate', '/v1/client/identify', '/v1/client/events']) {
      expectIdentity(seen[path]!, sdkToken);
    }
  });

  test('the stream connect carries the identity it was given', () async {
    Map<String, String>? headers;
    final ds = StreamingDataSource(
      baseUrl: 'https://eval.test',
      clientKey: 'k',
      context: {},
      onChange: (_) {},
      onSnapshot: (_) {},
      identity: '$sdkToken my-wrapper/1.0',
      client: MockClient.streaming((request, _) async {
        headers = request.headers;
        return http.StreamedResponse(const Stream.empty(), 200, headers: {'content-type': 'text/event-stream'});
      }),
    );

    ds.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    ds.stop();

    expectIdentity(headers!, '$sdkToken my-wrapper/1.0');
  });

  test('a configured wrapper reaches the wire through the client', () async {
    Map<String, String>? headers;
    final client = FeatureflipClient.getWithHttpClientForTesting(
      'identity-key',
      config: const FeatureflipConfig(
        clientKey: 'identity-key',
        baseUrl: 'https://eval.test',
        streaming: false,
        sendEvaluationEvents: false,
        wrapperName: 'featureflip-react-native',
        wrapperVersion: '0.1.0',
      ),
      httpClient: MockClient((request) async {
        headers ??= request.headers;
        return flags();
      }),
      anonymousKeyStore: _MemoryStore(),
    );

    await client.initialize();
    await client.close();

    expectIdentity(headers!, '$sdkToken featureflip-react-native/0.1.0');
  });

  test('a wrapper without a version is sent as a bare name', () {
    expect(buildIdentity(wrapperName: 'my-wrapper'), '$sdkToken my-wrapper');
  });

  test('an invalid wrapper is dropped with a diagnostic', () {
    // A space is not a legal product-token character. Identity metadata must
    // never stop the client starting, so the wrapper is dropped and said so.
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => printed.add(message ?? '');
    try {
      expect(buildIdentity(wrapperName: 'bad name', wrapperVersion: '1.0'), sdkToken);
    } finally {
      debugPrint = original;
    }

    expect(printed.join('\n'), contains('bad name'));
  });
}
