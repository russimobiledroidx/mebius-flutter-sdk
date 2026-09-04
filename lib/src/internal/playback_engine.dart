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
import 'package:mebius/src/mebius_delivery.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:video_player/video_player.dart';

/// Internal selector for the playback pipeline.
enum PlaybackPipeline {
  /// WebRTC-based low-latency playback (WHEP).
  lowLatency,

  /// HLS-based scalable playback.
  scale,
}

/// How long one route gets to produce its first frame before the engine moves
/// to the next one.
///
/// Not arbitrary. A route can look healthy and deliver nothing: an edge with no
/// ingest yet answers 200 with an empty stream, and a WebRTC connection reports
/// `connected` while zero frames arrive. 8s survives a slow first segment on
/// mobile data and is short enough that the viewer has not left yet.
const Duration kFirstFrameTimeout = Duration(seconds: 8);

/// One route to attempt, in the order the gateway prefers.
///
/// [path] is null for the WebRTC route, which is signaled rather than fetched
/// and therefore never appears in the gateway's delivery list.
class PlaybackCandidate {
  const PlaybackCandidate(this.pipeline, [this.path]);

  final PlaybackPipeline pipeline;
  final String? path;
}

/// Builds the ordered route list for a playback mode.
///
/// The gateway's own ordering is preserved verbatim — it knows which routes are
/// actually serving and what each costs to serve. The origin playlist is always
/// appended last, both as a guaranteed fallback and because every byte of it is
/// billed to us, unlike an edge route.
///
/// Flutter deliberately does NOT declare the buffered mid-latency route: the
/// platform video player has no support for it, so offering it would be a route
/// that could never play.
List<PlaybackCandidate> buildCandidates(
  PlaybackPipeline preferred,
  List<MebiusDelivery> deliveries,
) {
  final out = <PlaybackCandidate>[];
  if (preferred == PlaybackPipeline.lowLatency) {
    out.add(const PlaybackCandidate(PlaybackPipeline.lowLatency));
  }
  for (final d in deliveries) {
    if (!d.isResolvable) {
      continue;
    }
    // "fast" is skipped: it is the buffered route this platform cannot play.
    if (d.kind == 'wide' || d.kind == 'local') {
      out.add(PlaybackCandidate(PlaybackPipeline.scale, d.path));
    }
  }
  // Origin playlist, addressed without a delivery path.
  out.add(const PlaybackCandidate(PlaybackPipeline.scale));
  return out;
}

/// Video frames the decoder has actually produced, from a `getStats()` snapshot.
///
/// This is the honest answer to "is it playing?". The alternatives all lie: a
/// peer connection reports `connected`, and a video track reports `enabled`,
/// from the moment the session is negotiated — both stay true forever on a route
/// that never sends a single frame.
///
/// `framesReceived` is accepted where `framesDecoded` is missing, because not
/// every platform reports the latter and frames arriving is still proof that
/// media is flowing. Note the `??`: present-and-zero is a real answer and does
/// NOT fall back — media arriving with nothing decoded is exactly the stall we
/// must keep waiting through. A report with neither counter counts as zero: not
/// proven must not read as playing.
///
/// ponytail: `framesReceived` counts frames assembled before decode, so
/// `framesReceived > 0 && framesDecoded == 0` is what a stream missing a
/// keyframe or carrying a codec this device cannot decode looks like — the 0.2.1
/// failure mode, one release ago. Every platform this SDK targets does report
/// `framesDecoded`, so the fallback is near-dead code; drop it if a platform
/// without the counter never shows up.
///
/// Every inbound video report is summed rather than trusting the first: report
/// ordering is unspecified (Android builds it from a hash map), so a session
/// with two video entries could otherwise answer 0 while video was flowing and
/// fail over a route that was working.
///
/// Only inbound video is counted. A monitor publishes and plays on one device,
/// so counting the outbound side would report a frame for a route that received
/// none. `mediaType` is accepted alongside `kind` because matching only the spec
/// field would fail silently on a platform that emits just the legacy alias: no
/// report matches, every real-time route fails over, and nothing says why.
int decodedVideoFrames(List<StatsReport> reports) {
  var total = 0;
  for (final r in reports) {
    if (r.type != 'inbound-rtp') continue;
    final values = r.values;
    if ((values['kind'] ?? values['mediaType']) != 'video') continue;
    final decoded = values['framesDecoded'] ?? values['framesReceived'];
    if (decoded is num) {
      total += decoded.toInt();
    }
  }
  return total;
}

