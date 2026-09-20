// INTERNAL — not part of the public Mebius surface.
//
// Bridges the public broadcaster to native WebRTC via flutter_webrtc and
// publishes the local media using the WHIP exchange against the gateway.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_error.dart';

/// Ceiling on what a publisher's video encoder may send, in kbps.
///
/// 3500 matches what the studio's OBS encoder is configured to send, so a
/// broadcast costs the same whichever path it came from — a host on a phone and a
/// host in the studio bill identically.
///
/// It is a ceiling, not a target: WebRTC still spends less on still scenes. What
/// it removes is the open end, where a capable device answered high-motion content
/// with whatever it could encode.
///
/// Every Mebius SDK carries this same number. Changing it in one place without the
/// others makes the cost of a broadcast depend on which phone made it.
const int kDefaultMaxBitrateKbps = 3500;

/// Drives camera/mic capture and the WHIP publish session.
class BroadcastEngine {
  BroadcastEngine({
    required this.signaling,
    required this.video,
    required this.audio,
    this.maxBitrateKbps = kDefaultMaxBitrateKbps,
  });

  final GatewaySignaling signaling;
  final bool video;
  final bool audio;

  /// Ceiling on what the encoder may send, in kbps. Zero or null lifts it and
  /// leaves the choice to WebRTC.
  final int? maxBitrateKbps;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _resourceUrl;
  bool _usingFrontCamera = true;

  /// The renderer-facing local stream, available after [start].
  MediaStream? get localStream => _localStream;

  bool get isRunning => _pc != null;

  /// Captures local media and publishes [streamId] to the gateway.
  Future<void> start(String streamId) async {
    if (_pc != null) {
      return;
    }
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': video
            ? {
                'facingMode': 'user',
                // Minimums AND maximums. With only the minimums these were, a
                // capable phone was free to hand back 1080p60 — which is a
                // licence to spend, not a floor to meet, and it is delivery
                // bandwidth that pays for it. 720p30 matches what the Android
                // and iOS SDKs capture, so the same broadcast costs the same
                // whichever device it came from.
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '360',
                  'minFrameRate': '24',
                  'maxWidth': '1280',
                  'maxHeight': '720',
                  'maxFrameRate': '30',
                },
              }
            : false,
      });
    } catch (e) {
      throw MebiusError(
        MebiusErrorCode.permissionDenied,
        'Camera and/or microphone access was denied.',
        cause: e,
      );
    }

    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    await preferH264(pc);
    await _applyBitrateCap(pc);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final result = await signaling.publishOffer(streamId, offer.sdp ?? '');
    _resourceUrl = result.resourceUrl;
    await pc.setRemoteDescription(
      RTCSessionDescription(result.answerSdp, 'answer'),
    );
  }

  /// Caps what the video encoder may send.
  ///
  /// Capture constraints alone do not do this. They bound the SOURCE — how many
  /// pixels arrive per second — while the encoder still chooses how many bits to
  /// spend describing them, and high-motion content (sport, above all) makes it
  /// spend near the top of its range. The only place the ceiling is real is the
  /// sender's own encoding parameters.
  ///
  /// Why it matters beyond the device: there is no transcoding anywhere in the
  /// path, so every viewer is delivered at exactly the bitrate published here.
  /// One publisher's setting is multiplied by the size of its audience.
  ///
  /// Best-effort by design. A platform that does not implement setParameters
  /// leaves the stream uncapped rather than failing to go live — an unbudgeted
  /// broadcast beats no broadcast, and the caller learns from the stats either
  /// way.
  Future<void> _applyBitrateCap(RTCPeerConnection pc) async {
    final kbps = maxBitrateKbps;
    if (kbps == null || kbps <= 0) {
      return;
    }
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') {
          continue;
        }
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) {
          params.encodings = [RTCRtpEncoding(maxBitrate: kbps * 1000)];
        } else {
          for (final e in encodings) {
            e.maxBitrate = kbps * 1000;
          }
        }
        await sender.setParameters(params);
      }
    } on Object catch (_) {
      // See the note above: an uncapped publish is worse than a capped one, and
      // better than a failed one.
    }
  }

  /// Stops publishing and releases capture resources.
  Future<void> stop() async {
    final resource = _resourceUrl;
    _resourceUrl = null;
    if (resource != null) {
      await signaling.deleteResource(resource);
    }
    await _pc?.close();
    _pc = null;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    _localStream = null;
  }

  /// Flips between the front- and rear-facing cameras.
  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      return;
    }
    await Helper.switchCamera(videoTracks.first);
    _usingFrontCamera = !_usingFrontCamera;
  }

  /// Enables or disables the outgoing microphone track.
  void setMicEnabled({required bool enabled}) {
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  /// Enables or disables the outgoing camera track.
  void setCameraEnabled({required bool enabled}) {
    for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  /// Collects a lightweight stats snapshot from the active session.
  Future<Map<String, num>> readStats() async {
    final pc = _pc;
    if (pc == null) {
      return const {};
    }
    var bitrate = 0.0;
    var fps = 0.0;
    var packets = 0;
    final reports = await pc.getStats();
    for (final r in reports) {
      if (r.type == 'outbound-rtp') {
        final values = r.values;
        fps = (values['framesPerSecond'] as num?)?.toDouble() ?? fps;
        packets = (values['packetsSent'] as num?)?.toInt() ?? packets;
        final bytes = (values['bytesSent'] as num?)?.toDouble() ?? 0;
        bitrate = bytes * 8 / 1000;
      }
    }
    return {'bitrate': bitrate, 'fps': fps, 'packets': packets};
  }
}

/// Offers H264 ahead of VP8 for the outgoing video track.
///
/// libwebrtc negotiates VP8 by default, and VP8 is a dead end for every viewer
/// who is not on the real-time route: the gateway's segment-based deliveries
/// cannot carry it, so they drop the video track and the broadcast arrives as
/// audio only. The device shows a healthy preview and bitrate throughout, which
/// is what makes this worth doing here rather than diagnosing it per report.
///
/// VP8 stays in the list as the fallback — a device with no H264 encoder must
/// still be able to broadcast.
///
/// Best-effort: any failure leaves negotiation exactly as it was before.
Future<void> preferH264(RTCPeerConnection pc) async {
  try {
    final transceivers = await pc.getTransceivers();
    for (final t in transceivers) {
      if (t.sender.track?.kind != 'video') continue;
      await t.setCodecPreferences(h264FirstCodecs);
    }
  } on Object catch (_) {
    // Older plugin versions and platforms without the method call: the
    // broadcast still goes out, just with the previous codec order.
  }
}

/// Codec preference list applied to the publishing video transceiver.
final List<RTCRtpCodecCapability> h264FirstCodecs = <RTCRtpCodecCapability>[
  RTCRtpCodecCapability(mimeType: 'video/H264', clockRate: 90000),
  RTCRtpCodecCapability(mimeType: 'video/VP8', clockRate: 90000),
];
