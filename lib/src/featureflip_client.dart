import 'featureflip_config.dart';
import 'featureflip_provider.dart';
import 'flag_cache.dart';
import 'http_client.dart';
import 'event_processor.dart';
import 'lifecycle_observer.dart';
import 'models.dart';
import 'polling_data_source.dart';
import 'streaming_data_source.dart';

/// Main public API for the Featureflip Flutter SDK.
class FeatureflipClient {
  /// SDK version.
  static const version = '0.1.0';

  // Singleton
  static FeatureflipClient? _shared;

  /// The shared singleton client. Must call [configure] first.
  static FeatureflipClient get shared {
    if (_shared == null) {
      throw StateError(
        'FeatureflipClient.configure() must be called before accessing .shared',
      );
    }
    return _shared!;
  }

  /// Configures the shared singleton client.
  static void configure(FeatureflipConfig config) {
    _shared = FeatureflipClient(config: config);
  }

  final FeatureflipConfig _config;
  final FeatureflipHttpClient _httpClient;
  final FlagCache _cache;
  late final EventProcessor _eventProcessor;

  StreamingDataSource? _streamingDataSource;
  PollingDataSource? _pollingDataSource;
  LifecycleObserver? _lifecycleObserver;

  Map<String, dynamic> _currentContext;
  bool _initialized = false;
  final bool _isTestClient;

  /// Whether the client has completed initialization.
  ///
  /// Returns `true` once [initialize] has finished (regardless of whether
  /// the initial network fetch succeeded), or immediately for test clients.
  bool get isInitialized => _initialized;

  /// Flutter widget integration provider.
  late final FeatureflipProvider flagProvider = FeatureflipProvider(this);

  /// Creates a new client instance.
  FeatureflipClient({
    required FeatureflipConfig config,
    FeatureflipHttpClient? httpClient,
  })  : _config = config,
        _httpClient = httpClient ??
            FeatureflipHttpClient(
              baseUrl: config.baseUrl,
              clientKey: config.clientKey,
            ),
        _cache = FlagCache(),
        _currentContext = Map.of(config.context),
        _isTestClient = false {
    _eventProcessor = EventProcessor(
      httpClient: _httpClient,
      flushInterval: Duration(seconds: config.flushIntervalSeconds),
      batchSize: config.flushBatchSize,
    );
  }

  /// Creates a new client instance with a custom HTTP client (for testing).
  FeatureflipClient.withHttpClient({
    required FeatureflipConfig config,
    required FeatureflipHttpClient httpClient,
  })  : _config = config,
        _httpClient = httpClient,
        _cache = FlagCache(),
        _currentContext = Map.of(config.context),
        _isTestClient = false {
    _eventProcessor = EventProcessor(
      httpClient: _httpClient,
      flushInterval: Duration(seconds: config.flushIntervalSeconds),
      batchSize: config.flushBatchSize,
    );
  }

  /// Private constructor for test clients with static overrides.
  FeatureflipClient._test(Map<String, dynamic> overrides)
      : _config = const FeatureflipConfig(clientKey: 'test-key', baseUrl: 'https://localhost'),
        _httpClient = FeatureflipHttpClient(baseUrl: 'https://localhost', clientKey: 'test-key'),
        _cache = FlagCache(),
        _currentContext = {},
        _isTestClient = true {
    _eventProcessor = EventProcessor(
      httpClient: _httpClient,
      flushInterval: const Duration(seconds: 30),
      batchSize: 100,
    );
    final snapshot = <String, FlagValue>{};
    for (final entry in overrides.entries) {
      snapshot[entry.key] = FlagValue(
        value: entry.value,
        variation: 'override',
        reason: 'TEST',
      );
    }
    _cache.setAll(snapshot);
    _initialized = true;
  }

  /// Initializes the client: fetches flags, starts streaming/polling and lifecycle observer.
  Future<void> initialize() async {
    if (_isTestClient) return;

    // Fetch initial flags with timeout
    try {
      final response = await _httpClient.evaluate(
        _config.context,
        timeout: Duration(seconds: _config.initTimeoutSeconds),
      );
      _cache.setAll(response.flags);
    } catch (_) {
      // Use empty cache if network fails
    }

    // Start data source
    _startDataSource();

    // Start event processor
    _eventProcessor.start();

    // Start lifecycle observer
    _lifecycleObserver = LifecycleObserver(
      onForeground: _handleForeground,
      onBackground: _handleBackground,
    );
    _lifecycleObserver!.register();

    _initialized = true;
  }

