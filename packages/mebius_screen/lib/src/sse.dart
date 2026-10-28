// Internal: not exported.

import 'dart:math';

/// Splits a Server-Sent Events byte stream, already decoded to text and cut
/// at arbitrary chunk boundaries, into the `data` of each complete message.
///
/// Comment lines (`: ping`) and fields other than `data` are dropped; a
/// message's `data:` lines are joined with `\n` as the spec says.
class SseParser {
  String _buffer = '';
  final List<String> _data = [];

  /// Feeds one chunk; returns the messages it completed, in order.
  List<String> add(String chunk) {
    _buffer += chunk;
    final out = <String>[];
    while (true) {
      final nl = _buffer.indexOf('\n');
      if (nl < 0) {
        break;
      }
      var line = _buffer.substring(0, nl);
      _buffer = _buffer.substring(nl + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) {
        if (_data.isNotEmpty) {
          out.add(_data.join('\n'));
          _data.clear();
        }
      } else if (line.startsWith('data:')) {
        final v = line.substring(5);
        _data.add(v.startsWith(' ') ? v.substring(1) : v);
      }
    }
    return out;
  }
}

/// Reconnect delay before attempt [attempt] (0-based): 1 s doubling to 30 s,
/// minus up to 20 % jitter so a fleet of agents does not reconnect in step
/// after an engine restart.
Duration reconnectDelay(int attempt, Random random) {
  final ms = min(30000, 1000 << min(attempt, 5));
  return Duration(milliseconds: (ms * (1 - 0.2 * random.nextDouble())).round());
}
