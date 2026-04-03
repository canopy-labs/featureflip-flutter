import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// HTTP client for evaluation API requests.
class FeatureflipHttpClient {
  final String baseUrl;
  final String clientKey;
  final http.Client _client;

  FeatureflipHttpClient({
    required this.baseUrl,
    required this.clientKey,
    http.Client? client,
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

  /// Posts analytics events to /v1/sdk/events.
  Future<void> postEvents(List<SdkEvent> events) async {
    final body = jsonEncode({'events': events.map((e) => e.toJson()).toList()});
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/sdk/events'),
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
