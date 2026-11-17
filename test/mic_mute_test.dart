import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';

import 'support/webrtc_fakes.dart';

/// The mic is muted at the audio device module, never by disabling the track:
/// a disabled track stops libwebrtc's recorder, the publish goes audio-less and
/// web (FLV/MSE) viewers stall until unmute.
class _AudioTrack extends FakeTrack {
  @override
  String? get kind => 'audio';
  @override
  bool enabled = true;
}

class _AvStream extends FakeStream {
  _AvStream(this.audio) : super([audio]);
  final _AudioTrack audio;
  @override
  List<MediaStreamTrack> getAudioTracks() => [audio];
}

void main() {
  late List<String> log;
  late _AudioTrack track;
  late bool admFails;

  BroadcastEngine engine() => BroadcastEngine(
        signaling: RecordingSignaling().signaling,
        video: false,
        audio: true,
        source: () async => _AvStream(track),
        disposeSourceOnStop: false,
        openPeerConnection: (_) async {
          log.add('pc');
          return FakePeerConnection();
        },
        muteMicrophone: ({required muted}) async {
          if (admFails) throw Exception('no ADM');
          log.add('adm muted=$muted');
        },
      );

  setUp(() {
    log = [];
    track = _AudioTrack();
    admFails = false;
  });

  test('mute goes to the ADM and leaves the track enabled', () async {
    final e = engine();
    await e.start('s');
    e.setMicEnabled(enabled: false);
    await pumpEventQueue();
    expect(log.last, 'adm muted=true');
    expect(track.enabled, isTrue, reason: 'a disabled track stops the recorder');
    e.setMicEnabled(enabled: true);
    await pumpEventQueue();
    expect(log.last, 'adm muted=false');
    await e.stop();
  });

  test('a mute set before start is applied before the peer connection opens',
      () async {
    final e = engine()..setMicEnabled(enabled: false);
    await pumpEventQueue();
    log.clear();
    await e.start('s');
    expect(log.take(2), ['adm muted=true', 'pc']);
    await e.stop();
  });

  test('stop releases the process-wide mute; a restart mutes again', () async {
    final e = engine();
    await e.start('s');
    e.setMicEnabled(enabled: false);
    await pumpEventQueue();
    await e.stop();
    expect(log.last, 'adm muted=false');
    log.clear();
    await e.start('s');
    expect(log.first, 'adm muted=true', reason: 'the host is still muted');
    await e.stop();
  });

  test('a never-muted broadcast does not touch the ADM', () async {
    final e = engine();
    await e.start('s');
    await e.stop();
    expect(log.where((l) => l.startsWith('adm')), isEmpty);
  });

  test('without an ADM mute it falls back to the track toggle', () async {
    admFails = true;
    final e = engine();
    await e.start('s');
    e.setMicEnabled(enabled: false);
    await pumpEventQueue();
    expect(track.enabled, isFalse);
    await e.stop();
  });
}
