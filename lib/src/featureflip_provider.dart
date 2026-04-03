import 'package:flutter/widgets.dart';

import 'featureflip_client.dart';

/// A [ChangeNotifier] that exposes feature flag values for Flutter widgets.
///
/// Wrap your app in a [ListenableBuilder] or use with [ChangeNotifierProvider]
/// to reactively rebuild when flag values change.
class FeatureflipProvider extends ChangeNotifier {
  final FeatureflipClient _client;

  FeatureflipProvider(this._client);

  /// Returns a boolean flag value, or the default if missing or wrong type.
  bool boolVariation(String key, {required bool defaultValue}) {
    return _client.boolVariation(key, defaultValue: defaultValue);
  }

  /// Returns a string flag value, or the default if missing or wrong type.
  String stringVariation(String key, {required String defaultValue}) {
    return _client.stringVariation(key, defaultValue: defaultValue);
  }

  /// Returns a numeric flag value, or the default if missing or wrong type.
  double numberVariation(String key, {required double defaultValue}) {
    return _client.numberVariation(key, defaultValue: defaultValue);
  }

  /// Returns the raw flag value, or the default if missing.
  dynamic jsonVariation(String key, {required dynamic defaultValue}) {
    return _client.jsonVariation(key, defaultValue: defaultValue);
  }

  /// Notifies listeners that flag values have changed.
  void updateFlags() {
    notifyListeners();
  }
}
