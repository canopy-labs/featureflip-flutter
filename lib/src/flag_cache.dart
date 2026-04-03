import 'models.dart';

/// In-memory flag cache.
class FlagCache {
  Map<String, FlagValue> _flags = {};

  /// Replaces all cached flags.
  void setAll(Map<String, FlagValue> flags) {
    _flags = Map.of(flags);
  }

  /// Returns a single flag value, or null if missing.
  FlagValue? get(String key) => _flags[key];

  /// Returns all cached flags.
  Map<String, FlagValue> all() => Map.unmodifiable(_flags);
}
