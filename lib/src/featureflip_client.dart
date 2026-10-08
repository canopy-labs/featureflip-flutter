import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'anonymous_key_store.dart';
import 'featureflip_config.dart';
import 'featureflip_provider.dart';
import 'flag_cache.dart';
import 'http_client.dart';
import 'event_processor.dart';
import 'lifecycle_observer.dart';
import 'models.dart';
import 'polling_data_source.dart';
import 'read_recorder.dart';
import 'streaming_data_source.dart';

/// Process-wide cache of shared cores, keyed by SDK key.
final Map<String, _SharedFeatureflipCore> _liveCache = {};

/// The engine embeds the matched rule id in the reason as `rule-match:{id}`.
const _ruleMatchPrefix = 'rule-match:';

/// Internal shared core owning all expensive resources of a FeatureflipClient.
///
/// Refcounted: multiple [FeatureflipClient] handles can share one core, and the
/// real shutdown runs only when the last handle is closed.
class _SharedFeatureflipCore {
  final FeatureflipConfig config;
  final FeatureflipHttpClient httpClient;
  final FlagCache cache;
  late final EventProcessor eventProcessor;
  late final FeatureflipProvider provider;

  StreamingDataSource? _streamingDataSource;
  PollingDataSource? _pollingDataSource;
  LifecycleObserver? _lifecycleObserver;

  Map<String, dynamic> _currentContext;

  /// `user_id` of [_currentContext], as `track()` and read reporting send it.
  /// Cached because every flag read needs it: recomputing it per read would put
  /// a map lookup and a conversion on the hot path. [_setContext] is the only
  /// writer of the context after construction, and it refreshes this.
  String? _currentUserId;

  /// Present exactly when [httpClient] declares X-Featureflip-Reports-Evaluations,
  /// so the server is never told reads are reported while none are, or the reverse.
  late final ReadRecorder? _readRecorder;
  final AnonymousKeyStore _anonymousKeyStore;
  bool _initialized = false;
  final bool _isTestClient;
  int _refCount = 1;
  bool _isShutDown = false;
  Future<void>? _initFuture;

  _SharedFeatureflipCore({
    required this.config,
    required this.httpClient,
    required this.cache,
    required Map<String, dynamic> currentContext,
    required bool isTestClient,
    AnonymousKeyStore? anonymousKeyStore,
  })  : _currentContext = Map.of(currentContext),
        _currentUserId = _userIdOf(currentContext),
        _anonymousKeyStore = anonymousKeyStore ?? SharedPreferencesAnonymousKeyStore(),
        _isTestClient = isTestClient {
    eventProcessor = EventProcessor(
      httpClient: httpClient,
      flushInterval: Duration(seconds: config.flushIntervalSeconds),
      batchSize: config.flushBatchSize,
    );
    _readRecorder = httpClient.reportsEvaluations ? ReadRecorder(sink: eventProcessor.enqueue) : null;
    provider = FeatureflipProvider(cache, onRead: _recordRead);
  }

  _SharedFeatureflipCore._test(
    Map<String, dynamic> overrides, {
    List<EvaluationInspector> inspectors = const [],
  })  : config = FeatureflipConfig(
          clientKey: 'test-key',
          baseUrl: 'https://localhost',
          inspectors: inspectors,
        ),
        httpClient = FeatureflipHttpClient(baseUrl: 'https://localhost', clientKey: 'test-key'),
        cache = FlagCache(),
        _currentContext = {},
        _anonymousKeyStore = SharedPreferencesAnonymousKeyStore(),
        _isTestClient = true {
    eventProcessor = EventProcessor(
      httpClient: httpClient,
      flushInterval: const Duration(seconds: 30),
      batchSize: 100,
    );
    // forTesting clients make no network calls, so they report nothing.
    _readRecorder = null;
    provider = FeatureflipProvider(cache, onRead: _recordRead);
    final snapshot = <String, FlagValue>{};
    for (final entry in overrides.entries) {
      snapshot[entry.key] = FlagValue(
        value: entry.value,
        variation: 'override',
        reason: 'TEST',
      );
    }
    cache.setAll(snapshot);
    _initialized = true;
  }

  /// Atomically increment the refcount if the core is still alive.
  ///
  /// Returns true if the refcount was incremented, false if the core has
  /// already shut down (caller must construct a new one).
  bool _acquire() {
    if (_refCount <= 0) return false;
    _refCount++;
    return true;
  }

