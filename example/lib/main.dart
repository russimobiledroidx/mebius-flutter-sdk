import 'package:flutter/material.dart';
import 'package:mebius/mebius.dart';

/// Replace these with values for your Mebius account and a token minted by
/// your backend. The client never holds your app secret.
const String kAppId = 'your-app-id';
const String kGateway = 'https://gateway.mebius.example';
const String kToken = 'paste-a-short-lived-token-from-your-backend';

void main() {
  // Configure the SDK once, before the app starts.
  Mebius.init(appId: kAppId, gateway: kGateway);
  runApp(const MebiusExampleApp());
}

/// Root widget for the example app.
class MebiusExampleApp extends StatelessWidget {
  /// Creates the example app.
  const MebiusExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mebius Example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomeScreen(),
    );
  }
}

/// Landing screen offering the broadcast and watch flows.
class HomeScreen extends StatefulWidget {
  /// Creates the home screen.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  MebiusClient? _client;

  MebiusClient _ensureClient() {
    return _client ??= Mebius.connect(token: kToken);
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mebius Example')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.videocam),
              label: const Text('Broadcast'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BroadcastScreen(client: _ensureClient()),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.play_circle),
              label: const Text('Watch'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WatchScreen(client: _ensureClient()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Screen that captures and broadcasts the local camera and microphone.
class BroadcastScreen extends StatefulWidget {
  /// Creates the broadcast screen bound to [client].
  const BroadcastScreen({required this.client, super.key});

  /// The connected Mebius client.
  final MebiusClient client;

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final TextEditingController _streamId =
      TextEditingController(text: 'demo-stream');
  late final MebiusBroadcaster _broadcaster =
      widget.client.createBroadcaster();
  bool _live = false;
  bool _micOn = true;
  bool _camOn = true;
  String _status = 'Idle';

  @override
  void initState() {
    super.initState();
    _broadcaster.events.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        switch (event.type) {
          case MebiusBroadcasterEventType.started:
            _status = 'Live';
            _live = true;
          case MebiusBroadcasterEventType.stopped:
            _status = 'Stopped';
            _live = false;
          case MebiusBroadcasterEventType.stats:
            _status = 'Live • ${event.stats?.frameRate.toStringAsFixed(0)} fps';
        }
      });
    });
  }

  Future<void> _toggleBroadcast() async {
    try {
      if (_live) {
        await _broadcaster.stop();
      } else {
        await _broadcaster.start(_streamId.text.trim());
      }
    } on MebiusError catch (e) {
      _showError(e);
    }
  }

  void _showError(MebiusError e) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${e.codeName}: ${e.message}')),
    );
  }

  @override
  void dispose() {
    _broadcaster.dispose();
    _streamId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Broadcast — $_status')),
      body: Column(
        children: [
          Expanded(child: MebiusView(broadcaster: _broadcaster)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _streamId,
              decoration: const InputDecoration(
                labelText: 'Stream ID',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton.filledTonal(
                  icon: Icon(_micOn ? Icons.mic : Icons.mic_off),
                  onPressed: () {
                    setState(() => _micOn = !_micOn);
                    _broadcaster.setMicEnabled(enabled: _micOn);
                  },
                ),
                IconButton.filledTonal(
                  icon: Icon(_camOn ? Icons.videocam : Icons.videocam_off),
                  onPressed: () {
                    setState(() => _camOn = !_camOn);
                    _broadcaster.setCameraEnabled(enabled: _camOn);
                  },
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.cameraswitch),
                  onPressed: _broadcaster.switchCamera,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _toggleBroadcast,
                child: Text(_live ? 'Stop' : 'Start'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Screen that plays a stream, toggling between latency-optimized and
/// scale-optimized modes.
class WatchScreen extends StatefulWidget {
  /// Creates the watch screen bound to [client].
  const WatchScreen({required this.client, super.key});

  /// The connected Mebius client.
  final MebiusClient client;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  final TextEditingController _streamId =
      TextEditingController(text: 'demo-stream');
  MebiusPlayerMode _mode = MebiusPlayerMode.lowLatency;
  MebiusPlayer? _player;
  bool _playing = false;
  double _volume = 1;
  String _status = 'Idle';

  Future<void> _play() async {
    await _stop();
    final player = widget.client.createPlayer(mode: _mode)
      ..events.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          switch (event.type) {
            case MebiusPlayerEventType.playing:
              _status = 'Playing';
              _playing = true;
            case MebiusPlayerEventType.buffering:
              _status = 'Buffering…';
            case MebiusPlayerEventType.ended:
              _status = 'Ended';
              _playing = false;
            case MebiusPlayerEventType.stats:
              _status = 'Playing • '
                  '${event.stats?.frameRate.toStringAsFixed(0)} fps';
          }
        });
      });
    _player = player;
    setState(() {});
    try {
      await player.play(_streamId.text.trim());
      await player.setVolume(_volume);
    } on MebiusError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${e.codeName}: ${e.message}')),
        );
      }
    }
  }

  Future<void> _stop() async {
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
    }
    if (mounted) {
      setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _streamId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: Text('Watch — $_status')),
      body: Column(
        children: [
          Expanded(
            child: player == null
                ? const ColoredBox(color: Colors.black)
                : MebiusView.player(player: player),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _streamId,
              decoration: const InputDecoration(
                labelText: 'Stream ID',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SegmentedButton<MebiusPlayerMode>(
            segments: const [
              ButtonSegment(
                value: MebiusPlayerMode.lowLatency,
                label: Text('Low latency'),
              ),
              ButtonSegment(
                value: MebiusPlayerMode.scale,
                label: Text('Scale'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) async {
              setState(() => _mode = selection.first);
              if (_playing) {
                await _play();
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.volume_up),
                Expanded(
                  child: Slider(
                    value: _volume,
                    onChanged: (v) {
                      setState(() => _volume = v);
                      _player?.setVolume(v);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _playing ? _stop : _play,
                child: Text(_playing ? 'Stop' : 'Play'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
