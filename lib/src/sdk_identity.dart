import 'package:flutter/foundation.dart';

/// The SDK's version, reported in every request (#4143, contract in #4138).
///
/// Dart cannot read pubspec.yaml at runtime, so this is a constant.
/// publish-flutter-sdk.yml rewrites it from the release tag alongside pubspec.yaml,
/// and test/sdk_identity_test.dart holds the two equal between releases, so it
/// cannot drift the way literals in four other SDKs did (#2141).
const sdkVersion = '2.8.0';

// RFC 9110 product token: tchars.
final _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

/// `featureflip-flutter/<version>`, then the wrapper's token when one is set. A
/// wrapper that is not a valid product token is dropped with a diagnostic rather
/// than thrown: identity metadata must never stop the client starting.
String buildIdentity({String? wrapperName, String? wrapperVersion}) {
  const sdk = 'featureflip-flutter/$sdkVersion';
  if (wrapperName == null || wrapperName.isEmpty) return sdk;
  final valid = _token.hasMatch(wrapperName) && (wrapperVersion == null || _token.hasMatch(wrapperVersion));
  if (!valid) {
    debugPrint('[featureflip] ignoring wrapper "$wrapperName/$wrapperVersion": '
        'not a valid User-Agent product token');
    return sdk;
  }
  return wrapperVersion == null ? '$sdk $wrapperName' : '$sdk $wrapperName/$wrapperVersion';
}

/// The headers that carry [identity]. User-Agent is honoured on native platforms,
/// but a browser refuses it from a script and logs an error for every attempt, so
/// on the web only X-Featureflip-SDK is sent. The Evaluation API reads that one
/// first.
Map<String, String> identityHeaders(String identity) => {
      if (!kIsWeb) 'User-Agent': identity,
      'X-Featureflip-SDK': identity,
    };
