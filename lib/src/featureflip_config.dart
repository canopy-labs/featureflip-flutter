/// Configuration for the Featureflip client.
class FeatureflipConfig {
  /// Client SDK key from your project settings.
  final String clientKey;

  /// Evaluation API base URL.
  final String baseUrl;

  /// Initial evaluation context (user attributes).
  final Map<String, dynamic> context;

  /// Enable SSE for real-time flag updates.
  final bool streaming;

  /// Polling interval in seconds (used when streaming is disabled).
  final int pollIntervalSeconds;

  /// Interval in seconds between event flush batches.
  final int flushIntervalSeconds;

  /// Maximum number of events per flush batch.
  final int flushBatchSize;

  /// Maximum time in seconds to wait for initial flag fetch.
  final int initTimeoutSeconds;

  const FeatureflipConfig({
    required this.clientKey,
    this.baseUrl = 'https://eval.featureflip.io',
    this.context = const {},
    this.streaming = true,
    this.pollIntervalSeconds = 30,
    this.flushIntervalSeconds = 30,
    this.flushBatchSize = 100,
    this.initTimeoutSeconds = 10,
  });
}
