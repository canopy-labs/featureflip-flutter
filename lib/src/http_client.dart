import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// HTTP client for evaluation API requests.
class FeatureflipHttpClient {
  /// Sent on evaluate and identify when this client reports the flags the app
  /// reads to `/v1/client/events`. The server then stops recording an evaluation
  /// for every flag it serves on the client's behalf. Only the value `1` counts.
  static const reportsEvaluationsHeader = 'X-Featureflip-Reports-Evaluations';

  final String baseUrl;
  final String clientKey;

  /// Whether requests declare [reportsEvaluationsHeader]. The core keeps a read
  /// recorder exactly when this is true, so the two can never disagree. Defaults
  /// to false, the safe side: the server then records every served flag.
  final bool reportsEvaluations;

  final http.Client _client;

  FeatureflipHttpClient({
    required this.baseUrl,
    required this.clientKey,
    http.Client? client,
    this.reportsEvaluations = false,
  }) : _client = client ?? http.Client();

  /// Fetches evaluated flags from /v1/client/evaluate.
  Future<EvaluateResponse> evaluate(
    Map<String, dynamic> context, {
    Duration? timeout,
  }) async {
    return _post('/v1/client/evaluate', {'context': context}, timeout: timeout);
  }

  /// Re-evaluates flags with new context via /v1/client/identify.
  Future<EvaluateResponse> identify(
    Map<String, dynamic> context, {
    String? connectionId,
  }) async {
    return _post(
      '/v1/client/identify',
      {'context': context},
      extraHeaders: connectionId != null ? {'X-Connection-Id': connectionId} : null,
    );
  }

  /// Posts analytics events to /v1/client/events.
  ///
  /// The CLIENT surface, like every other call this SDK makes. /v1/sdk/events accepts server
  /// keys only, so it answered this one with a 401 — which the event processor classifies as
  /// permanent, discarding every batch (#3069).
  Future<void> postEvents(List<SdkEvent> events) async {
    final body = jsonEncode({'events': events.map((e) => e.toJson()).toList()});
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/client/events'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': clientKey,
      },
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FeatureflipHttpException(response.statusCode);
    }
  }

  void close() {
    _client.close();
  }

  Future<EvaluateResponse> _post(
    String path,
    Map<String, dynamic> requestBody, {
    Duration? timeout,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final body = jsonEncode(requestBody);
    var future = _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': clientKey,
        if (extraHeaders != null) ...extraHeaders,
        // Only evaluate and identify (and polling, which calls evaluate) come
        // through _post, and they are exactly the calls the server would otherwise
        // credit with every flag they serve. postEvents and the SSE stream build
        // their own requests and never send it.
        if (reportsEvaluations) reportsEvaluationsHeader: '1',
      },
      body: body,
    );
    if (timeout != null) {
      future = future.timeout(timeout);
    }
    final response = await future;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FeatureflipHttpException(response.statusCode);
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return EvaluateResponse.fromJson(json);
  }
}

class FeatureflipHttpException implements Exception {
  final int statusCode;
  const FeatureflipHttpException(this.statusCode);

  @override
  String toString() => 'FeatureflipHttpException: HTTP $statusCode';
}