  /// Decrement the refcount. Run shutdown exactly once when it hits zero.
  ///
  /// Returns a future that completes when shutdown finishes (if triggered),
  /// or immediately if the core is still alive.
  Future<void> _release() async {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount == 0 && !_isShutDown) {
      _isShutDown = true;
      await _shutdown();
    }
  }

  /// Initializes the core: fetches flags, starts streaming/polling and lifecycle observer.
  ///
  /// Returns a stored future so that concurrent/repeat callers share exactly
  /// one initialization (the "initPromise" pattern required by the design spec).
  Future<void> initialize() {
    if (_isTestClient) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    // Resolve a persisted anonymous user_id into the working context before the
    // first evaluate, so evaluate, SSE, polling, and track() all carry it.
    // Guarded: a shared_preferences platform/channel error must degrade to the
    // raw context, not break initialization.
    try {
      _setContext(await resolveAnonymousContext(_currentContext, _anonymousKeyStore));
    } catch (err) {
      // Persistence unavailable — proceed with the caller's context. Logged
      // rather than swallowed: it silently changes bucketing for anonymous
      // users, so it must not be invisible.
      debugPrint('[featureflip] anonymous id unavailable, using the raw context: $err');
    }
    try {
      final response = await httpClient.evaluate(
        _currentContext,
        timeout: Duration(seconds: config.initTimeoutSeconds),
      );
      cache.setAll(response.flags);
    } catch (err) {
      // NON-TERMINAL BY DESIGN — do not rethrow, and do not leave _initialized
      // false. The data source started below retries forever and re-snapshots on
      // connect, so a cold-start failure is recoverable; meanwhile every flag
      // serves the caller's default. This matches the browser SDK's documented
      // contract, and throwing here would take an app down at startup over a
      // transient blip.
      //
      // But it must not be SILENT. A wrong key in a release build, a 401 from a
      // revoked key, captive-portal wifi and a backend blip otherwise all present
      // exactly like a healthy start, and every flag quietly serves its default
      // forever. The log is the only thing that distinguishes them (#2290).
      debugPrint('[featureflip] initial flag fetch failed, serving defaults until the '
          'data source recovers: $err');
    }

    _startDataSource();
    eventProcessor.start();

    _lifecycleObserver = LifecycleObserver(
      onForeground: _handleForeground,
      onBackground: _handleBackground,
    );
    _lifecycleObserver!.register();

    _initialized = true;
  }

  /// Stops all resources and removes from cache.
  Future<void> _shutdown() async {
    // Remove from cache first (only if we're still the cached entry)
    _liveCache.removeWhere((key, core) => identical(core, this));

    _streamingDataSource?.stop();
    _streamingDataSource = null;
    _pollingDataSource?.stop();
    _pollingDataSource = null;
    await _lifecycleObserver?.pendingBackground;
    _lifecycleObserver?.unregister();
    _lifecycleObserver = null;
    await eventProcessor.stop();
    httpClient.close();
  }

  // Variation methods

  bool boolVariation(String key, {required bool defaultValue}) {
    final flag = cache.get(key);
    final value = (flag == null || flag.value is! bool) ? defaultValue : flag.value as bool;
    _notifyInspectors(key, flag, value);
    _recordRead(key, flag);
    return value;
  }

  String stringVariation(String key, {required String defaultValue}) {
    final flag = cache.get(key);
    final value = (flag == null || flag.value is! String) ? defaultValue : flag.value as String;
    _notifyInspectors(key, flag, value);
    _recordRead(key, flag);
    return value;
  }

  double numberVariation(String key, {required double defaultValue}) {
    final flag = cache.get(key);
    final raw = flag?.value;
    final value = raw is num ? raw.toDouble() : defaultValue;
    _notifyInspectors(key, flag, value);
    _recordRead(key, flag);
    return value;
  }

  dynamic jsonVariation(String key, {required dynamic defaultValue}) {
    final flag = cache.get(key);
    final value = flag == null ? defaultValue : flag.value;
    _notifyInspectors(key, flag, value);
    _recordRead(key, flag);
    return value;
  }

  /// Reports a read of [key] (see [ReadRecorder]). On every read, so it stays
  /// allocation-free: a null check, then the recorder's repeat path.
  void _recordRead(String key, FlagValue? flag) {
    _readRecorder?.record(key, flag?.variation, _currentUserId);
  }

  void _setContext(Map<String, dynamic> context) {
    _currentContext = context;
    _currentUserId = _userIdOf(context);
  }

  static String? _userIdOf(Map<String, dynamic> context) {
    final userId = context['user_id'];
    return userId is String ? userId : userId?.toString();
  }

  /// Fire the registered inspectors. Called once per variation call, after type
  /// coercion, so [value] is exactly what the accessor returns. A throwing
  /// inspector is isolated: it neither breaks the returned value nor stops the
  /// remaining inspectors.
  void _notifyInspectors(String key, FlagValue? flag, dynamic value) {
    final inspectors = config.inspectors;
    if (inspectors.isEmpty || _isShutDown) return;

    // The flag is absent from the snapshot (unknown key, not yet initialized,
    // or not clientSideVisible). The server never sent a reason for it, so
    // synthesize one in the same kebab-case the rest of the reasons use.
    final reason = flag?.reason ?? 'flag-not-found';
    String? ruleId;
    if (reason.startsWith(_ruleMatchPrefix)) {
      final suffix = reason.substring(_ruleMatchPrefix.length);
      if (suffix.isNotEmpty) ruleId = suffix;
    }

    final event = EvaluationEvent(
      flagKey: key,
      // Copy, so a buggy inspector cannot mutate core state.
      context: Map.of(_currentContext),
      value: value,
      variationKey: flag?.variation,
      reason: reason,
      ruleId: ruleId,
      prerequisiteKey: flag?.prerequisiteKey,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );

    for (final inspector in inspectors) {
      try {
        inspector(event);
      } catch (err) {
        // ignore: avoid_print
        print('[featureflip] evaluation inspector threw: $err');
      }
    }
  }

  // Identify

  Future<void> identify(Map<String, dynamic> context) async {
    // Let any in-flight initialization finish first so its anon-id resolution
    // and data-source startup don't clobber this identify (and so updateContext
    // below reaches an already-started data source).
    final initFuture = _initFuture;
    if (initFuture != null) {
      try {
        await initFuture;
      } catch (_) {
        // init failure is already handled inside _doInitialize
      }
    }
    var resolved = context;
    try {
      resolved = await resolveAnonymousContext(context, _anonymousKeyStore);
    } catch (_) {
      // persistence unavailable — use the caller's context
    }
    final connectionId = _streamingDataSource?.connectionId;
    final response = await httpClient.identify(resolved, connectionId: connectionId);
    cache.setAll(response.flags);
    _setContext(Map.of(resolved));
    _streamingDataSource?.updateContext(resolved);
    _pollingDataSource?.updateContext(resolved);
    provider.updateFlags();
  }

  // Track

  void track(String eventName, {Map<String, dynamic>? metadata}) {
    final event = SdkEvent(
      type: 'Custom',
      flagKey: eventName,
      userId: _currentUserId,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      metadata: metadata,
    );
    eventProcessor.enqueue(event);
  }

  // Flush

  Future<void> flush() async {
    await eventProcessor.flush();
  }

  Map<String, FlagValue> allFlags() => cache.all();

  // Private

  void _startDataSource() {
    // Idempotent, and that is load-bearing rather than defensive (#3075). An orphaned
    // streaming source used to stop itself at the retry cap; it now retries forever
    // AND keeps calling back into this core, so one left running by a second
    // _startDataSource() could retire the live source's fallback poller mid-outage and
    // leave the app uncovered by either.
    if (_streamingDataSource != null) return;
    if (config.streaming) {
      _streamingDataSource = StreamingDataSource(
        baseUrl: config.baseUrl,
        clientKey: config.clientKey,
        context: _currentContext,
        onChange: _handleStreamUpdate,
        // First flags-updated after (re)connect is the full snapshot -> REPLACE,
        // so a flag deleted during an outage is dropped on reconnect.
        onSnapshot: _handleFullUpdate,
        // Stream exhausted its retries -> poll ALONGSIDE it until it recovers.
        onFallbackToPolling: _handleStreamingFallback,
        onStreamRecovered: _stopFallbackPolling,
      );
      _streamingDataSource!.start();
    } else {
      _startPolling();
    }
  }

  /// Streaming exhausted its retries: start polling to cover the outage.
  ///
  /// The streaming source is deliberately NOT stopped or nulled (#3075). Nulling it
  /// is what used to make the fallback permanent — nothing would ever have restarted
  /// streaming, so the app lost real-time updates until it was killed. It kept
  /// `_handleForeground`/`identify` from resurrecting a *dormant* stream beside the
  /// poller (#1902), but the stream is no longer dormant: it keeps retrying
  /// underneath, so those two call sites act on the one live source that already
  /// exists and cannot create a second. `_startDataSource` is the only construction
  /// site and runs once.
  void _handleStreamingFallback() {
    // A source detached by close() can still fire this: acting on it would start a
    // poller nothing holds a reference to, polling for the rest of the process's life.
    if (_streamingDataSource == null) return;
    _startPolling();
  }

  /// Retires a polling fallback once the stream is carrying configuration again.
  /// Clears the reference as well as stopping the poller, so a later outage falls
  /// back again — [_startPolling] refuses to start a second poller while one is
  /// referenced, and a dead one parked there would leave the next outage uncovered.
  void _stopFallbackPolling() {
    if (_streamingDataSource == null) return;
    _pollingDataSource?.stop();
    _pollingDataSource = null;
  }

  void _startPolling() {
    // Idempotent: a stream->polling fallback must start at most one poller.
    if (_pollingDataSource != null) return;
    _pollingDataSource = PollingDataSource(
      httpClient: httpClient,
      context: _currentContext,
      interval: Duration(seconds: config.pollIntervalSeconds),
      onChange: _handleFullUpdate,
    );
    _pollingDataSource!.start();
  }

  void _handleStreamUpdate(Map<String, FlagValue> flags) {
    bool changed = false;
    final current = Map.of(cache.all());

    for (final entry in flags.entries) {
      if (entry.value.reason == 'FLAG_REMOVED' && entry.value.value == null) {
        if (current.containsKey(entry.key)) {
          current.remove(entry.key);
          changed = true;
        }
      } else {
        final existing = current[entry.key];
        if (existing != entry.value) {
          current[entry.key] = entry.value;
          changed = true;
        }
      }
    }

    if (changed) {
      cache.setAll(current);
      provider.updateFlags();
    }
  }

  void _handleFullUpdate(Map<String, FlagValue> flags) {
    final oldFlags = cache.all();
    if (_mapsEqual(oldFlags, flags)) return;
    cache.setAll(flags);
    provider.updateFlags();
  }

  static bool _mapsEqual(Map<String, FlagValue> a, Map<String, FlagValue> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  void _handleForeground() {
    // The recorder's Stopwatch stood still while the device slept, so a read
    // reported before a long sleep would stay deduped after waking, and the
    // server's last report could fall outside the archive guard's 24 h.
    // Re-report from scratch on every resume; it costs at most one event per
    // flag the app reads again.
    _readRecorder?.resetWindow();
    _streamingDataSource?.start();
    _pollingDataSource?.start();
  }

  Future<void> _handleBackground() async {
    _streamingDataSource?.stop();
    _pollingDataSource?.stop();
    await eventProcessor.flush();
  }
}

