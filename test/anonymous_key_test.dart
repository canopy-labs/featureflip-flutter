import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:featureflip/src/anonymous_key_store.dart';

/// In-memory [AnonymousKeyStore] for the pure resolver tests.
class _MemoryStore implements AnonymousKeyStore {
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String value) async => _v = value;
}

void main() {
  group('resolveAnonymousContext', () {
    test('injects and persists an anonymous user_id', () async {
      final store = _MemoryStore();
      final first = await resolveAnonymousContext({'plan': 'pro'}, store);
      expect(first['user_id'], isA<String>());
      expect((first['user_id'] as String).isNotEmpty, isTrue);
      expect(first['plan'], 'pro');

      // Second call reads the SAME persisted key.
      final second = await resolveAnonymousContext({'plan': 'pro'}, store);
      expect(second['user_id'], first['user_id']);
    });

    test('real user_id wins', () async {
      final store = _MemoryStore();
      final out = await resolveAnonymousContext({'user_id': 'real-1'}, store);
      expect(out['user_id'], 'real-1');
      expect(await store.read(), isNull); // never generated
    });

    test('camelCase userId alias wins', () async {
      final store = _MemoryStore();
      final out = await resolveAnonymousContext({'userId': 'alice'}, store);
      expect(out, {'userId': 'alice'});
      expect(await store.read(), isNull);
    });

    test('blank user_id treated as anonymous', () async {
      final store = _MemoryStore();
      final out = await resolveAnonymousContext({'user_id': '   '}, store);
      expect((out['user_id'] as String).trim().isNotEmpty, isTrue);
      expect(out['user_id'], isNot('   '));
    });
  });

  group('SharedPreferencesAnonymousKeyStore', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('persists the key across store instances (same backing prefs)', () async {
      final store1 = SharedPreferencesAnonymousKeyStore();
      expect(await store1.read(), isNull);

      final ctx = await resolveAnonymousContext({}, store1);
      final id = ctx['user_id'] as String;
      expect(id.isNotEmpty, isTrue);

      // A fresh store instance (simulated restart) reads the same persisted key.
      final store2 = SharedPreferencesAnonymousKeyStore();
      expect(await store2.read(), id);
    });
  });
}
