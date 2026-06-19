import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const _storageKey = 'featureflip.anonymous_id';

/// Persistence seam for the generated anonymous user id. Injectable so tests can
/// supply an in-memory implementation instead of `shared_preferences`.
abstract class AnonymousKeyStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// `shared_preferences`-backed store (default for production clients).
class SharedPreferencesAnonymousKeyStore implements AnonymousKeyStore {
  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_storageKey);
  }

  @override
  Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, value);
  }
}

String _generateKey() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

bool _isNonBlank(Object? value) => value is String && value.trim().isNotEmpty;

/// Returns a context guaranteed to carry a non-blank `user_id`. A real caller id
/// (either the canonical `user_id` or its accepted `userId` alias, mirroring the
/// engine's ClientContextMapper) is returned unchanged so a real user always
/// wins. Otherwise a persisted anonymous id is read — or generated and persisted
/// once — and injected under `user_id`, giving anonymous users sticky
/// percentage-rollout bucketing.
Future<Map<String, dynamic>> resolveAnonymousContext(
  Map<String, dynamic> context,
  AnonymousKeyStore store,
) async {
  if (_isNonBlank(context['user_id']) || _isNonBlank(context['userId'])) {
    return context;
  }
  var key = await store.read();
  if (key == null || key.trim().isEmpty) {
    key = _generateKey();
    await store.write(key);
  }
  return {...context, 'user_id': key};
}