/// Main public API for the Featureflip Flutter SDK.
///
/// Obtain instances via the [FeatureflipClient.get] static factory. Multiple
/// calls with the same SDK key return handles sharing one underlying connection
/// (refcounted). The connection shuts down only when the last handle is closed.
///
/// ```dart
/// final client = FeatureflipClient.get('sdk-key-123', config: config);
/// await client.initialize();
///
/// final enabled = client.boolVariation('feature', defaultValue: false);
///
/// await client.close(); // decrements refcount; shuts down if last handle
/// ```
class FeatureflipClient {
  /// SDK version.
  static const version = '2.0.0';

  final _SharedFeatureflipCore _core;
  bool _disposed = false;

  FeatureflipClient._(this._core);

  /// Obtains a client handle for the given SDK key.
  ///
  /// If a shared core already exists for [sdkKey], returns a new handle to it
  /// (refcount incremented). Otherwise, creates a fresh core.
  ///
  /// If [config] differs from the cached instance's config, a warning is
  /// logged and the cached config is preserved.
  static FeatureflipClient get(String sdkKey, {required FeatureflipConfig config}) =>
      _get(sdkKey, config);

  /// [get], with the HTTP transport and the anonymous-id store supplied by a
  /// test. The core is cached under [sdkKey] exactly as [get] caches it, so a
  /// later [get] for the same key returns a handle on this core.
  @visibleForTesting
  static FeatureflipClient getWithHttpClientForTesting(
    String sdkKey, {
    required FeatureflipConfig config,
    required http.Client httpClient,
    AnonymousKeyStore? anonymousKeyStore,
  }) =>
      _get(sdkKey, config, transport: httpClient, anonymousKeyStore: anonymousKeyStore);

