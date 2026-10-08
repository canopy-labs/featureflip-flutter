import 'package:flutter_test/flutter_test.dart';
import 'package:featureflip/src/models.dart';
import 'package:featureflip/src/read_recorder.dart';

void main() {
  late List<SdkEvent> sent;
  late int nowMs;
  late ReadRecorder recorder;

  const hourMs = 60 * 60 * 1000;

  setUp(() {
    sent = <SdkEvent>[];
    nowMs = 0;
    recorder = ReadRecorder(sink: sent.add, nowMs: () => nowMs);
  });

  List<List<String?>> summary() =>
      sent.map((e) => [e.flagKey, e.variation, e.userId]).toList();

  test('the window is a fixed hour', () {
    // Rollups are hourly and the archive guard looks back 24 h, so re-reporting
    // hourly loses nothing. Tying this to the flush interval would send one event
    // per flag per 30 s for the life of a session.
    expect(ReadRecorder.window, const Duration(hours: 1));
  });

  test('the first read queues one Evaluation event with the read details', () {
    recorder.record('flag-a', 'on', 'user-1');

    expect(sent, hasLength(1));
    final json = sent.single.toJson();
    expect(json['type'], 'Evaluation');
    expect(json['flagKey'], 'flag-a');
    expect(json['variation'], 'on');
    expect(json['userId'], 'user-1');
    expect(DateTime.parse(json['timestamp'] as String).isUtc, isTrue);
  });

  test('repeat reads inside the hour never reach the sink', () {
    recorder.record('flag-a', 'on', 'user-1');
    for (var i = 0; i < 1000; i++) {
      nowMs += 3000; // 1000 reads spread over 50 minutes
      recorder.record('flag-a', 'on', 'user-1');
    }
    expect(sent, hasLength(1));
  });

  test('the first read once the hour has elapsed starts a new window', () {
    recorder.record('flag-a', 'on', 'user-1');
    nowMs = hourMs - 1;
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(1));

    nowMs = hourMs; // exactly one window after the recorder started
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(2));

    // The new window started at that read, so a repeat right after is dropped again.
    nowMs = hourMs + 1000;
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(2));

    // And it ends one hour after it started, not one hour after the recorder did.
    nowMs = 2 * hourMs;
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(3));
  });

  test('a different variation, user or flag is its own event', () {
    recorder.record('flag-a', 'on', 'user-1');
    recorder.record('flag-a', 'off', 'user-1');
    recorder.record('flag-a', 'on', 'user-2');
    recorder.record('flag-b', 'on', 'user-1');
    recorder.record('flag-a', 'on', 'user-1'); // repeat of the first
    recorder.record('flag-a', 'off', 'user-1'); // repeat of the second

    expect(summary(), [
      ['flag-a', 'on', 'user-1'],
      ['flag-a', 'off', 'user-1'],
      ['flag-a', 'on', 'user-2'],
      ['flag-b', 'on', 'user-1'],
    ]);
  });

  test('a read of an absent flag is recorded once, with no variation', () {
    recorder.record('missing', null, 'user-1');
    recorder.record('missing', null, 'user-1');

    expect(sent, hasLength(1));
    final json = sent.single.toJson();
    expect(json['flagKey'], 'missing');
    expect(json.containsKey('variation'), isFalse);
  });

  test('a read with no user id is recorded once, without one', () {
    recorder.record('flag-a', 'on', null);
    recorder.record('flag-a', 'on', null);

    expect(sent, hasLength(1));
    expect(sent.single.toJson().containsKey('userId'), isFalse);
  });

  test('resetWindow() re-reports the next read without the clock advancing', () {
    // Stopwatch does not advance while a phone sleeps; the client calls this on
    // resume so a read after a long sleep is reported again.
    recorder.record('flag-a', 'on', 'user-1');
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(1));

    recorder.resetWindow(); // nowMs deliberately unchanged
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(2));

    // And it starts a full window from now: a repeat is dropped again.
    recorder.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(2));
  });

  test('the default clock is monotonic and needs no injection', () {
    final real = ReadRecorder(sink: sent.add);
    real.record('flag-a', 'on', 'user-1');
    real.record('flag-a', 'on', 'user-1');
    expect(sent, hasLength(1));
  });
}
