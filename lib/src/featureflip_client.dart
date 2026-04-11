import 'package:flutter/foundation.dart';

import 'featureflip_config.dart';
import 'featureflip_provider.dart';
import 'flag_cache.dart';
import 'http_client.dart';
import 'event_processor.dart';
import 'lifecycle_observer.dart';
import 'models.dart';
import 'polling_data_source.dart';
import 'streaming_data_source.dart';

/// Process-wide cache of shared cores, keyed by SDK key.
final Map<String, _SharedFeatureflipCore> _liveCache = {};

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
  })  : _currentContext = Map.of(currentContext),
        _isTestClient = isTestClient {
    eventProcessor = EventProcessor(
      httpClient: httpClient,
      flushInterval: Duration(seconds: config.flushIntervalSeconds),
      batchSize: config.flushBatchSize,
    );
    provider = FeatureflipProvider(cache);
  }

  _SharedFeatureflipCore._test(Map<String, dynamic> overrides)
      : config = const FeatureflipConfig(clientKey: 'test-key', baseUrl: 'https://localhost'),
        httpClient = FeatureflipHttpClient(baseUrl: 'https://localhost', clientKey: 'test-key'),
        cache = FlagCache(),
        _currentContext = {},
        _isTestClient = true {
    eventProcessor = EventProcessor(
      httpClient: httpClient,
      flushInterval: const Duration(seconds: 30),
      batchSize: 100,
    );
    provider = FeatureflipProvider(cache);
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
    try {
      final response = await httpClient.evaluate(
        config.context,
        timeout: Duration(seconds: config.initTimeoutSeconds),
      );
      cache.setAll(response.flags);
    } catch (_) {
      // Use empty cache if network fails
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
    if (flag == null || flag.value is! bool) return defaultValue;
    return flag.value as bool;
  }

  String stringVariation(String key, {required String defaultValue}) {
    final flag = cache.get(key);
    if (flag == null || flag.value is! String) return defaultValue;
    return flag.value as String;
  }

  double numberVariation(String key, {required double defaultValue}) {
    final flag = cache.get(key);
    if (flag == null) return defaultValue;
    final value = flag.value;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return defaultValue;
  }

  dynamic jsonVariation(String key, {required dynamic defaultValue}) {
    final flag = cache.get(key);
    if (flag == null) return defaultValue;
    return flag.value;
  }

  // Identify

  Future<void> identify(Map<String, dynamic> context) async {
    final connectionId = _streamingDataSource?.connectionId;
    final response = await httpClient.identify(context, connectionId: connectionId);
    cache.setAll(response.flags);
    _currentContext = Map.of(context);
    _streamingDataSource?.updateContext(context);
    _pollingDataSource?.updateContext(context);
    provider.updateFlags();
  }

  // Track

  void track(String eventName, {Map<String, dynamic>? metadata}) {
    final userId = _currentContext['user_id'];
    final event = SdkEvent(
      type: 'Custom',
      flagKey: eventName,
      userId: userId is String ? userId : userId?.toString(),
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
    if (config.streaming) {
      _streamingDataSource = StreamingDataSource(
        baseUrl: config.baseUrl,
        clientKey: config.clientKey,
        context: _currentContext,
        onChange: _handleStreamUpdate,
        onMaxRetriesReached: _handleStreamingFallback,
      );
      _streamingDataSource!.start();
    } else {
      _startPolling();
    }
  }

  void _handleStreamingFallback() {
    _streamingDataSource?.stop();
    _streamingDataSource = null;
    _startPolling();
  }

  void _startPolling() {
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
  static FeatureflipClient get(String sdkKey, {required FeatureflipConfig config}) {
    final existing = _liveCache[sdkKey];
    if (existing != null && existing._acquire()) {
      if (existing.config.clientKey != config.clientKey ||
          existing.config.baseUrl != config.baseUrl) {
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
    );
    final core = _SharedFeatureflipCore(
      config: config,
      httpClient: httpClient,
      cache: FlagCache(),
      currentContext: config.context,
      isTestClient: false,
    );
    _liveCache[sdkKey] = core;
    return FeatureflipClient._(core);
  }

  /// Creates a no-network test client with static flag overrides.
  ///
  /// Test clients do not participate in the shared cache and each call
  /// returns an independent client.
  static FeatureflipClient forTesting(Map<String, dynamic> overrides) {
    return FeatureflipClient._(_SharedFeatureflipCore._test(overrides));
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
  bool get isInitialized => _core._initialized;

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

  /// Returns a boolean flag value, or the default if missing or not a bool.
  bool boolVariation(String key, {required bool defaultValue}) =>
      _core.boolVariation(key, defaultValue: defaultValue);

  /// Returns a string flag value, or the default if missing or not a string.
  String stringVariation(String key, {required String defaultValue}) =>
      _core.stringVariation(key, defaultValue: defaultValue);

  /// Returns a numeric flag value, or the default if missing or not a number.
  double numberVariation(String key, {required double defaultValue}) =>
      _core.numberVariation(key, defaultValue: defaultValue);

  /// Returns the raw flag value, or the default if missing.
  dynamic jsonVariation(String key, {required dynamic defaultValue}) =>
      _core.jsonVariation(key, defaultValue: defaultValue);

  /// Re-evaluates flags for a new user context.
  Future<void> identify(Map<String, dynamic> context) =>
      _core.identify(context);

  /// Enqueues a custom analytics event.
  void track(String eventName, {Map<String, dynamic>? metadata}) =>
      _core.track(eventName, metadata: metadata);

  /// Force-flushes pending analytics events.
  Future<void> flush() => _core.flush();

  /// Returns all current flag values.
  Map<String, FlagValue> allFlags() => _core.allFlags();
}
