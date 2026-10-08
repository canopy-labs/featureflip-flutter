import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/anonymous_key_store.dart';

const _reportsHeader = 'X-Featureflip-Reports-Evaluations';

class _MemoryStore implements AnonymousKeyStore {
  _MemoryStore(this._value);
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;
}

/// Stands in for the Evaluation API: answers evaluate/identify with [flags],
/// accepts events, and records every request.
class _FakeEvaluationApi {
  _FakeEvaluationApi(this.flags);

  final Map<String, Map<String, dynamic>> flags;
  final List<http.Request> requests = <http.Request>[];

  late final http.Client client = http_testing.MockClient((request) async {
    requests.add(request);
    if (request.url.path == '/v1/client/events') return http.Response('', 202);
    return http.Response(jsonEncode({'flags': flags}), 200);
  });

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  /// Every Evaluation event POSTed to /v1/client/events, in order.
  List<Map<String, dynamic>> get evaluationEvents => to('/v1/client/events')
      .expand((r) => ((jsonDecode(r.body) as Map<String, dynamic>)['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>())
      .where((e) => e['type'] == 'Evaluation')
      .toList();
}

Map<String, Map<String, dynamic>> _flags() => {
      'bool-flag': {'value': true, 'variation': 'on', 'reason': 'fallthrough'},
      'string-flag': {'value': 'blue', 'variation': 'blue-arm', 'reason': 'fallthrough'},
      'number-flag': {'value': 3, 'variation': 'three', 'reason': 'fallthrough'},
      'json-flag': {
        'value': {'a': 1},
        'variation': 'obj',
        'reason': 'fallthrough',
      },
    };

/// A real, refcounted core over [api]. Polling, not streaming, with one poll on
/// start and none after, so every request a test sees was caused by the test.
FeatureflipClient _client(
  _FakeEvaluationApi api, {
  String sdkKey = 'read-reporting-key',
  Map<String, dynamic> context = const {'user_id': 'u1'},
  bool sendEvaluationEvents = true,
}) {
  final client = FeatureflipClient.getWithHttpClientForTesting(
    sdkKey,
    config: FeatureflipConfig(
      clientKey: 'client-key',
      baseUrl: 'https://test.example.com',
      context: context,
      streaming: false,
      pollIntervalSeconds: 3600,
      sendEvaluationEvents: sendEvaluationEvents,
    ),
    httpClient: api.client,
    anonymousKeyStore: _MemoryStore('anon-123'),
  );
  addTearDown(client.close);
  return client;
}

/// Lets in-flight mock round-trips (the poller's first poll) land.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<List<dynamic>> _summarise(List<Map<String, dynamic>> events) =>
    events.map((e) => [e['flagKey'], e['variation'], e['userId']]).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(FeatureflipClient.resetForTesting);

  group('the option and the header, through the client', () {
    test('every /evaluate, the startup fetch and the poll after it, declares it', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);

      await client.initialize();
      await _settle();

      final evaluates = api.to('/v1/client/evaluate');
      expect(evaluates, hasLength(2), reason: 'the startup fetch and the poller\'s first poll');
      for (final r in evaluates) {
        expect(r.headers[_reportsHeader], '1');
      }
    });

    test('/identify declares it', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      await client.identify({'user_id': 'u2'});

      expect(api.to('/v1/client/identify').single.headers[_reportsHeader], '1');
    });

    test('with sendEvaluationEvents: false, no request declares it', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api, sendEvaluationEvents: false);

      await client.initialize();
      await client.identify({'user_id': 'u2'});
      await _settle();

      final calls = [...api.to('/v1/client/evaluate'), ...api.to('/v1/client/identify')];
      expect(calls, hasLength(3));
      for (final r in calls) {
        expect(r.headers.containsKey(_reportsHeader), isFalse);
      }
    });

    test('/v1/client/events never carries it', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      client.track('checkout');
      await client.flush();

      final posts = api.to('/v1/client/events');
      expect(posts, isNotEmpty);
      for (final r in posts) {
        expect(r.headers.containsKey(_reportsHeader), isFalse);
      }
    });

    test('a second get() with a different sendEvaluationEvents warns and keeps the first setting', () async {
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = originalDebugPrint);

      final api = _FakeEvaluationApi(_flags());
      final first = _client(api, sdkKey: 'mismatch-key');
      await first.initialize();

      // What a hot reload that edits the config also does: _liveCache survives it.
      final second = FeatureflipClient.get(
        'mismatch-key',
        config: const FeatureflipConfig(
          clientKey: 'client-key',
          baseUrl: 'https://test.example.com',
          streaming: false,
          pollIntervalSeconds: 3600,
          sendEvaluationEvents: false,
        ),
      );
      addTearDown(second.close);

      expect(logs.any((l) => l.contains('different config')), isTrue, reason: 'logs: $logs');

      // The cached core's setting still governs the header.
      await second.identify({'user_id': 'u2'});
      expect(api.to('/v1/client/identify').single.headers[_reportsHeader], '1');
    });
  });

  group('reads', () {
    test('each typed variation reports its first read once, with the served variation and user', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      for (var i = 0; i < 3; i++) {
        client.boolVariation('bool-flag', defaultValue: false);
        client.stringVariation('string-flag', defaultValue: '');
        client.numberVariation('number-flag', defaultValue: 0);
        client.jsonVariation('json-flag', defaultValue: null);
      }
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
        ['string-flag', 'blue-arm', 'u1'],
        ['number-flag', 'three', 'u1'],
        ['json-flag', 'obj', 'u1'],
      ]);
      for (final e in api.evaluationEvents) {
        expect(DateTime.parse(e['timestamp'] as String).isUtc, isTrue);
      }
    });

    test('a read of a flag the snapshot does not have is reported, with no variation', () async {
      // An old build reading an archived or renamed flag must stay visible.
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      client.boolVariation('missing-flag', defaultValue: true);
      client.boolVariation('missing-flag', defaultValue: true);
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['missing-flag', null, 'u1'],
      ]);
      expect(api.evaluationEvents.single.containsKey('variation'), isFalse);
    });

    test('allFlags() reports nothing', () async {
      // Counting it would bring the bug back in any app with a debug screen.
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      expect(client.allFlags(), hasLength(4));
      await client.flush();

      expect(api.to('/v1/client/events'), isEmpty);
    });

    test('widget reads through flagProvider are reported, once', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      for (var i = 0; i < 3; i++) {
        expect(client.flagProvider.boolVariation('bool-flag', defaultValue: false), isTrue);
        client.flagProvider.stringVariation('string-flag', defaultValue: '');
        client.flagProvider.numberVariation('number-flag', defaultValue: 0);
        client.flagProvider.jsonVariation('missing-flag', defaultValue: null);
      }
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
        ['string-flag', 'blue-arm', 'u1'],
        ['number-flag', 'three', 'u1'],
        ['missing-flag', null, 'u1'],
      ]);
    });

    test('a client read and a widget read of the same flag are one report', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      client.boolVariation('bool-flag', defaultValue: false);
      client.flagProvider.boolVariation('bool-flag', defaultValue: false);
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
      ]);
    });

    test('handles on one core share one dedupe state', () async {
      final api = _FakeEvaluationApi(_flags());
      final h1 = _client(api, sdkKey: 'shared-key');
      final h2 = _client(api, sdkKey: 'shared-key');
      await h1.initialize();

      h1.boolVariation('bool-flag', defaultValue: false);
      h2.boolVariation('bool-flag', defaultValue: false);
      await h2.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
      ]);
    });

    test('with sendEvaluationEvents: false, no read is reported', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api, sendEvaluationEvents: false);
      await client.initialize();

      client.boolVariation('bool-flag', defaultValue: false);
      client.boolVariation('missing-flag', defaultValue: false);
      client.flagProvider.stringVariation('string-flag', defaultValue: '');
      await client.flush();

      expect(api.to('/v1/client/events'), isEmpty);
    });

    test('track() still sends the same user id', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      client.track('checkout');
      await client.flush();

      final events = (jsonDecode(api.to('/v1/client/events').single.body) as Map<String, dynamic>)['events']
          as List<dynamic>;
      final custom = events.cast<Map<String, dynamic>>().single;
      expect(custom['type'], 'Custom');
      expect(custom['userId'], 'u1');
    });
  });

  group('Flutter lifecycle', () {
    test('after the app resumes, the same read is reported again (device sleep)', () async {
      // Stopwatch does not advance while a phone sleeps. Without the reset on
      // resume, a read before a 30 h sleep stays deduped after waking. No clock
      // is advanced here: the resume alone must start a new window.
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(() => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      client.boolVariation('bool-flag', defaultValue: false);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var i = 0; i < 100 && api.evaluationEvents.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.evaluationEvents, hasLength(1));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      client.boolVariation('bool-flag', defaultValue: false);
      client.boolVariation('bool-flag', defaultValue: false); // still deduped within the new window
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
        ['bool-flag', 'on', 'u1'],
      ]);
    });

    test('a read before initialize() is reported, and does not hide the read after it', () async {
      // Widgets often build before `await client.initialize()` returns. No
      // snapshot yet, and the anonymous id is not resolved yet.
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api, context: const <String, dynamic>{});

      expect(client.boolVariation('bool-flag', defaultValue: false), isFalse);
      await client.initialize();
      expect(client.boolVariation('bool-flag', defaultValue: false), isTrue);
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', null, null],
        // The cached user id was refreshed when init resolved the anonymous id.
        ['bool-flag', 'on', 'anon-123'],
      ]);
    });

    test('after identify(), reads are reported under the new user', () async {
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();

      client.boolVariation('bool-flag', defaultValue: false);
      await client.identify({'user_id': 'u2'});
      client.boolVariation('bool-flag', defaultValue: false);
      await client.flush();

      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
        ['bool-flag', 'on', 'u2'],
      ]);
    });

    test('going to the background sends recorded reads without waiting for the flush timer', () async {
      // Mobile sessions are short: an app opened and backgrounded inside the 30 s
      // flush interval must still report what it read.
      final api = _FakeEvaluationApi(_flags());
      final client = _client(api);
      await client.initialize();
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(() => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      client.boolVariation('bool-flag', defaultValue: false);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      for (var i = 0; i < 100 && api.evaluationEvents.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(_summarise(api.evaluationEvents), [
        ['bool-flag', 'on', 'u1'],
      ]);
    });
  });
}
