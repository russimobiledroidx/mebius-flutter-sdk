# mebius_screen

Desktop screen share for Mebius, for monitoring and remote-support apps:

- **`MebiusScreenAgent`** runs on the employee's computer (Windows, macOS). It enrolls the device once, stays online, publishes the primary screen when an admin opens a session, and applies the admin's mouse and keyboard input in a `control` session.
- **`MebiusScreenViewer`** + **`MebiusScreenView`** let a Flutter admin app watch a session and, in `control` mode, drive it.

It is a separate package from `mebius` because it carries desktop-only native code (CoreGraphics and `SendInput` through FFI, `win32`) that must not reach mobile apps. Media goes through the `mebius` broadcaster and player.

The protocol it speaks (REST, the agent event stream, WHIP/WHEP, the input schema) is in the screen-share integration guide. Your backend creates enroll codes and sessions with your `sk_` key; neither the agent nor the viewer ever sees it.

## Install

```sh
flutter pub add mebius_screen
```

Requires Flutter 3.38+ (Dart 3.10+). It pulls in `mebius` at a matching
minor version.

## Agent

```dart
import 'package:mebius_screen/mebius_screen.dart';

final agent = MebiusScreenAgent(
  engineUrl: Uri.parse('https://stream.mebius.io'),
  credentials: MebiusSecureCredentialStore(), // Keychain / DPAPI
);

// Once, at onboarding. The code (enr_…) comes from your backend.
if (!await agent.isEnrolled) {
  await agent.enroll(code: enrollCode, name: hostName, os: 'windows');
}

agent.onSession.listen((s) {
  // s.sessionId, s.mode ('view' | 'control'), s.userId (your admin id)
  showNotice(s.isControl ? 'An admin is controlling your screen' : 'Your screen is being viewed');
});
agent.onSessionEnded.listen((sessionId) => hideNotice());
agent.onError.listen((e) {
  // MebiusErrorCode.tokenExpired: the device was revoked. Enroll again.
});

await agent.connect(); // returns at once; stays online until disconnect()
```

What the agent does by itself:

- Keeps the event stream open, reconnecting after 1 s, 2 s, 4 s … up to 30 s, with jitter. A connection silent for 45 s (no 15 s ping) is replaced.
- On `session.start`: captures the primary display at 15 fps with no picker and publishes it, capped at the session's `maxBitrateKbps`, through the session's TURN servers when the engine sends them. A new session replaces the running one.
- On `session.stop`, or when the event stream drops: stops publishing and emits `onSessionEnded`.
- Applies input only while the current session is `control`, and only for that session id.

What your app does: the tray icon and the "you are being viewed/controlled" notice (required for UU PDP compliance), auto-start at login (e.g. `launch_at_startup`), the macOS permission onboarding below, and a "stop control" button (call `disconnect()`, or have your backend end the session).

## Viewer (Flutter admin app)

```dart
final viewer = MebiusScreenViewer(engineUrl: Uri.parse('https://stream.mebius.io'));

// sessionId, token and (if present) iceServers come from your backend's
// POST /screen/devices/:id/sessions response.
await viewer.watch(sessionId: sessionId, token: token, iceServers: iceServers);

// In the widget tree:
MebiusScreenView(viewer);

// control sessions only:
viewer.enableControl(refreshToken: () => myApi.newSessionToken(sessionId));
viewer.onEnded.listen((reason) => close());
await viewer.close();
```

- `watch` retries every second for ~15 s while the agent starts publishing.
- `MebiusScreenView` fits the screen whole and maps pointer positions onto it, so the black bars send nothing. Click it to give it keyboard focus.
- Input is batched (one request per ~33 ms, at most 64 events, consecutive moves collapsed). The token is renewed a minute before it expires, and once on a 401. Control turns itself off when the engine refuses input for good (view-only, session over, token not renewable).

## Platform setup

### macOS (13+)

Set `MACOSX_DEPLOYMENT_TARGET` to 13.0 or later (the example does).

The agent needs two privacy permissions, granted by the user in System Settings → Privacy & Security, or by an MDM PPPC profile on managed machines:

- **Screen Recording**: for the capture. Without it macOS captures the wallpaper only.
- **Accessibility**: for remote control. Without it macOS silently drops injected input; the agent checks for it and reports `permissionDenied` on `onError` instead.

Entitlements (see `example/macos/Runner/*.entitlements`):

- `com.apple.security.network.client`: the event stream and media.
- **App Sandbox off**. A sandboxed app cannot post input events to other apps. If you only need `view` sessions you can keep the sandbox, but note the capture still needs Screen Recording.

`MebiusSecureCredentialStore` uses the login keychain, so no keychain-access-groups entitlement (and no signing team) is needed.

### Windows (10+)

Run the agent in the user's session, not as a Windows service: a service (session 0) cannot capture the user's screen. The UAC prompt and the lock screen (the secure desktop) cannot be captured or controlled from the user session.

Pointer positions use `SendInput`'s absolute coordinates on the primary monitor, so display scaling (DPI) needs no handling.

### Other platforms

The agent's remote control is macOS and Windows only; elsewhere input is ignored. The viewer runs on any platform with `dart:ffi` (not the web; a web dashboard uses `@mebius-io/web`).

## Keys

Input carries `KeyboardEvent.code` values (physical keys). Both agents map letters, digits, punctuation (`Minus` … `Slash`, `Backquote`, `IntlBackslash`), `Enter`, `Escape`, `Backspace`, `Tab`, `Space`, `CapsLock`, the arrows, `Insert`/`Delete`/`Home`/`End`/`PageUp`/`PageDown`, left/right `Shift`/`Control`/`Alt`/`Meta`, `F1`–`F12`, the numpad (`Numpad0`–`Numpad9`, operators, `NumpadDecimal`, `NumpadEnter`), `ContextMenu` and `PrintScreen`. Other keys are ignored. The character a key produces follows the agent's keyboard layout.

Keys and buttons still held when a session ends, control is switched off, or the view loses focus are released, so nothing stays pressed on the device.

## Limits

- Primary monitor only.
- No recording.

## Example

`example/` is a minimal agent (enroll, go online/offline, a status line) for macOS and Windows:

```sh
cd example
flutter run -d macos
```

## Developing in this repo

`pubspec_overrides.yaml` points `mebius` at the repo root, so `flutter pub get`, `flutter analyze` and `flutter test` here build against the local `mebius`. Publish with `tool/publish_mebius_screen.sh` from the repo root (it explains why), after the matching `mebius` is on pub.dev.
