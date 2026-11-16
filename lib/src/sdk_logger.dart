import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Strips the SDK key out of everything the SDK logs.
///
/// Failure paths report the underlying error verbatim, because a silent init
/// failure is worse than a noisy one (#2290). But that error can come from an
/// HTTP stack the SDK does not control, and the key travels in request headers
/// and `/v1/client/*` URLs: an error that quotes either would hand the
/// credential to whatever the host app ships its logs to (#5167).
///
/// Every SDK log line goes through one instance per client, so the default
/// `debugPrint` sink is covered and so is any line added later. The global
/// `debugPrint` is left alone: it belongs to the host app.
///
/// Internal, not part of the public API.
class SdkLogger {
  static const _replacement = '[redacted]';

  /// Below this the value is not treated as a credential. A real key is always
  /// 54 characters; redacting a short value corrupts every line it appears in.
  static const minRedactableLength = 20;

  final String _secret;

  const SdkLogger(this._secret);

  /// A logger with nothing to redact.
  const SdkLogger.none() : _secret = '';

  /// [message] with the key replaced. Interpolate errors into [message]; their
  /// `toString()` is redacted along with the rest.
  String redact(String message) => _secret.length >= minRedactableLength
      ? message.replaceAll(_secret, _replacement)
      : message;

  /// What to rethrow to the caller in place of [error]: [error] itself when its
  /// message is clean, a same-type copy for `http.ClientException` (the one
  /// type a third-party HTTP stack can put the key into, and the one callers
  /// catch), else a [RedactedException]. [TimeoutException] and
  /// [FeatureflipHttpException] carry no request text, so they stay as they are.
  Object redactError(Object error) {
    final text = error.toString();
    if (redact(text) == text) return error;
    if (error is http.ClientException) {
      Uri? uri;
      try {
        final raw = error.uri;
        uri = raw == null ? null : Uri.parse(redact(raw.toString()));
      } on FormatException {
        uri = null;
      }
      return http.ClientException(redact(error.message), uri);
    }
    return RedactedException(redact(text));
  }

  void log(String message) => debugPrint(redact(message));
}

/// Stands in for an error whose message quoted the SDK key. Internal; callers
/// see an ordinary [Exception] with the key removed.
class RedactedException implements Exception {
  final String message;
  const RedactedException(this.message);

  @override
  String toString() => message;
}
