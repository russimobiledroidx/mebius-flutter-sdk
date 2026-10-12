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

import 'dart:async';

import 'package:clock/clock.dart';
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
///
/// This is the budget for FLV and WebRTC, which show a picture in about half a
/// second when they work. HLS gets [kHlsFirstFrameTimeout].
const Duration kFirstFrameTimeout = Duration(seconds: 8);

/// First-frame budget for an HLS route (`wide`, `local`, origin playlist).
///
/// A cold CDN edge answers the master and media playlists in 5–6 s each on the
/// first request, and AVPlayer then buffers a few 3–4 s segments before it
/// moves the playhead. 8 s abandoned healthy routes on iPhone, and each
/// abandoned route restarts the next one from zero: a "connecting" loop.
const Duration kHlsFirstFrameTimeout = Duration(seconds: 20);

/// How long an HLS route that is still visibly loading may run past
/// [kHlsFirstFrameTimeout] before it is abandoned anyway.
const Duration kHlsFirstFrameHardCap = Duration(seconds: 30);

/// How long after the buffered end last moved an HLS route still counts as
/// loading. A live playlist's buffer grows one 3–4 s segment at a time, so
/// "grew since the last 200 ms poll" is false most of the time even on a
/// route that is loading fine.
const Duration kHlsProgressWindow = Duration(seconds: 5);

/// Upper bound on the platform player's `initialize()` for an HLS route. An
/// AVPlayer item stuck in "unknown" never completes it, and nothing else
/// would move the viewer on.
const Duration kHlsInitializeTimeout = Duration(seconds: 20);

/// Upper bound on `initialize()` for the FLV route, which opens in about half
/// a second when it works.
const Duration kFlvInitializeTimeout = Duration(seconds: 15);

/// Whether an HLS route that has not shown a frame yet is still loading.
///
/// AVPlayer reports `isBuffering` only on change, so before the first frame
/// it usually stays false; the buffered end is the signal that moves. It is
/// remembered with the time it last grew, so a route counts as loading for
/// [kHlsProgressWindow] after each segment arrives.
class HlsProgress {
  Duration _end = Duration.zero;
  DateTime? _grewAt;

  bool progressing({required bool isBuffering, required Duration bufferedEnd}) {
    final now = clock.now();
    if (bufferedEnd > _end) {
      _end = bufferedEnd;
      _grewAt = now;
    }
    final grewAt = _grewAt;
    return isBuffering ||
        (grewAt != null && now.difference(grewAt) <= kHlsProgressWindow);
  }
}

/// Runs [initialize] with an upper bound of [limit].
///
/// On timeout the walk gets `connectionFailed` at once and moves to the next
/// route. The platform open may still finish later, so [dispose] runs when it
/// settles: a late controller is released, not leaked. On any other failure
/// [dispose] runs before the error is rethrown.
Future<void> initializeWithin(
  Future<void> Function() initialize,
  Future<void> Function() dispose,
  Duration limit,
) async {
  final init = initialize();
  try {
    await init.timeout(limit);
  } on TimeoutException catch (e) {
    unawaited(
      init.then<void>((_) {}, onError: (Object _) {}).whenComplete(dispose),
    );
    throw MebiusError(
      MebiusErrorCode.connectionFailed,
      'The stream did not start in time.',
      cause: e,
    );
  } on Object {
    await dispose();
    rethrow;
  }
}

/// What one poll of a route that is still opening saw.
enum FrameProbe {
  /// The picture is moving.
  frame,

  /// No picture yet, but media is still arriving.
  progressing,

  /// No picture and no sign of progress.
  waiting,

  /// The player reported an error; this route will not recover by waiting.
  failed,
}

