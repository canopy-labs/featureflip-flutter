import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/featureflip.dart';

/// `_doInitialize` wraps the initial evaluate in a bare `catch (_)` with no
/// diagnostic, so a wrong SDK key, a 401, a timeout, captive-portal wifi and a
/// backend blip all present identically to a healthy start: every flag quietly
/// serves the caller's default (#2290).
///
/// Serving defaults is CORRECT and stays — it matches the browser SDK's
/// documented contract ("Non-terminal … serve caller defaults meanwhile. Never
/// reject."), and rethrowing here would take an app down at startup over a
/// network blip. What was wrong is that the failure left no trace at all.
///
/// These tests run under TestWidgetsFlutterBinding, whose HttpOverrides answers
/// every request with HTTP 400 — so the initial evaluate genuinely fails here
/// without needing a stub server.
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

  FeatureflipClient buildClient() => FeatureflipClient.get(
        'test-key',
        config: const FeatureflipConfig(
          clientKey: 'test-key',
          // Unroutable on purpose; the binding's HttpOverrides intercepts anyway.
          baseUrl: 'http://localhost:1',
          streaming: false,
          initTimeoutSeconds: 1,
        ),
      );

  test('logs a diagnostic when the initial evaluate fails', () async {
    final client = buildClient();

    await client.initialize();

    expect(
      logs.any((l) => l.contains('[featureflip]') && l.contains('initial flag fetch failed')),
      isTrue,
      reason: 'a failed initial fetch must leave a trace; logs were: $logs',
    );
  });

  test('the logged diagnostic names the underlying error', () async {
    final client = buildClient();

    await client.initialize();

    final line = logs.firstWhere(
      (l) => l.contains('initial flag fetch failed'),
      orElse: () => '',
    );
    // The point of logging is to distinguish a bad key from an unreachable host,
    // so the cause has to survive into the message.
    expect(line.length, greaterThan('[featureflip] initial flag fetch failed: '.length),
        reason: 'the diagnostic must carry the underlying error, not just a label');
  });

  test('still serves caller defaults and reports initialized (contract unchanged)', () async {
    final client = buildClient();

    await client.initialize();

    // Deliberate: matches the browser SDK. A failed initial fetch is non-terminal
    // — the data source keeps retrying and re-snapshots on connect. Changing this
    // to throw, or to leave isInitialized false, would diverge from every other
    // client SDK and can break app startup on a transient blip.
    expect(client.isInitialized, isTrue);
    expect(client.boolVariation('anything', defaultValue: false), isFalse);
    expect(client.stringVariation('anything', defaultValue: 'fallback'), 'fallback');
  });
}
