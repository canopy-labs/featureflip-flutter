import 'dart:convert';

import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/anonymous_key_store.dart';
import 'package:featureflip/src/sdk_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

/// The SDK key must never reach a log line or an exception message, even when
/// the HTTP stack quotes it (#5166, #5167). The stub's transport errors embed
/// the key on purpose, so these tests prove the redactor and not just clean
/// call sites.
const _key = 'sdk_client_SentinelKeyMustNeverAppearInLogs-0123456789';

class _InMemoryKeyStore implements AnonymousKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
}

/// Answers evaluate with [evaluate], events with [events]; either may be an
/// int status or 'throw' (a transport error quoting the Authorization header).
http.Client _stub({required Object evaluate, required Object events}) =>
    http_testing.MockClient((request) async {
      final behaviour =
          request.url.path.endsWith('/events') ? events : evaluate;
      if (behaviour == 'throw') {
        throw http.ClientException(
            'connection failed; request headers: Authorization: ${request.headers['Authorization']} '
            'url: ${request.url}?key=$_key',
            request.url);
      }
      if (behaviour == 200) {
        return http.Response(
            jsonEncode({
              'flags': {
                'bool-flag': {
                  'value': true,
                  'variation': 'on',
                  'reason': 'fallthrough'
                },
              },
            }),
            200);
      }
      return http.Response('', behaviour as int);
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DebugPrintCallback originalDebugPrint;
  late List<String> logs;

  setUp(() {
    logs = <String>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    FeatureflipClient.resetForTesting();
  });

  FeatureflipConfig config(
          {String clientKey = _key,
          int flushBatchSize = 100,
          bool streaming = false,
          List<EvaluationInspector> inspectors = const []}) =>
      FeatureflipConfig(
        clientKey: clientKey,
        baseUrl: 'https://test.example.com',
        streaming: streaming,
        inspectors: inspectors,
        pollIntervalSeconds: 3600,
        flushBatchSize: flushBatchSize,
      );

  for (final evaluate in <Object>[200, 401, 500, 'throw']) {
    for (final events in <Object>[202, 500, 401, 'throw']) {
      test(
          'evaluate=$evaluate events=$events: the key appears in no log line or exception',
          () async {
        final thrown = <String>[];
        Future<void> guarded(Future<void> Function() body) async {
          try {
            await body();
          } catch (err) {
            thrown.add(err.toString());
          }
        }

        final client = FeatureflipClient.getWithHttpClientForTesting(
          _key,
          config: config(),
          httpClient: _stub(evaluate: evaluate, events: events),
          anonymousKeyStore: _InMemoryKeyStore(),
        );
        await guarded(client.initialize);

        client.boolVariation('bool-flag', defaultValue: false);
        client.boolVariation('unknown-flag', defaultValue: false);
        client.stringVariation('bool-flag', defaultValue: 'd'); // type mismatch
        client.numberVariation('bool-flag', defaultValue: 1);

        client.track('clicked', metadata: {'a': 1});
        await guarded(() => client.identify({'user_id': 'u2'}));
        await guarded(client.flush);

        // Same key, different config: the "options ignored" warning path.
        final second = FeatureflipClient.get(
          _key,
          config: FeatureflipConfig(
              clientKey: _key, baseUrl: 'https://other.example.com'),
        );
        await guarded(second.close);
        await guarded(client.close);

        expect(logs, isNotEmpty,
            reason:
                'the drive must actually exercise logging, or the assertion is vacuous');
        for (final line in logs) {
          expect(line, isNot(contains(_key)));
        }
        for (final message in thrown) {
          expect(message, isNot(contains(_key)));
        }
      });
    }
  }

  test('a key quoted by the transport error reaches the log as [redacted]',
      () async {
    final client = FeatureflipClient.getWithHttpClientForTesting(
      _key,
      config: config(),
      httpClient: _stub(evaluate: 'throw', events: 'throw'),
      anonymousKeyStore: _InMemoryKeyStore(),
    );
    await client.initialize();

    final line =
        logs.firstWhere((l) => l.contains('initial flag fetch failed'));
    expect(line, contains('[redacted]'));
    expect(line, isNot(contains(_key)));

    client.track('t');
    await client.flush();
    final flushLine = logs.firstWhere((l) => l.contains('failed to flush'));
    expect(flushLine, contains('Authorization: [redacted]'));
    await client.close();
  });

  test('identify rethrows an http.ClientException with the key removed',
      () async {
    final client = FeatureflipClient.getWithHttpClientForTesting(
      _key,
      config: config(),
      httpClient: _stub(evaluate: 'throw', events: 202),
      anonymousKeyStore: _InMemoryKeyStore(),
    );
    await client.initialize();

    Object? caught;
    try {
      await client.identify({'user_id': 'u2'});
    } catch (err) {
      caught = err;
    }
    expect(caught, isA<http.ClientException>());
    final e = caught as http.ClientException;
    expect(e.message, contains('[redacted]'));
    expect(e.message, isNot(contains(_key)));
    expect(e.uri.toString(), isNot(contains(_key)));
    expect(e.toString(), isNot(contains(_key)));
    await client.close();
  });

  test('an inspector that throws a key-quoting error is logged redacted',
      () async {
    final client = FeatureflipClient.getWithHttpClientForTesting(
      _key,
      config: config(
          inspectors: [(_) => throw Exception('boom Authorization: $_key')]),
      httpClient: _stub(evaluate: 200, events: 202),
      anonymousKeyStore: _InMemoryKeyStore(),
    );
    await client.initialize();
    client.boolVariation('bool-flag', defaultValue: false);

    final line = logs.firstWhere((l) => l.contains('inspector threw'));
    expect(line, contains('Authorization: [redacted]'));
    expect(line, isNot(contains(_key)));
    await client.close();
  });

  test('streaming enabled: the key appears in no log line', () async {
    final client = FeatureflipClient.getWithHttpClientForTesting(
      _key,
      config: config(streaming: true),
      httpClient: _stub(evaluate: 200, events: 'throw'),
      anonymousKeyStore: _InMemoryKeyStore(),
    );
    await client.initialize();
    client.track('t');
    await client.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.close();
    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, isNot(contains(_key)));
    }
  });

  group('SdkLogger', () {
    test('redacts every occurrence', () {
      expect(const SdkLogger(_key).redact('a $_key b $_key'),
          'a [redacted] b [redacted]');
    });

    test('leaves a key shorter than 20 characters alone', () {
      const short = 'sdk_client_abc'; // 14
      expect(const SdkLogger(short).redact('failed for $short'),
          'failed for $short');
    });

    test('with no secret, passes the message through', () {
      expect(const SdkLogger.none().redact('hello'), 'hello');
    });

    test('log() redacts what it hands to debugPrint', () {
      const SdkLogger(_key).log('x $_key');
      expect(logs, ['x [redacted]']);
    });
  });
}
