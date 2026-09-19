# mebius

Live video for Flutter — broadcast and watch real-time streams through the Mebius gateway with one simple API.

[![pub version](https://img.shields.io/pub/v/mebius.svg)](https://pub.dev/packages/mebius)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

`mebius` gives you a tiny, stable API for publishing a camera/microphone stream and for watching live streams, with two playback profiles: latency-optimized and scale-optimized. All transport is handled for you behind the Mebius gateway.

---

## 2. Requirements

- **Flutter:** `>= 3.22.0`
- **Dart:** `>= 3.4.0 < 4.0.0`
- **iOS:** 13.0+ (camera & microphone usage descriptions required)
- **Android:** `minSdkVersion 24`+ (camera, microphone & internet permissions required)

### iOS — `Info.plist`

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to broadcast live video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to broadcast live audio.</string>
```

### Android — `AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
```

---

## 3. Install

Add `mebius` from pub.dev:

```sh
flutter pub add mebius
```

or add it manually to your `pubspec.yaml` and run `flutter pub get`:

```yaml
dependencies:
  mebius: ^0.2.2
```

Then import it:

```dart
import 'package:mebius/mebius.dart';
```

<details>
<summary>Alternative: install straight from Git</summary>

You can also pin the package to a Git tag/branch/commit instead of pub.dev:

```yaml
dependencies:
  mebius:
    git:
      url: https://github.com/russimobiledroidx/mebius-flutter-sdk.git
      ref: v0.2.2
```

`ref` accepts any git reference — a tag (recommended for reproducible builds), a
branch, or a full commit SHA.

</details>

---

## 4. Platform setup

### iOS

Set the platform floor and enable the required capabilities in `ios/Podfile`:

```ruby
platform :ios, '13.0'
```

Add the usage descriptions shown in [Requirements](#2-requirements) to `ios/Runner/Info.plist`. If you target a background broadcasting use case, also enable the relevant Background Modes in Xcode (Audio).

### Android

In `android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        minSdkVersion 24
    }
}
```

Add the permissions shown in [Requirements](#2-requirements) to
`android/app/src/main/AndroidManifest.xml`. Camera and microphone are
**runtime** permissions on Android 6.0+, so request them before broadcasting
(see [Troubleshooting](#9-troubleshooting)).

---

## 5. Quick Start

### Auth

The SDK never holds your app secret. Your backend mints a **short-lived token**
(a JWT derived from your `appId` + `appSecret`) and your app passes that token
to `Mebius.connect`. When the token expires the client emits an `error` event
with code `TOKEN_EXPIRED`; refresh the token from your backend and reconnect.

**Sessions longer than one token.** Pass `getToken` and the SDK renews the
credential shortly *before* `exp`, swapping it in place — no reconnect, no
renegotiation, no gap on screen. A failing provider is retried with backoff
while the current token is still valid, so `TOKEN_EXPIRED` means the credential
genuinely ran out. Each renewal emits `MebiusClientEventType.tokenRefreshed`.
Use `client.updateToken(newToken)` to do the same swap by hand.

```dart
final client = Mebius.connect(
  token: await backend.mintToken(),
  getToken: () => backend.mintToken(), // optional; omit for 0.2.x behaviour
);
```

This matters most to a camera publisher: a match longer than the token's life is
the difference between a seamless broadcast and a visible reconnect. Without
`getToken` nothing changes — no renewal is scheduled and expiry surfaces exactly
when it always did.

### Initialize and connect

```dart
import 'package:mebius/mebius.dart';

void main() {
  Mebius.init(
    appId: 'your-app-id',
    gateway: 'https://gateway.mebius.example',
  );
  runApp(const MyApp());
}

// Later, after fetching a token from your backend. The same response carries a
// `deliveries` list — pass it through as-is and Mebius picks the best route for
// each viewer, falling back on its own if one stops delivering frames.
final body = jsonDecode(response.body) as Map<String, dynamic>;
final client = Mebius.connect(
  token: body['token'] as String,
  deliveries: MebiusDelivery.listFromJson(body['deliveries']),
);

client.events.listen((event) {
  switch (event.type) {
    case MebiusClientEventType.connected:
      // Ready.
    case MebiusClientEventType.disconnected:
      // Session ended.
    case MebiusClientEventType.error:
      if (event.error?.code == MebiusErrorCode.tokenExpired) {
        // Refresh the token and reconnect.
      }
  }
});
```

### Broadcast

```dart
class BroadcastPage extends StatefulWidget {
  const BroadcastPage({required this.client, super.key});
  final MebiusClient client;

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  late final MebiusBroadcaster _broadcaster =
      widget.client.createBroadcaster(video: true, audio: true);

