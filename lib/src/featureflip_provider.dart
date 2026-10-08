import 'package:flutter/widgets.dart';

import 'flag_cache.dart';
import 'models.dart';

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
  final void Function(String key, FlagValue? flag)? _onRead;

  /// [onRead] is called once per variation call with the key read and the
  /// cached flag (null when absent). The client uses it to report reads made
  /// from widgets, which never pass through the client's own variation methods.
  FeatureflipProvider(this._cache, {void Function(String key, FlagValue? flag)? onRead})
      : _onRead = onRead;

  /// Returns a boolean flag value, or the default if missing or wrong type.
  bool boolVariation(String key, {required bool defaultValue}) {
    final flag = _read(key);
    if (flag == null || flag.value is! bool) return defaultValue;
    return flag.value as bool;
  }

  /// Returns a string flag value, or the default if missing or wrong type.
  String stringVariation(String key, {required String defaultValue}) {
    final flag = _read(key);
    if (flag == null || flag.value is! String) return defaultValue;
    return flag.value as String;
  }

  /// Returns a numeric flag value, or the default if missing or wrong type.
  double numberVariation(String key, {required double defaultValue}) {
    final flag = _read(key);
    if (flag == null) return defaultValue;
    final value = flag.value;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return defaultValue;
  }

  /// Returns the raw flag value, or the default if missing.
  dynamic jsonVariation(String key, {required dynamic defaultValue}) {
    final flag = _read(key);
    if (flag == null) return defaultValue;
    return flag.value;
  }

  /// Notifies listeners that flag values have changed.
  void updateFlags() {
    notifyListeners();
  }

  FlagValue? _read(String key) {
    final flag = _cache.get(key);
    _onRead?.call(key, flag);
    return flag;
  }
}
