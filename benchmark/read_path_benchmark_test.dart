// The testing seams are @visibleForTesting; this file is a test-style harness
// that lives outside test/ so CI's bare `flutter test` never runs it.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:featureflip/featureflip.dart';
import 'package:featureflip/src/anonymous_key_store.dart';

/// Read-path cost of read reporting. Not run in CI (timing flakes on shared
/// runners); run it by hand and put the printed line in the PR description:
///
///   cd packages/flutter-sdk && flutter test benchmark/read_path_benchmark_test.dart
///
/// Budget: a repeat read adds at most 100 ns with
/// sendEvaluationEvents on, compared with off.

const _reads = 1000000; // no digit separators: CI's Dart 3.5 lacks them
const _rounds = 5;

class _MemoryStore implements AnonymousKeyStore {
  String? _value = 'bench-user';

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;
}

Future<FeatureflipClient> _initialized(String sdkKey, {required bool sendEvaluationEvents}) async {
  final transport = http_testing.MockClient((request) async {
    if (request.url.path == '/v1/client/events') return http.Response('', 202);
    return http.Response(
      jsonEncode({
        'flags': {
          'bool-flag': {'value': true, 'variation': 'on', 'reason': 'fallthrough'},
        },
      }),
      200,
    );
  });
  final client = FeatureflipClient.getWithHttpClientForTesting(
    sdkKey,
    config: FeatureflipConfig(
      clientKey: 'bench-key',
      baseUrl: 'https://bench.example.com',
      context: const {'user_id': 'bench-user'},
      streaming: false,
      pollIntervalSeconds: 3600,
      sendEvaluationEvents: sendEvaluationEvents,
    ),
    httpClient: transport,
    anonymousKeyStore: _MemoryStore(),
  );
  await client.initialize();
  return client;
}

/// ns per boolVariation call over [_reads] calls. Asserts every call served the
/// flag, which also keeps the loop from being optimised away.
double _nsPerRead(FeatureflipClient client) {
  var hits = 0;
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < _reads; i++) {
    if (client.boolVariation('bool-flag', defaultValue: false)) hits++;
  }
  stopwatch.stop();
  expect(hits, _reads);
  return stopwatch.elapsedMicroseconds * 1000 / _reads;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(FeatureflipClient.resetForTesting);

  test('a repeat read adds at most 100 ns with read reporting on', () async {
    final off = await _initialized('bench-off', sendEvaluationEvents: false);
    final on = await _initialized('bench-on', sendEvaluationEvents: true);
    addTearDown(off.close);
    addTearDown(on.close);

    // Warm-up: lets the JIT optimise the read path, and records the one first
    // read on `on`, so every timed read below is a repeat.
    _nsPerRead(off);
    _nsPerRead(on);

    var bestOff = double.infinity;
    var bestOn = double.infinity;
    for (var round = 0; round < _rounds; round++) {
      bestOff = math.min(bestOff, _nsPerRead(off));
      bestOn = math.min(bestOn, _nsPerRead(on));
    }
    final added = bestOn - bestOff;

    // ignore: avoid_print
    print('[read-path benchmark] off ${bestOff.toStringAsFixed(1)} ns/read, '
        'on ${bestOn.toStringAsFixed(1)} ns/read, '
        'added ${added.toStringAsFixed(1)} ns/read '
        '($_reads repeat boolVariation calls, best of $_rounds, flutter test JIT)');

    expect(added, lessThanOrEqualTo(100));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
