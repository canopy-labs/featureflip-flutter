import 'package:flutter/widgets.dart';

import 'flag_cache.dart';

/// A [ChangeNotifier] that exposes feature flag values for Flutter widgets.
///
/// Wrap your app in a [ListenableBuilder] or use with [ChangeNotifierProvider]
/// to reactively rebuild when flag values change.
///
/// The provider is shared across all [FeatureflipClient] handles that use the
/// same SDK key, so widget rebuilds are triggered regardless of which handle
/// caused the flag change.
class FeatureflipProvider extends ChangeNotifier {
  final FlagCache _cache;

  FeatureflipProvider(this._cache);

  /// Returns a boolean flag value, or the default if missing or wrong type.
  bool boolVariation(String key, {required bool defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null || flag.value is! bool) return defaultValue;
    return flag.value as bool;
  }

  /// Returns a string flag value, or the default if missing or wrong type.
  String stringVariation(String key, {required String defaultValue}) {
    final flag = _cache.get(key);
    if (flag == null || flag.value is! String) return defaultValue;
    return flag.value as String;
  }

  /// Returns a numeric flag value, or the default if missing or wrong type.
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

  /// Notifies listeners that flag values have changed.
  void updateFlags() {
    notifyListeners();
  }
}