  @override
  void dispose() {
    _broadcaster.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: MebiusView(broadcaster: _broadcaster)),
        Row(
          children: [
            ElevatedButton(
              onPressed: () => _broadcaster.start('my-stream'),
              child: const Text('Start'),
            ),
            ElevatedButton(
              onPressed: _broadcaster.stop,
              child: const Text('Stop'),
            ),
            IconButton(
              onPressed: _broadcaster.switchCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
            IconButton(
              onPressed: () => _broadcaster.setMicEnabled(enabled: false),
              icon: const Icon(Icons.mic_off),
            ),
          ],
        ),
      ],
    );
  }
}
```

### Watch

```dart
class WatchPage extends StatefulWidget {
  const WatchPage({required this.client, super.key});
  final MebiusClient client;

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  late final MebiusPlayer _player =
      widget.client.createPlayer();

  @override
  void initState() {
    super.initState();
    _player.play('my-stream');
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: MebiusView.player(player: _player)),
        Slider(
          value: 1,
          onChanged: (v) => _player.setVolume(v),
        ),
        ElevatedButton(
          onPressed: _player.stop,
          child: const Text('Stop'),
        ),
      ],
    );
  }
}
```

### Playback modes

| Mode | When to use |
| --- | --- |
| `auto` (default) | Recommended. Mebius picks per viewer and re-picks if a route stops delivering. |
| `lowLatency` | Two-way interaction (co-broadcast), sub-second delay. Costs a per-viewer session, so it is not for a plain audience. |
| `scale` | Largest audiences and unstable networks. |

To switch, dispose the current player and create a new one:

```dart
client.createPlayer();                                  // auto
client.createPlayer(mode: MebiusPlayerMode.scale);      // scale
```

### Watching the other side of a co-broadcast

```dart
final monitor = client.createMonitor();
await monitor.play(opponentStreamId);
```

Same API as a player, different delay budget: it starts on the real-time route
and moves to another by itself if no frame arrives within 8 seconds.

### `deliveries`

`Mebius.connect` accepts the `deliveries` list your backend returned with the
token. Pass it through untouched — `kind` and `path` are opaque, and Mebius
decides the ordering. It is optional, but without it every viewer is served from
Mebius origin instead of the nearest edge, and on mobile that is billed per
viewer.

A full, copy-paste example with both screens, camera switching, mute,
mode-toggling and a volume slider lives in [`example/lib/main.dart`](example/lib/main.dart).

---

## 6. API Reference

| Member | Dart signature | Description |
| --- | --- | --- |
| `Mebius.init` | `static void init({required String appId, required String gateway})` | Configure the SDK once at startup. |
| `Mebius.connect` | `static MebiusClient connect({required String token, List<MebiusDelivery> deliveries = const [], Future<String> Function()? getToken})` | Open an authenticated session. `getToken` renews the credential before it expires. |
| `MebiusClient.updateToken` | `void updateToken(String token)` | Swap the credential in place. Throws for an empty token or one scoped to another stream. |
| `MebiusClient.createBroadcaster` | `MebiusBroadcaster createBroadcaster({bool video = true, bool audio = true})` | Create a broadcaster. |
| `MebiusClient.createPlayer` | `MebiusPlayer createPlayer({MebiusPlayerMode mode = MebiusPlayerMode.auto})` | Create a player. |
| `MebiusClient.createMonitor` | `MebiusPlayer createMonitor()` | Player for a stream you interact with. |
| `MebiusDelivery.listFromJson` | `static List<MebiusDelivery> listFromJson(Object? json)` | Parse the `deliveries` array from your token response. |
| `MebiusClient.disconnect` | `Future<void> disconnect()` | End the session and release everything. |
| `MebiusClient.events` | `Stream<MebiusClientEvent> events` | `connected` / `disconnected` / `error` / `tokenRefreshed`. |
| `MebiusBroadcaster.start` | `Future<void> start(String streamId)` | Begin broadcasting. |
| `MebiusBroadcaster.stop` | `Future<void> stop()` | Stop broadcasting. |
| `MebiusBroadcaster.switchCamera` | `Future<void> switchCamera()` | Flip front/back camera. |
| `MebiusBroadcaster.setMicEnabled` | `void setMicEnabled({required bool enabled})` | Mute/unmute the mic. |
| `MebiusBroadcaster.setCameraEnabled` | `void setCameraEnabled({required bool enabled})` | Enable/disable the camera. |
| `MebiusBroadcaster.events` | `Stream<MebiusBroadcasterEvent> events` | `started` / `stopped` / `stats`. |
| `MebiusPlayer.play` | `Future<void> play(String streamId, [Object? viewTarget])` | Begin playback. |
| `MebiusPlayer.stop` | `Future<void> stop()` | Stop playback. |
| `MebiusPlayer.setVolume` | `Future<void> setVolume(double volume)` | Set volume (0..1). |
| `MebiusPlayer.events` | `Stream<MebiusPlayerEvent> events` | `playing` / `buffering` / `ended` / `stats`. |
| `MebiusView` | `MebiusView({required MebiusBroadcaster broadcaster})` | Render a broadcaster preview. |
| `MebiusView.player` | `MebiusView.player({required MebiusPlayer player})` | Render a player surface. |

---

## 7. Events

All events are delivered through Dart `Stream`s. Subscribe with `listen` and
remember to keep the subscription only as long as the object lives.

### Client events

```dart
client.events.listen((MebiusClientEvent event) {
  // event.type : MebiusClientEventType { connected, disconnected, error }
  // event.error: MebiusError?  (set only for `error`)
});
```

### Broadcaster events

```dart
broadcaster.events.listen((MebiusBroadcasterEvent event) {
  // event.type : MebiusBroadcasterEventType { started, stopped, stats }
  // event.stats: MebiusBroadcastStats?  (set only for `stats`)
  //   - outboundBitrateKbps: double
  //   - frameRate:           double
  //   - packetsSent:         int
});
```

### Player events

```dart
player.events.listen((MebiusPlayerEvent event) {
  // event.type : MebiusPlayerEventType { playing, buffering, ended, stats }
  // event.stats: MebiusPlaybackStats?  (set only for `stats`)
  //   - inboundBitrateKbps: double
  //   - frameRate:          double
  //   - bufferedMs:         int
});
```

---

## 8. Error handling

Every failure is a `MebiusError` with a stable `code` (`MebiusErrorCode`) and a
human-readable `message`. The codes are identical across all Mebius client SDKs.

| Code | Meaning | Recovery |
| --- | --- | --- |
| `TOKEN_EXPIRED` | The connection token is no longer valid. | Mint a fresh token from your backend and reconnect. |
| `PERMISSION_DENIED` | Camera/microphone access was denied. | Prompt the user and request OS permissions, then retry. |
| `CONNECTION_FAILED` | Could not reach or hold the Mebius gateway. | Check connectivity and retry with backoff. |
| `NOT_CONNECTED` | An operation needs an active connection. | Reconnect via `Mebius.connect` before retrying. |
| `STREAM_NOT_FOUND` | The requested stream does not exist. | Verify the stream id; the broadcaster may not be live yet. |
| `UNKNOWN` | Unexpected failure. | Inspect `message`/`cause`; report if it persists. |

```dart
try {
  await broadcaster.start('my-stream');
} on MebiusError catch (e) {
  switch (e.code) {
    case MebiusErrorCode.permissionDenied:
      // Ask the user to grant camera/mic access.
    case MebiusErrorCode.tokenExpired:
      // Refresh token and reconnect.
    default:
      // Show e.message.
  }
}
```

---

## 9. Troubleshooting

- **Runtime permissions (Android/iOS):** declaring permissions in the manifest
  / `Info.plist` is not enough. On Android 6.0+ and iOS, the OS prompts the user
  the first time the camera/microphone is accessed. A denial surfaces as
  `MebiusErrorCode.permissionDenied`. Use a package such as
  `permission_handler` to request them up front for a smoother flow.
- **Background:** broadcasting in the background requires the appropriate OS
  capabilities (iOS Background Modes → Audio; Android foreground service). By
  default, expect publishing to pause when the app is backgrounded.
- **Dispose lifecycle:** always `dispose()` your `MebiusBroadcaster` and
  `MebiusPlayer` (typically in `State.dispose`), and `disconnect()` the
  `MebiusClient` when you are done. `MebiusView` releases its own renderer, but
  it does not own the broadcaster/player you pass in. Failing to dispose leaks
  camera/microphone and network resources.
- **Black video surface:** the surface stays black until media arrives. Listen
  for the `playing` (player) or `started` (broadcaster) event to know when it is
  live.

---

## 10. Versioning & changelog

This package follows [Semantic Versioning](https://semver.org). The public API
is stable within a major version; any breaking change to the contract is a major
version bump. See [`CHANGELOG.md`](CHANGELOG.md) for the full history.

---

## 11. License

Released under the [MIT License](LICENSE).