  static FeatureflipClient _get(
    String sdkKey,
    FeatureflipConfig config, {
    http.Client? transport,
    AnonymousKeyStore? anonymousKeyStore,
  }) {
    final existing = _liveCache[sdkKey];
    if (existing != null && existing._acquire()) {
      // sendEvaluationEvents is warned about, unlike streaming or the intervals:
      // a caller turning reporting off must not have it silently stay on (and
      // keep declaring it to the server) because another handle got there first.
      if (existing.config.clientKey != config.clientKey ||
          existing.config.baseUrl != config.baseUrl ||
          existing.config.sendEvaluationEvents != config.sendEvaluationEvents) {
        debugPrint(
          'FeatureflipClient.get() called with different config for SDK key '
          'already in use; the cached instance\'s config is preserved.',
        );
      }
      return FeatureflipClient._(existing);
    }

    // Stale entry or cache miss — create fresh core
    if (existing != null) {
      _liveCache.remove(sdkKey);
    }

    final httpClient = FeatureflipHttpClient(
      baseUrl: config.baseUrl,
      clientKey: config.clientKey,
      client: transport,
      reportsEvaluations: config.sendEvaluationEvents,
    );
    final core = _SharedFeatureflipCore(
      config: config,
      httpClient: httpClient,
      cache: FlagCache(),
      currentContext: config.context,
      isTestClient: false,
      anonymousKeyStore: anonymousKeyStore,
    );
    _liveCache[sdkKey] = core;
    return FeatureflipClient._(core);
  }

