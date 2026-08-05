# Featureflip Flutter SDK

Flutter SDK for [Featureflip](https://featureflip.io) — evaluate feature flags in Flutter apps with real-time updates.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  featureflip: ^2.4.1
```

Then run:

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:featureflip/featureflip.dart';

final config = FeatureflipConfig(clientKey: 'your-client-sdk-key');
final client = FeatureflipClient.get('your-client-sdk-key', config: config);

await client.initialize();

final enabled = client.boolVariation('my-feature', defaultValue: false);

if (enabled) {
  print('Feature is enabled!');
}

await client.close();
```

## Configuration

```dart
final config = FeatureflipConfig(
  clientKey: 'your-client-sdk-key',
  baseUrl: 'https://eval.featureflip.io',       // Evaluation API URL (default)
  context: {'user_id': '123'},                    // Initial evaluation context
  streaming: true,                                // SSE for real-time updates (default)
  pollIntervalSeconds: 30,                        // Polling interval in seconds
  flushIntervalSeconds: 30,                       // Event flush interval in seconds
  flushBatchSize: 100,                            // Events per batch
  initTimeoutSeconds: 10,                         // Max seconds to wait for initialization
);
```

## Lifetime

`FeatureflipClient.get()` is the only way to obtain a client. Calling it multiple times with the same SDK key returns handles that share a single underlying connection — safe for any registration lifetime (singleton, scoped, transient).

```dart
final client1 = FeatureflipClient.get('key', config: config);
final client2 = FeatureflipClient.get('key', config: config);

// client1 and client2 share one connection (refcounted).
// The connection shuts down only when the last handle is closed.

await client1.close(); // decrements refcount
await client2.close(); // refcount → 0, connection shut down
```

## Evaluation

```dart
// Boolean flag
final enabled = client.boolVariation('feature-key', defaultValue: false);

// String flag
final tier = client.stringVariation('pricing-tier', defaultValue: 'free');

// Number flag
final limit = client.numberVariation('rate-limit', defaultValue: 100.0);

// JSON flag
final uiConfig = client.jsonVariation('ui-config', defaultValue: {'theme': 'light'});
```

## Identify

Re-evaluate all flags with a new context (e.g., after login):

```dart
await client.identify({'user_id': '123', 'plan': 'pro'});
```

## Event Tracking

```dart
// Track custom events
client.track('checkout-completed', metadata: {'total': 99.99});

// Force flush pending events
await client.flush();
```

## Flutter Widget Integration

Use `FeatureflipProvider` with `ListenableBuilder` for reactive flag values:

```dart
import 'package:featureflip/featureflip.dart';

class MyApp extends StatelessWidget {
  final FeatureflipClient client;
  const MyApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client.flagProvider,
      builder: (context, _) {
        final showBanner = client.flagProvider.boolVariation(
          'show-banner',
          defaultValue: false,
        );
        return showBanner ? const BannerWidget() : const SizedBox.shrink();
      },
    );
  }
}
```

## Testing

Use `forTesting()` to create a client with predetermined flag values — no network calls.

```dart
final client = FeatureflipClient.forTesting({
  'my-feature': true,
  'pricing-tier': 'pro',
});

client.boolVariation('my-feature', defaultValue: false);     // true
client.stringVariation('pricing-tier', defaultValue: 'free'); // 'pro'
client.boolVariation('unknown', defaultValue: false);         // false (default)
```

For test isolation, call `resetForTesting()` in your test teardown:

```dart
tearDown(() {
  FeatureflipClient.resetForTesting();
});
```

## Features

- **Client-side evaluation** — Flags evaluated server-side, only values returned
- **Real-time updates** — SSE streaming with automatic polling fallback
- **Singleton by construction** — Same SDK key always shares one connection
- **Refcounted lifecycle** — Connection shuts down when the last handle closes
- **Event tracking** — Automatic batching and background flushing
- **Test support** — `forTesting()` factory for deterministic unit tests
- **Flutter integration** — `FeatureflipProvider` for reactive flag values
- **Lifecycle management** — Automatic pause/resume on app lifecycle changes

## Requirements

- Flutter 3.24+
- Dart 3.5+

## License

Apache-2.0
