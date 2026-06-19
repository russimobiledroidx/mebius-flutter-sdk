import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/mebius_broadcaster.dart';
import 'package:mebius/src/mebius_player.dart';
import 'package:video_player/video_player.dart';

/// Renders the video surface for a Mebius broadcaster preview or player.
///
/// Provide exactly one of [broadcaster] or [player]. When [broadcaster] is
/// given, the widget shows the local camera preview. When [player] is given,
/// the widget shows the incoming stream.
///
/// ```dart
/// // Broadcaster preview:
/// MebiusView(broadcaster: broadcaster)
///
/// // Player surface:
/// MebiusView(player: player)
/// ```
class MebiusView extends StatefulWidget {
  /// Creates a Mebius video surface bound to a [broadcaster] preview.
  const MebiusView({
    required MebiusBroadcaster this.broadcaster,
    this.fit = BoxFit.contain,
    this.mirror = true,
    super.key,
  }) : player = null;

  /// Creates a Mebius video surface bound to a [player].
  const MebiusView.player({
    required MebiusPlayer this.player,
    this.fit = BoxFit.contain,
    super.key,
  })  : broadcaster = null,
        mirror = false;

  /// The broadcaster whose local preview should be rendered, if any.
  final MebiusBroadcaster? broadcaster;

  /// The player whose stream should be rendered, if any.
  final MebiusPlayer? player;

  /// How the video should be inscribed into the widget's bounds.
  final BoxFit fit;

  /// Whether to mirror the video horizontally (typical for a selfie preview).
  final bool mirror;

  @override
  State<MebiusView> createState() => _MebiusViewState();
}

class _MebiusViewState extends State<MebiusView> {
  RTCVideoRenderer? _renderer;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    unawaited(_attach());
  }

  @override
  void didUpdateWidget(MebiusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.broadcaster != widget.broadcaster ||
        oldWidget.player != widget.player) {
      _detach();
      unawaited(_attach());
    } else {
      _refreshSources();
    }
  }

  Future<void> _attach() async {
    final usesWebrtc = widget.broadcaster != null ||
        widget.player?.mode == MebiusPlayerMode.lowLatency;
    if (usesWebrtc) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _renderer = renderer;
    }
    _refreshSources();
    if (mounted) {
      setState(() {});
    }
  }

  void _refreshSources() {
    final broadcaster = widget.broadcaster;
    final player = widget.player;
    if (broadcaster != null) {
      _renderer?.srcObject = broadcaster.engine.localStream;
    } else if (player != null) {
      if (player.mode == MebiusPlayerMode.lowLatency) {
        _renderer?.srcObject = player.engine.remoteStream;
      } else {
        _videoController = player.engine.videoController;
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _detach() {
    _renderer?.srcObject = null;
    final renderer = _renderer;
    if (renderer != null) {
      unawaited(renderer.dispose());
    }
    _renderer = null;
    // The VideoPlayerController is owned by the player/engine, not by the view.
    _videoController = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer != null) {
      return RTCVideoView(
        renderer,
        mirror: widget.mirror,
        objectFit: widget.fit == BoxFit.cover
            ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
            : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }
    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      return FittedBox(
        fit: widget.fit,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      );
    }
    return const ColoredBox(color: Color(0xFF000000));
  }
}