  /// Creates a no-network test client with static flag overrides.
  ///
  /// Test clients do not participate in the shared cache and each call
  /// returns an independent client.
  static FeatureflipClient forTesting(
    Map<String, dynamic> overrides, {
    List<EvaluationInspector> inspectors = const [],
  }) {
    return FeatureflipClient._(
      _SharedFeatureflipCore._test(overrides, inspectors: inspectors),
    );
  }

  /// Clears the shared core cache. For test isolation only.
  @visibleForTesting
  static void resetForTesting() {
    final cores = List.of(_liveCache.values);
    _liveCache.clear();
    for (final core in cores) {
      core._release();
    }
  }

  /// Whether the client has completed initialization.
  /// Whether the client has loaded flags and is ready to evaluate.
  ///
  /// False once this handle is closed: `close()` releases the core, so the handle
  /// can no longer evaluate anything (#2291).
  bool get isInitialized => !_disposed && _core._initialized;

  /// Flutter widget integration provider.
  FeatureflipProvider get flagProvider => _core.provider;

  /// Initializes the client: fetches flags, starts streaming/polling.
  Future<void> initialize() => _core.initialize();

  /// Closes this handle.
  ///
  /// Decrements the refcount on the shared core. If this is the last handle,
  /// the core shuts down (stops streaming, flushes events, closes HTTP).
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await _core._release();
  }

  // A closed handle serves the caller's default (#2291, contract from #2313).
  // close() releases the core — stopping streaming, flushing events, unregistering
  // the lifecycle observer — but the in-memory cache stays readable, so without
  // these guards the handle would keep serving a frozen snapshot that can never
  // update again.

  /// Returns a boolean flag value, or the default if missing, not a bool, or closed.
  bool boolVariation(String key, {required bool defaultValue}) => _disposed
      ? defaultValue
      : _core.boolVariation(key, defaultValue: defaultValue);

  /// Returns a string flag value, or the default if missing, not a string, or closed.
  String stringVariation(String key, {required String defaultValue}) => _disposed
      ? defaultValue
      : _core.stringVariation(key, defaultValue: defaultValue);

  /// Returns a numeric flag value, or the default if missing, not a number, or closed.
  double numberVariation(String key, {required double defaultValue}) => _disposed
      ? defaultValue
      : _core.numberVariation(key, defaultValue: defaultValue);

  /// Returns the raw flag value, or the default if missing or closed.
  dynamic jsonVariation(String key, {required dynamic defaultValue}) => _disposed
      ? defaultValue
      : _core.jsonVariation(key, defaultValue: defaultValue);

  /// Re-evaluates flags for a new user context.
  Future<void> identify(Map<String, dynamic> context) =>
      _core.identify(context);

  /// Enqueues a custom analytics event.
  void track(String eventName, {Map<String, dynamic>? metadata}) =>
      _core.track(eventName, metadata: metadata);

  /// Force-flushes pending analytics events.
  Future<void> flush() => _core.flush();

  /// Returns all current flag values, or an empty map once closed — the
  /// bulk-read analogue of a variation falling back to its default.
  ///
  /// Not reported as a read: a flag your code reaches only through `allFlags()`
  /// looks unused to Featureflip, so it can be marked stale and archived.
  Map<String, FlagValue> allFlags() => _disposed ? const {} : _core.allFlags();
}
