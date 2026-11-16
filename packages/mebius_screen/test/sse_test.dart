import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mebius_screen/src/sse.dart';

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  group('SseParser', () {
    test('yields the data of each message and drops pings', () {
      final p = SseParser();
      expect(
        p.add(': ping\n\ndata: {"a":1}\n\n: ping\n\ndata: {"b":2}\n\n'),
        ['{"a":1}', '{"b":2}'],
      );
    });

    test('reassembles messages cut at any chunk boundary', () {
      const stream = 'data: {"type":"session.start"}\n\n: ping\n\ndata: x\n\n';
      for (var cut = 1; cut < stream.length; cut++) {
        final p = SseParser();
        final out = [
          ...p.add(stream.substring(0, cut)),
          ...p.add(stream.substring(cut)),
        ];
        expect(out, ['{"type":"session.start"}', 'x'], reason: 'cut at $cut');
      }
    });

    test('handles CRLF, multi-line data and other fields', () {
      final p = SseParser();
      expect(
        p.add('event: x\r\nid: 1\r\ndata: a\r\ndata:b\r\n\r\n'),
        ['a\nb'],
      );
    });

    test('holds an unterminated message until its blank line', () {
      final p = SseParser();
      expect(p.add('data: a\n'), isEmpty);
      expect(p.add('\n'), ['a']);
    });
  });

  group('reconnectDelay', () {
    test('doubles from 1 s and caps at 30 s', () {
      final none = _FixedRandom(0);
      expect(
        [for (var i = 0; i < 8; i++) reconnectDelay(i, none).inSeconds],
        [1, 2, 4, 8, 16, 30, 30, 30],
      );
    });

    test('jitters down by at most 20 %', () {
      expect(reconnectDelay(0, _FixedRandom(1)).inMilliseconds, 800);
      expect(reconnectDelay(9, _FixedRandom(0.5)).inMilliseconds, 27000);
      final r = Random(1);
      for (var i = 0; i < 100; i++) {
        final ms = reconnectDelay(10, r).inMilliseconds;
        expect(ms, inInclusiveRange(24000, 30000));
      }
    });
  });
}