/// Polls [probe] until a first frame, and decides when to give up.
///
/// FLV and WebRTC ([hls] false) keep the plain [kFirstFrameTimeout] and
/// ignore everything but `frame`, exactly as before. HLS gets
/// [kHlsFirstFrameTimeout], is abandoned at once on `failed`, and past that
/// budget keeps going while the probe reports `progressing` — up to
/// [kHlsFirstFrameHardCap]. [current] is the engine's generation check: once
/// it is false the open was retired, and nothing it reads counts.
Future<bool> awaitFirstFrame({
  required Future<FrameProbe> Function() probe,
  required bool Function() current,
  required bool hls,
}) async {
  final start = clock.now();
  final budget = hls ? kHlsFirstFrameTimeout : kFirstFrameTimeout;
  final cap = hls ? kHlsFirstFrameHardCap : kFirstFrameTimeout;
  while (current()) {
    final seen = await probe();
    if (!current()) {
      return false;
    }
    if (seen == FrameProbe.frame) {
      return true;
    }
    if (hls && seen == FrameProbe.failed) {
      return false;
    }
    final elapsed = clock.now().difference(start);
    if (elapsed >= cap ||
        (elapsed >= budget && !(hls && seen == FrameProbe.progressing))) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

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
/// renditions are untouched by all three, and so is low latency.
List<PlaybackCandidate> buildCandidates(
  PlaybackPipeline preferred,
  List<MebiusDelivery> deliveries, {
  bool flv = false,
  String? quality,
  int? maxHeight,
  List<String>? allowed,
}) {
  if (preferred == PlaybackPipeline.lowLatency) {
    // A real-time session has one quality. Its fallbacks ignore the ladder
    // entirely, so their order and URLs stay exactly as they were in 0.5.1.
    return [
      const PlaybackCandidate(PlaybackPipeline.lowLatency),
      ...buildCandidates(
        PlaybackPipeline.scale,
        [for (final d in deliveries) MebiusDelivery(kind: d.kind, path: d.path)],
        flv: flv,
      ),
    ];
  }
  final out = <PlaybackCandidate>[];
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

  /// Bumped by [stop]. An open captures it when it begins and publishes into
  /// the fields above only while it is unchanged, so an open that outlives a
  /// [stop] — a quality reopen still in flight when the viewer switched
  /// streams — releases what it made instead of replacing the newer session.
  int _gen = 0;

  @visibleForTesting
  int get generation => _gen;

  static const MebiusError _stopped = MebiusError(
    MebiusErrorCode.connectionFailed,
    'Playback was stopped before the stream opened.',
  );

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
    final gen = _gen;
    final pinned = quality;
    if (pinned != null) {
      try {
        await _walk(streamId, pinned, gen);
        return;
      } on Object catch (_) {
        if (gen != _gen) {
          rethrow;
        }
        // A pinned rung that will not open — the vendor may skip a rung larger
        // than the source — falls back to auto rather than failing. Unless the
        // viewer already picked something else meanwhile.
        if (quality == pinned) {
          quality = null;
        }
      }
    }
    await _walk(streamId, null, gen);
  }

  Future<void> _walk(String streamId, String? pinned, int gen) async {
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
      // Stopped mid-walk: whatever runs now belongs to a newer session.
      if (gen != _gen) {
        throw _stopped;
      }
      try {
        final ok = await openCandidate(streamId, candidate, gen);
        if (gen != _gen) {
          // stop() already released what this open published.
          throw _stopped;
        }
        if (ok) {
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
        if (gen != _gen) {
          throw _stopped;
        }
        lastError = e;
      }
      // Release the dead route before opening the next one; leaving a peer
      // connection or a platform player attached leaks it for the whole session.
      await _release();
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
  ///
  /// Publishes into the engine's state only while [gen] is current; once it is
  /// not, disposes what it made itself and stops.
  @visibleForTesting
  Future<bool> openCandidate(
    String streamId,
    PlaybackCandidate candidate,
    int gen,
  ) async {
    switch (candidate.pipeline) {
      case PlaybackPipeline.lowLatency:
        await _startLowLatency(streamId, gen);
      case PlaybackPipeline.scale:
        await _startScale(streamId, candidate.path, gen, flv: candidate.flv);
    }
    final progress = HlsProgress();
    return awaitFirstFrame(
      // Never reads a newer session's frame as this open's.
      current: () => gen == _gen,
      hls: candidate.pipeline == PlaybackPipeline.scale && !candidate.flv,
      probe: () async {
        final controller = _videoController;
        if (controller == null) {
          return await _hasFrame() ? FrameProbe.frame : FrameProbe.waiting;
        }
        final v = controller.value;
        if (v.hasError) {
          return FrameProbe.failed;
        }
        if (v.isInitialized && v.position > Duration.zero) {
          return FrameProbe.frame;
        }
        // Progress is buffering or the buffered end moving recently, not
        // "initialized": every route that reaches this wait is initialized,
        // stuck ones included.
        return progress.progressing(
          isBuffering: v.isBuffering,
          bufferedEnd:
              v.buffered.isEmpty ? Duration.zero : v.buffered.last.end,
        )
            ? FrameProbe.progressing
            : FrameProbe.waiting;
      },
    );
  }

  /// Whether the stream is actually rendering.
  ///
  /// Progress of the picture is the signal, not "initialized" or "connected" —
  /// both of those are true on a route that is sending nothing.
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

  Future<void> _startLowLatency(String streamId, int gen) async {
    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    if (gen != _gen) {
      await pc.close();
      await pc.dispose();
      throw _stopped;
    }
    // Published: from here a stop() closes it, and the awaits below throw.
    _pc = pc;

    pc.onTrack = (event) {
      if (_pc == pc && event.streams.isNotEmpty) {
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
    if (gen != _gen) {
      final resource = result.resourceUrl;
      if (resource != null) {
        await signaling.deleteResource(resource);
      }
      throw _stopped;
    }
    _resourceUrl = result.resourceUrl;
    await pc.setRemoteDescription(
      RTCSessionDescription(result.answerSdp, 'answer'),
    );
  }

  Future<void> _startScale(
    String streamId,
    String? deliveryPath,
    int gen, {
    bool flv = false,
  }) async {
    final url = deliveryPath == null
        ? signaling.scalePlaylistUrl(streamId)
        : signaling.deliveryUrl(deliveryPath);
    await signaling.ensureScaleReachable(streamId, url);
    if (gen != _gen) {
      throw _stopped;
    }
    // Delivery paths (`/d/wide/{id}`) carry no `.m3u8` extension, and Android's
    // player guesses the container from the URL: without the hint it opens the
    // playlist as a progressive file and fails with UnrecognizedInputFormat.
    // FLV is exactly that progressive case, so it gets no hint and the player
    // sniffs the container.
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: flv ? null : VideoFormat.hls,
    );
    // Published: from here a stop() disposes it.
    _videoController = controller;
    _flv = flv;
    try {
      await initializeWithin(
        controller.initialize,
        controller.dispose,
        flv ? kFlvInitializeTimeout : kHlsInitializeTimeout,
      );
    } catch (e) {
      // initializeWithin has disposed it, or will once a late open settles.
      if (_videoController == controller) {
        _videoController = null;
      }
      if (gen != _gen) {
        throw _stopped;
      }
      throw e is MebiusError
          ? e
          : MebiusError(
              MebiusErrorCode.connectionFailed,
              'Playback could not be started for this stream.',
              cause: e,
            );
    }
    if (gen != _gen) {
      // stop() already disposed it.
      throw _stopped;
    }
    await controller.setVolume(_volume);
    await controller.play();
  }

  /// Stops playback and releases resources. Any open still in flight is
  /// retired with it.
  Future<void> stop() async {
    _gen += 1;
    await _release();
  }

  /// Releases the current route. Everything is detached before the first
  /// await, so a route published meanwhile is never the one torn down.
  Future<void> _release() async {
    final resource = _resourceUrl;
    final pc = _pc;
    final controller = _videoController;
    _resourceUrl = null;
    _pc = null;
    _remoteStream = null;
    _videoController = null;
    if (resource != null) {
      await signaling.deleteResource(resource);
    }
    // dispose() as well as close(): only dispose removes the connection from the
    // plugin's registry. Pre-existing, but this fix is what makes it reachable —
    // the real-time route used to always report success, so failover never ran
    // and no connection was ever abandoned. Now every viewer on a dead route
    // would leak one for the session.
    await pc?.close();
    await pc?.dispose();
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
