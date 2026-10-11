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

import 'package:flutter/foundation.dart';
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
  const PlaybackCandidate(this.pipeline, [this.path, this.qualityId])
      : flv = false;

  /// The `fast` route at [path], played as HTTP-FLV.
  const PlaybackCandidate.flv(this.path, [this.qualityId])
      : pipeline = PlaybackPipeline.scale,
        flv = true;

  final PlaybackPipeline pipeline;
  final String? path;

  /// The rendition this route opens, or null when it is not one fixed rung
  /// (source quality, or a master playlist the platform player adapts over).
  final String? qualityId;

  /// The buffered `fast` route: HTTP-FLV, one long-lived response rather than
  /// a playlist. Played as a progressive stream, never with an HLS hint.
  final bool flv;
}

/// Whether this platform's video player can play the buffered `fast` route.
///
/// Android's player (ExoPlayer/media3) ships an FLV extractor and plays a
/// live HTTP-FLV response as a progressive stream — the same route the web
/// SDK plays through flv.js, a few seconds behind live instead of the ten-plus
/// of CDN HLS. iOS has no FLV support at all (AVPlayer), so it keeps `wide`.
/// How far a scale route has got, for the stall detector.
///
/// The playhead, except on HTTP-FLV: Android's player reports a live
/// progressive stream's position as a constant (1 ms on media3 1.9) while the
/// picture moves, so a playhead-based detector declared every FLV session
/// stalled ten seconds in and reopened it — a "reconnecting" loop every ~14 s
/// on a healthy stream. What moves on a live FLV route is the buffered end:
/// media keeps arriving for as long as the route is alive, and stops when it
/// dies, which is exactly the failure the detector exists to catch.
int scaleProgress({
  required bool flv,
  required Duration position,
  required Duration bufferedEnd,
}) =>
    (flv ? bufferedEnd : position).inMilliseconds;

bool get platformPlaysFlv =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Builds the ordered route list for a playback mode.
///
/// The gateway's own ordering is preserved verbatim — it knows which routes are
/// actually serving and what each costs to serve. The origin playlist is always
/// appended last, both as a guaranteed fallback and because every byte of it is
/// billed to us, unlike an edge route.
///
/// The buffered `fast` route (HTTP-FLV) is included only when [flv] is set —
/// see [platformPlaysFlv]: on a player without an FLV demuxer it is a route
/// that could never play.
///
/// [quality] (a rendition id, null for auto), [maxHeight] and [allowed]
/// choose which rung of a laddered route is opened. Routes without
/// renditions are untouched by all three.
List<PlaybackCandidate> buildCandidates(
  PlaybackPipeline preferred,
  List<MebiusDelivery> deliveries, {
  bool flv = false,
  String? quality,
  int? maxHeight,
  List<String>? allowed,
}) {
  final out = <PlaybackCandidate>[];
  if (preferred == PlaybackPipeline.lowLatency) {
    out.add(const PlaybackCandidate(PlaybackPipeline.lowLatency));
  }
  final usable = deliveries.where((d) => d.isResolvable);
  if (quality != null) {
    // A pinned rung opens only as that rung. When no route has it (or none of
    // them opens) the list runs dry and the engine falls back to auto, rather
    // than quietly playing source under a label that says otherwise.
    for (final d in usable) {
      final rung = d.renditions.where((r) => r.id == quality).firstOrNull;
      if (rung == null) {
        continue;
      }
      if (d.kind == 'fast' && flv) {
        out.add(PlaybackCandidate.flv(rung.path, rung.id));
      } else if (d.kind == 'wide') {
        out.add(PlaybackCandidate(PlaybackPipeline.scale, rung.path, rung.id));
      }
    }
    return out;
  }
  // Uncapped auto on a laddered stream plays the `wide` master playlist first,
  // so the platform player's own ABR (ExoPlayer/AVPlayer) picks the rung —
  // within [allowed], which the gateway applies to the master via `q`. FLV has
  // no master, so it moves behind `wide` as a fallback: adapting it would
  // mean our own buffering heuristic stepping rungs. The cost is HLS latency
  // instead of FLV latency in auto; a manual pick or a cap still opens FLV
  // first.
  final nativeAbr = maxHeight == null &&
      usable.any((d) => d.kind == 'wide' && d.renditions.isNotEmpty);
  PlaybackCandidate? deferredFlv;
  for (final d in usable) {
    final rungs = allowedRungs(d.renditions, allowed);
    final restricted =
        maxHeight != null || rungs.length < d.renditions.length;
    // "fast" (HTTP-FLV) only where the platform player can demux FLV; the
    // gateway lists it first, so it is tried first and `wide` stays the
    // fallback. Elsewhere it is a route that could never play.
    if (d.kind == 'fast' && flv) {
      // Highest allowed rung under the cap; source when nothing restricts it.
      final rung = restricted ? pickRendition(rungs, maxHeight) : null;
      final c = PlaybackCandidate.flv(rung?.path ?? d.path, rung?.id);
      if (nativeAbr) {
        deferredFlv = c;
      } else {
        out.add(c);
      }
    } else if (d.kind == 'wide') {
      final rung = maxHeight != null ? pickRendition(rungs, maxHeight) : null;
      out.add(
        PlaybackCandidate(
          PlaybackPipeline.scale,
          rung?.path ??
              (restricted && rungs.isNotEmpty
                  ? _withQuery(d.path, rungs)
                  : d.path),
          rung?.id,
        ),
      );
      if (deferredFlv != null) {
        out.add(deferredFlv);
        deferredFlv = null;
      }
    } else if (d.kind == 'local') {
      out.add(PlaybackCandidate(PlaybackPipeline.scale, d.path));
    }
  }
  // Only reachable if the gateway ever listed `wide` before `fast`.
  if (deferredFlv != null) {
    out.add(deferredFlv);
  }
  // Origin playlist, addressed without a delivery path.
  out.add(const PlaybackCandidate(PlaybackPipeline.scale));
  return out;
}

