# Featureflip Flutter SDK

Flutter SDK for [Featureflip](https://featureflip.io) — evaluate feature flags in Flutter apps with real-time updates.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  featureflip: ^1.0.0
```

Then run:

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:featureflip/featureflip.dart';

final config = FeatureflipConfig(clientKey: 'your-client-sdk-key');
final client = FeatureflipClient(config: config);

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

## Singleton Pattern

```dart
FeatureflipClient.configure(config);

// Access from anywhere
final enabled = FeatureflipClient.shared.boolVariation('my-feature', defaultValue: false);
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
final config = client.jsonVariation('ui-config', defaultValue: {'theme': 'light'});
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

## Features

- **Client-side evaluation** — Flags evaluated server-side, only values returned
- **Real-time updates** — SSE streaming with automatic polling fallback
- **Event tracking** — Automatic batching and background flushing
- **Test support** — `forTesting()` factory for deterministic unit tests
- **Flutter integration** — `FeatureflipProvider` for reactive flag values
- **Lifecycle management** — Automatic pause/resume on app lifecycle changes
- **Singleton or instance** — `configure`/`shared` pattern or manual instantiation

## Requirements

- Flutter 3.24+
- Dart 3.5+

## License

MIT