  /// Stops streaming/polling and flushes pending events.
  Future<void> close() async {
    _streamingDataSource?.stop();
    _streamingDataSource = null;
    _pollingDataSource?.stop();
    _pollingDataSource = null;
    await _lifecycleObserver?.pendingBackground;
    _lifecycleObserver?.unregister();
    _lifecycleObserver = null;
    await _eventProcessor.stop();
    _httpClient.close();
  }

  // Variation methods

  /// Returns a boolean flag value, or the default if missing or not a bool.
  bool boolVariation(String key, {required bool defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null || flag.value is! bool) return defaultValue;
    return flag.value as bool;
  }

  /// Returns a string flag value, or the default if missing or not a string.
  String stringVariation(String key, {required String defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null || flag.value is! String) return defaultValue;
    return flag.value as String;
  }

  /// Returns a numeric flag value, or the default if missing or not a number.
  double numberVariation(String key, {required double defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null) return defaultValue;
    final value = flag.value;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return defaultValue;
  }

  /// Returns the raw flag value, or the default if missing.
  dynamic jsonVariation(String key, {required dynamic defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null) return defaultValue;
    return flag.value;
  }

  // Identify

  /// Re-evaluates flags for a new user context.
  Future<void> identify(Map<String, dynamic> context) async {
    final connectionId = _streamingDataSource?.connectionId;
    final response = await _httpClient.identify(context, connectionId: connectionId);
    _cache.setAll(response.flags);
    _currentContext = Map.of(context);
    _streamingDataSource?.updateContext(context);
    _pollingDataSource?.updateContext(context);
    flagProvider.updateFlags();
  }

  // Track

  /// Enqueues a custom analytics event.
  void track(String eventName, {Map<String, dynamic>? metadata}) {
    final userId = _currentContext['user_id'];
    final event = SdkEvent(
      type: 'Custom',
      flagKey: eventName,
      userId: userId is String ? userId : userId?.toString(),
      timestamp: DateTime.now().toUtc().toIso8601String(),
      metadata: metadata,
    );
    _eventProcessor.enqueue(event);
  }

  // Flush

  /// Force-flushes pending analytics events.
  Future<void> flush() async {
    await _eventProcessor.flush();
  }

  // Testing

  /// Creates a no-network test client with static flag overrides.
  static FeatureflipClient forTesting(Map<String, dynamic> overrides) {
    return FeatureflipClient._test(overrides);
  }

  /// Returns all current flag values (visible for testing and provider).
  Map<String, FlagValue> allFlags() => _cache.all();

  // Private

  void _startDataSource() {
    if (_config.streaming) {
      _streamingDataSource = StreamingDataSource(
        baseUrl: _config.baseUrl,
        clientKey: _config.clientKey,
        context: _currentContext,
        onChange: _handleStreamUpdate,
        onMaxRetriesReached: _handleStreamingFallback,
      );
      _streamingDataSource!.start();
    } else {
      _startPolling();
    }
  }

  /// Falls back to polling when SSE streaming exhausts retries.
  void _handleStreamingFallback() {
    _streamingDataSource?.stop();
    _streamingDataSource = null;
    _startPolling();
  }

  void _startPolling() {
    _pollingDataSource = PollingDataSource(
      httpClient: _httpClient,
      context: _currentContext,
      interval: Duration(seconds: _config.pollIntervalSeconds),
      onChange: _handleFullUpdate,
    );
    _pollingDataSource!.start();
  }

  /// Handles SSE partial updates — merges into existing cache, handles deletions.
  void _handleStreamUpdate(Map<String, FlagValue> flags) {
    bool changed = false;
    final current = Map.of(_cache.all());

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
      _cache.setAll(current);
      flagProvider.updateFlags();
    }
  }

  /// Handles full flag snapshots from polling/identify — replaces entire cache.
  void _handleFullUpdate(Map<String, FlagValue> flags) {
    final oldFlags = _cache.all();
    if (_mapsEqual(oldFlags, flags)) return;
    _cache.setAll(flags);
    flagProvider.updateFlags();
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
    await _eventProcessor.flush();
  }
}
