

## 2.7.0 — 2026-10-07

### Added

- The SDK now reports which flags your app reads. The first read of a flag in each hour, and again after the app returns to the foreground, queues one `Evaluation` event for each variation and `user_id`. Events go to `/v1/client/events` with your `track()` events, on the same 30-second flush and when the app goes to the background. Reads through `boolVariation`, `stringVariation`, `numberVariation`, `jsonVariation` and the same methods on `flagProvider` count, including a read of a flag the SDK doesn't have, which is reported with no variation. `allFlags()` doesn't count. A repeat read inside the hour sends nothing and costs almost nothing. (#3545)
- Requests to `/v1/client/evaluate` and `/v1/client/identify` now carry `X-Featureflip-Reports-Evaluations: 1`. The header tells the server this client reports its own reads, so the server stops recording an evaluation for every flag it sends to the device. (#3545)
- New option `FeatureflipConfig.sendEvaluationEvents`, default `true`. Set it to `false` to send no `Evaluation` events and no header. The server then records every flag it sends, as before. (#3545)

### Changed

- Evaluation analytics for client-side flags now count deduplicated reads. Before, each flag served to a device counted as one evaluation per app launch. Expect the numbers to drop as your users upgrade. (#3545)
- Client-side flags that are sent to devices but never read can now show as stale, which can trigger stale-flag notice emails. Before, every flag sent to a device looked evaluated. Likewise, a client-side flag whose code you removed can now be archived once no client has read it recently, as your users upgrade. Before, the archive was refused indefinitely. (#3545)
- A second `FeatureflipClient.get()` for the same SDK key with a different `sendEvaluationEvents` now logs the config-mismatch warning. The first client's setting still applies. (#3545)

## 2.6.3 — 2026-10-01

### Changed

- The pub.dev listing now carries the topics `feature-flags`, `feature-toggles`, `feature-management` and `sdk`, so the package appears under those tags. No code changes.

## 2.6.2 — 2026-09-19

### Fixed

- `track()` events now reach the server. They were posted to `/v1/sdk/events`, which accepts server SDK keys only — so every batch came back `401`, which the event processor correctly classifies as permanent and discards. Nothing was retried and nothing was logged above debug, so `track()` was a public API that silently did nothing. Events now post to `/v1/client/events`, the client-surface ingest this SDK's other calls already use. `identify()` and flag evaluation were never affected — `identify()` round-trips `/v1/client/identify`, and evaluations are recorded server-side on this SDK's behalf. Requires an Evaluation API that serves that endpoint; against an older one, events are dropped exactly as before. (#3069)
- The polling fallback no longer ends the SSE stream. After five consecutive failures — about 31 seconds of unreachability, so an edge incident, a bad deploy or a network partition — this SDK stopped the streaming source and cleared its reference before starting the poller, and nothing ever re-opened it: the app lost real-time updates for the rest of its life and polled `/v1/client/evaluate` every 30 seconds until it was killed. Flag changes, kill switches included, then arrived up to a poll interval late. Polling is now additive — it covers the outage while the stream keeps retrying underneath at the capped backoff, and the next delivered configuration frame retires the poller. Retiring it matters as much as arming it: a poller left running beside a healthy stream reverts SSE deltas with its own whole-store replaces. (#3075)
- The consecutive-failure counter now resets on a delivered configuration frame rather than on the connection handshake. A server that accepts a connection and then closes it without sending anything satisfied the handshake on every cycle, so the counter never accumulated — and with the stream now retrying indefinitely, that is the case where the fallback above would never arm at all. (#3075)
- Three races around the fallback's lifetime are closed: a poll already in flight when the poller was retired could land afterwards and revert the stream's snapshot; a fallback callback arriving after `close()` could start a poller nothing could stop; and returning to the foreground could resurrect a just-retired one. (#3075)
- One failed SSE connection no longer spends two retries or leaves a second connection live. `_scheduleRetry` was wired to both `onError` and `onDone`, so a single failure scheduled two reconnects, and the second `_connect()` could not be cancelled by the timer that had already fired — leaving two live streams with only the newer one referenced. `identify()` reached the same state by a shorter route. Each connection now carries an identity, so it spends exactly one retry and a superseded response cannot install itself. (#3075)

## 2.6.1 — 2026-08-26

### Fixed

- An explicit `client.flush()` no longer opens a second drain loop while one is already running. The in-flight latch added for #2456 guarded only the batch-size trigger, so the periodic flush, an explicit `client.flush()` and a size-triggered flush could enter the loop together — two request streams against an endpoint the backoff gate exists to protect, and worse, a success in one cleared the gate a failure in the other had just armed, re-opening the one-request-per-evaluation behaviour outright. A caller arriving while a drain is running now waits for it and returns, matching the js and node SDKs. Shutdown still bypasses coalescing, because it is the last drain there will ever be. (#2477)

- The first SSE reconnect after a healthy stream drops is now jittered to `[d/2, d]`, like every other backoff level. The drops this absorbs are fleet-wide — a single edge event severs every stream at once — so every client re-entered the backoff together and waited an identical delay, republishing the drop's own synchronisation as a reconnect spike one backoff later. Measured in production: a drop spread across 2.5–3.0 ms produced a reconnect spread of 26–46 ms. The delay never exceeds the previous one and stays strictly positive, so a stream that fails immediately still cannot busy-loop. (#2508)

## 2.6.0 — 2026-08-24

### Fixed

- A permanently rejected batch of analytics events is no longer retried forever. The flush restored the batch on *any* error, so a 401/403 (rejected SDK key) or 400 (malformed body) would be re-sent indefinitely, pinning the buffer at its cap and starving every later event. Only a retryable failure — 5xx, 429, or a transport fault — is kept now. (#2456)
- A failing events endpoint no longer receives one request per recorded event. A restored batch leaves the buffer at or above the batch size, so every subsequent event re-fired the size trigger. That trigger now backs off for one flush interval after a retryable failure and will not start a second flush while one is running; the periodic timer remains the retry vehicle. (#2456)
- A flush failure is now reported. The failure was swallowed by a bare `catch (_)`, so events could be retried or discarded with nothing written to the log. (#2456)
- `stop()` makes a single final attempt and discards the remainder, rather than restoring a batch into a buffer nothing will ever drain again. (#2456)

### Changed

- A flush sends one request per batch instead of one for the whole buffer. Restoring failed batches is what lets the buffer reach its 1000-event cap, and a body that size invites a 413 — which is not retryable, so the path meant to preserve the backlog would have been the one that discarded it. (#2456)

## 2.5.0 — 2026-08-20

### Fixed

- A closed handle serves the caller's default from every accessor and reports not-initialized. `close()` releases the shared core — stopping streaming and polling, shutting down the event processor — but the in-memory cache stayed readable, so a closed client kept evaluating against a frozen snapshot that could never update again while still reporting itself initialized. (#2291)

- A failed initial flag fetch is now diagnosable rather than swallowed by a bare `catch (_)`. (#2290)

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
``dart
final client = FeatureflipClient(config: config);
// or
FeatureflipClient.configure(config);
final client = FeatureflipClient.shared;
``

After:
``dart
final client = FeatureflipClient.get('your-sdk-key', config: config);
``

## 1.0.0

- Initial release