/// Drives inbound playback for a single stream.
class PlaybackEngine {
  PlaybackEngine({required this.signaling, required this.pipeline});

  final GatewaySignaling signaling;
  final PlaybackPipeline pipeline;

  /// Routes supplied by the gateway, in the gateway's preferred order.
  List<MebiusDelivery> deliveries = const <MebiusDelivery>[];

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

  /// Begins playback of [streamId], walking the route list until one delivers.
  ///
  /// A route that opens successfully is not yet a route that plays, so each one
  /// is given [kFirstFrameTimeout] to produce a frame before the next is tried.
  /// Without this, a route that connects and sends nothing leaves the viewer on
  /// a black frame indefinitely — there is no error to react to.
  Future<void> start(String streamId) async {
    if (isPlaying) {
      return;
    }
    Object? lastError;
    for (final candidate in buildCandidates(pipeline, deliveries)) {
      try {
        switch (candidate.pipeline) {
          case PlaybackPipeline.lowLatency:
            await _startLowLatency(streamId);
          case PlaybackPipeline.scale:
            await _startScale(streamId, candidate.path);
        }
        if (await _awaitFirstFrame()) {
          return;
        }
        lastError = const MebiusError(
          MebiusErrorCode.connectionFailed,
          'A Mebius route delivered no video.',
        );
      } on Object catch (e) {
        lastError = e;
      }
      // Release the dead route before opening the next one; leaving a peer
      // connection or a platform player attached leaks it for the whole session.
      await stop();
    }
    throw MebiusError.from(
      lastError ??
          const MebiusError(
            MebiusErrorCode.connectionFailed,
            'No Mebius route could play this stream.',
          ),
    );
  }

  /// Resolves true once the stream is actually rendering, false on timeout.
  ///
  /// Progress of the picture is the signal, not "initialized" or "connected" —
  /// both of those are true on a route that is sending nothing.
  Future<bool> _awaitFirstFrame() async {
    final deadline = DateTime.now().add(kFirstFrameTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _hasFrame()) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // No last look: the loop already polled to within 200ms of the deadline, so
    // another round trip fires after the budget is spent and can only repeat the
    // answer we just had.
    return false;
  }

  Future<bool> _hasFrame() async {
    final controller = _videoController;
    if (controller != null) {
      final v = controller.value;
      return v.isInitialized && v.position > Duration.zero;
    }
    // For the WebRTC route, ask the decoder. A track object is not evidence: it
    // exists from the moment the session is negotiated, so reading it as "a
    // frame arrived" defused the very watchdog that was meant to catch a route
    // which connects and then sends nothing.
    final pc = _pc;
    if (pc == null) {
      return false;
    }
    try {
      return decodedVideoFrames(await pc.getStats()) > 0;
    } on Object catch (_) {
      // flutter_webrtc throws a bare String from native getStats, and iOS throws
      // when the connection has left the plugin registry — which is reachable
      // because stop() is public and can land mid-poll. Left uncaught it becomes
      // the caller's error: MebiusError.from maps a non-MebiusError to
      // MebiusErrorCode.unknown with toString() as the user-facing message, so a
      // stats hiccup leaked an internal libwebrtc string and reported UNKNOWN
      // where CONNECTION_FAILED was the truth. Unavailable stats is not playing.
      return false;
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

  Future<void> _startScale(String streamId, [String? deliveryPath]) async {
    final url = deliveryPath == null
        ? signaling.scalePlaylistUrl(streamId)
        : signaling.deliveryUrl(deliveryPath);
    await signaling.ensureScaleReachable(streamId, url);
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
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
    // dispose() as well as close(): only dispose removes the connection from the
    // plugin's registry. Pre-existing, but this fix is what makes it reachable —
    // the real-time route used to always report success, so failover never ran
    // and no connection was ever abandoned. Now every viewer on a dead route
    // would leak one for the session.
    await _pc?.close();
    await _pc?.dispose();
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
