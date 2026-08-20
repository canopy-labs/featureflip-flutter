## 2.5.0 — 2026-08-20

### Fixed

- A closed handle serves the caller's default from every accessor and reports not-initialized. `close()` releases the shared core — stopping streaming and polling, shutting down the event processor — but the in-memory cache stayed readable, so a closed client kept evaluating against a frozen snapshot that could never update again while still reporting itself initialized. ([#2291](https://github.com/canopy-labs/featureflip/issues/2291))

- A failed initial flag fetch is now diagnosable rather than swallowed by a bare `catch (_)`. ([#2290](https://github.com/canopy-labs/featureflip/issues/2290))
## 2.4.1 — 2026-08-05

### Fixed

- `LICENSE` is now the verbatim Apache-2.0 text. Three phrases in the operative sections had been reworded and the appendix dropped, which left automated license scanners unable to identify it. The license itself is unchanged; the file now says what it always claimed to.
- The README's `pubspec.yaml` snippet says `^2.4.1`. It said `^2.0.0` in the repo and on the mirror, while pub.dev showed a different value again — the publish workflow rewrote that line on its way out, so the three copies disagreed. The rewrite is gone and all three now come from one source.

## 2.4.0 — 2026-07-29

### Added

- **`onEvaluation` inspector callback.** `inspectors` config option registering in-process observers fired on every evaluation. Notified from the four variation accessors after type coercion — `flagDetail()` and all-flags accessors stay silent so one decision is never double-counted. `reason` is the engine's kebab-case string forwarded verbatim; a flag absent from the snapshot synthesizes `flag-not-found` (#1914).

## 2.3.0 — 2026-07-13

### Fixed

- Outage-recovery hardening: replace-on-reconnect, so a flag deleted while disconnected is dropped (#1883).
- The connect-snapshot store replacement is keyed off the explicit `full: true` marker rather than event order, which was ambiguous when a delta arrived first (#1887).

## 2.2.0 — 2026-06-19

### Added

- A generated anonymous `user_id` is persisted via `shared_preferences` and injected at every evaluate/identify/SSE call, so anonymous users bucket consistently across sessions (#1467).

## 2.1.0 — 2026-05-27

### Added

- **`FlagValue.prerequisiteKey`.** Optional `String?` on `FlagValue` carrying the key of the prerequisite flag that caused this flag to serve its off variation. Populated by the server on `/v1/client/evaluate` and `/v1/client/identify` responses when `reason == "prerequisite-failed"`; null for all other reasons. `toJson` omits the field when null, preserving the existing wire shape for older consumers (#1124).

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