/// The master playlist [path] limited to [rungs]: the gateway drops every
/// variant not named in `q`. The token is appended after it as usual.
String _withQuery(String path, List<MebiusQuality> rungs) {
  final ids = rungs.map((r) => Uri.encodeQueryComponent(r.id)).join(',');
  return '$path${path.contains('?') ? '&' : '?'}q=$ids';
}

/// The rungs of [ladder] named in [allowed], in ladder order.
///
/// Null or empty [allowed] means every rung, and so does a set that names
/// none of them: a filter that leaves nothing to play is ignored rather than
/// turning a laddered stream into an unplayable one.
List<MebiusQuality> allowedRungs(
  List<MebiusQuality> ladder,
  List<String>? allowed,
) {
  if (allowed == null || allowed.isEmpty) {
    return ladder;
  }
  final kept = ladder.where((r) => allowed.contains(r.id)).toList();
  return kept.isEmpty ? ladder : kept;
}

/// The highest of [rungs] at or under [maxHeight] (no cap when null) — the
/// lowest rung when none fits. Null only for an empty ladder.
///
/// ponytail: a cap pins one fixed rung, so capped auto does not adapt below
/// it. A native cap over a platform channel (ExoPlayer track-selection max
/// video size, AVPlayer `preferredMaximumResolution`) on the master playlist
/// would keep ABR under the cap; add it when a capped viewer needs to adapt.
MebiusQuality? pickRendition(List<MebiusQuality> rungs, int? maxHeight) {
  if (rungs.isEmpty) {
    return null;
  }
  final byHeight = [...rungs]..sort((a, b) => b.height.compareTo(a.height));
  return byHeight.firstWhere(
    (r) => maxHeight == null || r.height <= maxHeight,
    orElse: () => byHeight.last,
  );
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

  /// Chosen rendition id, or null for auto. Read on every [start].
  String? quality;

  /// Auto-mode height cap, or null for none. Read on every [start].
  int? maxHeight;

  /// Rendition ids auto may use, or null for all. Read on every [start].
  List<String>? allowed;

  /// What the last successful [start] opened: the rung id (null when not one
  /// fixed rung), and whether auto chose it.
  String? openedQualityId;
  bool openedAuto = true;
  String? _openedKey;

  /// Whether the quality choice moved since the last successful [start] —
  /// the open that landed is stale and should be redone (latest wins).
  bool get selectionChanged =>
      _openedKey != _selectionKey(quality, maxHeight, allowed);

  // A manual pick overrides the cap and the allowed set, so they are not part
  // of its key.
  static String _selectionKey(String? q, int? cap, List<String>? allowed) =>
      q != null ? 'q:$q' : 'auto:$cap:${allowed?.join(',')}';

  // Low-latency (WebRTC) state.
  RTCPeerConnection? _pc;
  MediaStream? _remoteStream;
  String? _resourceUrl;

  // Scale (HLS) state.
  VideoPlayerController? _videoController;

  /// The serving scale route is the buffered `fast` route (HTTP-FLV).
  bool _flv = false;

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
    final pinned = quality;
    if (pinned != null) {
      try {
        await _walk(streamId, pinned);
        return;
      } on Object catch (_) {
        // A pinned rung that will not open — the vendor may skip a rung larger
        // than the source — falls back to auto rather than failing. Unless the
        // viewer already picked something else meanwhile.
        if (quality == pinned) {
          quality = null;
        }
      }
    }
    await _walk(streamId, null);
  }

  Future<void> _walk(String streamId, String? pinned) async {
    final cap = maxHeight;
    final allow = allowed;
    Object? lastError;
    for (final candidate in buildCandidates(
      pipeline,
      deliveries,
      flv: platformPlaysFlv,
      quality: pinned,
      maxHeight: cap,
      allowed: allow,
    )) {
      try {
        if (await openCandidate(streamId, candidate)) {
          openedQualityId = candidate.qualityId;
          openedAuto = pinned == null;
          _openedKey = _selectionKey(pinned, cap, allow);
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

  /// Opens one route and resolves whether it produced a first frame. The seam
  /// tests replace to drive route outcomes without a platform player.
  @visibleForTesting
  Future<bool> openCandidate(String streamId, PlaybackCandidate candidate) async {
    switch (candidate.pipeline) {
      case PlaybackPipeline.lowLatency:
        await _startLowLatency(streamId);
      case PlaybackPipeline.scale:
        await _startScale(streamId, candidate.path, flv: candidate.flv);
    }
    return _awaitFirstFrame();
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

  Future<void> _startScale(
    String streamId,
    String? deliveryPath, {
    bool flv = false,
  }) async {
    final url = deliveryPath == null
        ? signaling.scalePlaylistUrl(streamId)
        : signaling.deliveryUrl(deliveryPath);
    await signaling.ensureScaleReachable(streamId, url);
    // Delivery paths (`/d/wide/{id}`) carry no `.m3u8` extension, and Android's
    // player guesses the container from the URL: without the hint it opens the
    // playlist as a progressive file and fails with UnrecognizedInputFormat.
    // FLV is exactly that progressive case, so it gets no hint and the player
    // sniffs the container.
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: flv ? null : VideoFormat.hls,
    );
    _videoController = controller;
    _flv = flv;
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
  ///
  /// Carries a `progress` entry alongside the reportable numbers: a monotonic
  /// count of how far playback has actually got, which is the only evidence
  /// Flutter has that a route is still alive. Neither pipeline reports its own
  /// death — the platform player holds its last frame and goes on claiming to be
  /// initialized, and a peer connection reports `connected` long after the far
  /// end stopped sending — but both of these counters only move while media is
  /// arriving. It rides along with the stats rather than being read separately,
  /// because on the real-time route that would mean a second native `getStats`
  /// every tick for one integer.
  ///
  /// `progress` is -1 when it could not be read. Not 0: a stats call that throws
  /// says nothing about the stream, and 0 would read as the playhead jumping
  /// backwards to whatever is comparing successive values.
  Future<Map<String, num>> readStats() async {
    final pc = _pc;
    if (pc != null) {
      var bitrate = 0.0;
      var fps = 0.0;
      var progress = -1;
      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          if (r.type == 'inbound-rtp') {
            final values = r.values;
            fps = (values['framesPerSecond'] as num?)?.toDouble() ?? fps;
            final bytes = (values['bytesReceived'] as num?)?.toDouble() ?? 0;
            bitrate = bytes * 8 / 1000;
          }
        }
        progress = decodedVideoFrames(reports);
      } on Object catch (_) {
        // Same reasoning as _hasFrame: flutter_webrtc throws a bare String from
        // native getStats, and stop() is public enough to land mid-poll.
      }
      return {'bitrate': bitrate, 'fps': fps, 'buffered': 0, 'progress': progress};
    }
    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      var buffered = 0;
      if (controller.value.buffered.isNotEmpty) {
        buffered = controller.value.buffered.last.end.inMilliseconds -
            controller.value.position.inMilliseconds;
      }
      return {
        'bitrate': 0,
        'fps': 0,
        'buffered': buffered,
        'progress': scaleProgress(
          flv: _flv,
          position: controller.value.position,
          bufferedEnd: controller.value.buffered.isEmpty
              ? Duration.zero
              : controller.value.buffered.last.end,
        ),
      };
    }
    return const {};
  }
}
