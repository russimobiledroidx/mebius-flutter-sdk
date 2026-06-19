// INTERNAL — not part of the public Mebius surface.
//
// Bridges the public player to native pipelines:
//   * low-latency mode -> WebRTC via flutter_webrtc using the WHEP exchange.
//   * scale mode        -> HLS playback via the video_player plugin, fed the
//                          gateway's HLS playlist URL.
// The chosen pipeline is selected automatically from the public `mode` and is
// never surfaced in protocol terms.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:video_player/video_player.dart';

/// Internal selector for the playback pipeline.
enum PlaybackPipeline {
  /// WebRTC-based low-latency playback (WHEP).
  lowLatency,

  /// HLS-based scalable playback.
  scale,
}

/// Drives inbound playback for a single stream.
class PlaybackEngine {
  PlaybackEngine({required this.signaling, required this.pipeline});

  final GatewaySignaling signaling;
  final PlaybackPipeline pipeline;

  // Low-latency (WebRTC) state.
  RTCPeerConnection? _pc;
  MediaStream? _remoteStream;
  String? _resourceUrl;

  // Scale (HLS) state.
  VideoPlayerController? _videoController;

  double _volume = 1;

  bool get isPlaying => _pc != null || _videoController != null;

  /// Remote media stream for low-latency mode (null in scale mode).
  MediaStream? get remoteStream => _remoteStream;

  /// Controller backing scale-mode playback (null in low-latency mode).
  VideoPlayerController? get videoController => _videoController;

  /// Begins playback of [streamId] using the configured pipeline.
  Future<void> start(String streamId) async {
    if (isPlaying) {
      return;
    }
    switch (pipeline) {
      case PlaybackPipeline.lowLatency:
        await _startLowLatency(streamId);
      case PlaybackPipeline.scale:
        await _startScale(streamId);
    }
  }

  Future<void> _startLowLatency(String streamId) async {
    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
      }
    };

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final result = await signaling.playOffer(streamId, offer.sdp ?? '');
    _resourceUrl = result.resourceUrl;
    await pc.setRemoteDescription(
      RTCSessionDescription(result.answerSdp, 'answer'),
    );
  }

  Future<void> _startScale(String streamId) async {
    await signaling.ensureScaleReachable(streamId);
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(signaling.scalePlaylistUrl(streamId)),
    );
    _videoController = controller;
    try {
      await controller.initialize();
    } catch (e) {
      _videoController = null;
      await controller.dispose();
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Playback could not be started for this stream.',
        cause: e,
      );
    }
    await controller.setVolume(_volume);
    await controller.play();
  }

  /// Stops playback and releases resources.
  Future<void> stop() async {
    final resource = _resourceUrl;
    _resourceUrl = null;
    if (resource != null) {
      await signaling.deleteResource(resource);
    }
    await _pc?.close();
    _pc = null;
    _remoteStream = null;

    final controller = _videoController;
    _videoController = null;
    if (controller != null) {
      await controller.pause();
      await controller.dispose();
    }
  }

  /// Sets the playback volume in the range 0..1.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _videoController?.setVolume(_volume);
    for (final track in _remoteStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _volume > 0;
    }
  }

  /// Collects a lightweight stats snapshot from the active session.
  Future<Map<String, num>> readStats() async {
    final pc = _pc;
    if (pc != null) {
      var bitrate = 0.0;
      var fps = 0.0;
      final reports = await pc.getStats();
      for (final r in reports) {
        if (r.type == 'inbound-rtp') {
          final values = r.values;
          fps = (values['framesPerSecond'] as num?)?.toDouble() ?? fps;
          final bytes = (values['bytesReceived'] as num?)?.toDouble() ?? 0;
          bitrate = bytes * 8 / 1000;
        }
      }
      return {'bitrate': bitrate, 'fps': fps, 'buffered': 0};
    }
    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      var buffered = 0;
      if (controller.value.buffered.isNotEmpty) {
        buffered = controller.value.buffered.last.end.inMilliseconds -
            controller.value.position.inMilliseconds;
      }
      return {'bitrate': 0, 'fps': 0, 'buffered': buffered};
    }
    return const {};
  }
}
