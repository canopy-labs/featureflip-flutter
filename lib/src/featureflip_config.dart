import 'models.dart';

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

  /// In-process observers fired on every variation call. Honored on the first
  /// `get()` per client key, like every other option.
  final List<EvaluationInspector> inspectors;

  /// Report the flags this app reads, so Featureflip can tell which flags
  /// deployed code still uses. On by default.
  ///
  /// When on, the first read of each flag (per variation and `user_id`) in an
  /// hour queues one `Evaluation` event, and `/v1/client/evaluate` and
  /// `/v1/client/identify` requests declare it with
  /// `X-Featureflip-Reports-Evaluations: 1`. When off, neither happens, and the
  /// server counts every flag it sends to this device as read. Honored on the
  /// first `get()` per client key, like every other option.
  final bool sendEvaluationEvents;

  /// Name of a library that wraps this SDK (a design-system shell, an internal
  /// platform client). Sent after the SDK's own token in the User-Agent and
  /// X-Featureflip-SDK headers (`featureflip-flutter/<version> my-wrapper/1.0.0`)
  /// so usage through the wrapper can be counted. Must be a valid HTTP product
  /// token; an invalid one is ignored with a diagnostic. Leave unset when calling
  /// the SDK directly. Not part of the different-config check: it identifies the
  /// caller rather than changing behavior.
  final String? wrapperName;

  /// Version of the wrapper named by [wrapperName]. Optional.
  final String? wrapperVersion;

  const FeatureflipConfig({
    required this.clientKey,
    this.baseUrl = 'https://eval.featureflip.io',
    this.context = const {},
    this.streaming = true,
    this.pollIntervalSeconds = 30,
    this.flushIntervalSeconds = 30,
    this.flushBatchSize = 100,
    this.initTimeoutSeconds = 10,
    this.inspectors = const [],
    this.sendEvaluationEvents = true,
    this.wrapperName,
    this.wrapperVersion,
  });
}
