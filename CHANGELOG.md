## 2.0.0

**BREAKING:** Singleton-by-construction refactor.

- **Removed** public constructor `FeatureflipClient(config:)`, `FeatureflipClient.withHttpClient()`, `FeatureflipClient.configure()`, and `FeatureflipClient.shared`.
- **Added** `FeatureflipClient.get(sdkKey, config:)` static factory — the only way to obtain a client. Multiple calls with the same SDK key return handles sharing one refcounted core.
- **Added** `FeatureflipClient.resetForTesting()` for test isolation.
- `FeatureflipClient.forTesting()` unchanged — continues to create independent test clients.

### Migration

Before:
```dart
final client = FeatureflipClient(config: config);
// or
FeatureflipClient.configure(config);
final client = FeatureflipClient.shared;
```

After:
```dart
final client = FeatureflipClient.get('your-sdk-key', config: config);
```

## 1.0.0

- Initial release
