// INTERNAL — not part of the public Mebius surface.
//
// Bridges the public broadcaster to native WebRTC via flutter_webrtc and
// publishes the local media using the WHIP exchange against the gateway.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_error.dart';

/// Drives camera/mic capture and the WHIP publish session.
class BroadcastEngine {
  BroadcastEngine({
    required this.signaling,
    required this.video,
    required this.audio,
  });

  final GatewaySignaling signaling;
  final bool video;
  final bool audio;

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
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '360',
                  'minFrameRate': '24',
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

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final result = await signaling.publishOffer(streamId, offer.sdp ?? '');
    _resourceUrl = result.resourceUrl;
    await pc.setRemoteDescription(
      RTCSessionDescription(result.answerSdp, 'answer'),
    );
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
