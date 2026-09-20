## Unreleased

- Publishing is capped at 2500 kbps by default, matching the studio's OBS encoder,
  so a broadcast costs the same whichever path it came from. `createBroadcaster`
  takes `maxBitrateKbps` to change it; 0 lifts it entirely.

  The cap is applied to the sender's encoding parameters, which is the only place
  it is real. Capture constraints bound the SOURCE — how many pixels arrive per
  second — while the encoder still chooses how many bits to spend describing them,
  and high-motion content makes it spend near the top of its range.

  It matters far past the device: nothing transcodes anywhere in the path, so every
  viewer is delivered at exactly the bitrate published here. One broadcaster's
  setting is multiplied by the size of its audience.

- Camera capture now has maximums as well as minimums (1280x720 at 30fps). It had
  only minimums, which on a capable phone is a licence to send 1080p60 rather than
  a floor to meet — and this was the one SDK that could drift upward. It now
  captures what the Android and iOS SDKs capture.

## 0.3.0

- A delivery route that stops delivering is now reopened instead of leaving a
  frozen frame. Route selection ran exactly once, when playback started:
  whichever route produced the first frame served the rest of the session, and
  when it later died — a CDN edge restarting, the publisher reconnecting, the
  device changing network — the picture simply stopped. Nothing was reported at
  all, because neither pipeline knows it has stopped receiving.

  On a 90-minute watch that looked like bad luck. On a channel that runs for a
  day it is a certainty, because every one of those causes happens more than
  once a day, and the viewer's word for it is a black screen.

  The player now supervises the route it accepted. A route that reports it
  ended, or whose picture stands still for longer than ten seconds, is treated
  as lost: it is torn down and the full route list is walked again, because the
  usual causes take out one route and not the others. Reopening backs off (1s,
  2s, 4s, 8s, 16s) and gives up after five consecutive attempts — bounded on
  purpose, since every viewer of one broadcast fails at the same instant and an
  unbounded retry from a full room is how a recovery mechanism becomes the
  outage. `MebiusPlayerEventType.buffering` is emitted as soon as reopening
  starts, `playing` when a route is serving again, and `ended` only once the
  budget is spent.

  Refreshed credentials need no handling here: the client renews the token on
  its own schedule whether or not anything is playing, and every route stamps
  the current token as it builds its URL, so a route reopened after a long stall
  connects with today's credential.

- A session can now outlive the token it opened with. `MebiusClient.updateToken`
  replaces the credential in place: publishing and playback are not stopped,
  there is no renegotiation and no track is rebuilt. It throws for an empty
  token, or for one scoped to a different stream — swapping in a credential for
  another stream would not renew the session, it would break it on the next
  request, far from the line that caused it.
- `Mebius.connect` takes an optional `getToken`. Given one, the SDK mints a
  fresh credential shortly *before* `exp` rather than reacting to
  `TOKEN_EXPIRED` afterwards, and retries with backoff for as long as the
  current token is still valid — so `TOKEN_EXPIRED` now means the credential
  genuinely ran out, not that one mint failed. Each renewal emits
  `MebiusClientEventType.tokenRefreshed`.

  This is what a camera publisher needed: a match longer than the token's life
  used to cost a visible reconnect in the middle of it.
  A renewed token is refused — and retried, not fatal — when it is scoped to a
  different stream than the session, or when it does not outlive the token it
  replaces. A provider's late answer is also dropped if `updateToken` replaced
  the credential while it was being fetched, so the app's own swap always wins,
  and `disconnect()` during an in-flight renewal leaves no timer behind.

- Behaviour without `getToken` is unchanged. No renewal is scheduled, no new
  timer is armed, and an expired token still surfaces exactly when and how it
  did in 0.2.2 — proven by a test rather than asserted.

Known limitation: a segmented playback session already running keeps the URL it
was started with, because the platform video player is handed a URL once and
offers no hook to re-stamp its segment requests. Publishing, and every request
made after the swap, use the new token.

## 0.2.2

- A viewer no longer gets stuck on a black frame when the real-time route
  connects but sends nothing. The 8-second first-frame budget existed for
  exactly that case, but the check behind it asked whether a video track was
  present and enabled — true from the moment the session is negotiated, and true
  forever after, whether or not a single frame follows. So the route always
  reported success, playback never moved on to the next route, and there was no
  error to react to. Playback now waits for the decoder to actually produce a
  frame.
- A route that walks away is released properly. Failover never ran before this
  fix, so a peer connection was never abandoned; now that it can be, the
  connection is disposed rather than merely closed.
- A hiccup reading playback statistics no longer surfaces as an `unknown` error
  carrying an internal message. It is treated as "not playing yet", which is
  what it means.

Known limitation, unchanged: a broadcast with no camera — audio only — cannot be
played on the real-time route, on any Mebius SDK. Audio arrives, but the
first-frame budget is waiting for a picture that never comes, so playback falls
through to the buffered routes and then reports a connection failure. Publish
with video if you need the real-time route.

## 0.2.1

- A broadcast published from this SDK now reaches viewers who are not on the
  real-time route. libwebrtc negotiated VP8, which the gateway's segment-based
  deliveries cannot carry — they dropped the video track, so those viewers got
  audio only while the device showed a healthy preview and bitrate the whole
  time. The publishing transceiver now prefers H264, with VP8 kept as the
  fallback for a device that cannot encode H264.

## 0.2.0

- `Mebius.connect` accepts `deliveries`, the route list your backend receives
  with the access token. Pass it through as-is; Mebius orders it and picks from
  it. Without it every viewer is served from Mebius origin instead of the nearest
  edge — on mobile that is a per-viewer bill rather than none.
- New `MebiusPlayerMode.auto`, and `createPlayer()` now defaults to it. The old
  default was `lowLatency`, which opened a per-viewer real-time session for every
  audience member; only a monitor needs one.
- Playback walks an ordered route list with an 8-second first-frame budget per
  route. A route that opens successfully is not yet a route that plays: an edge
  with no ingest answers 200 with an empty stream, and a WebRTC connection reports
  `connected` while zero frames arrive. Previously either case left the viewer on
  a black frame with no error to react to.
- New `client.createMonitor()` for watching the other side of a co-broadcast.
- New `MebiusDelivery` with `listFromJson`, which skips malformed entries instead
  of throwing, and `isResolvable`, which refuses any path that would send the
  access token to a host Mebius did not choose.
- The buffered mid-latency route is deliberately not offered on Flutter: the
  platform player cannot play it, so declaring it would be a mode that can never
  work.

# Changelog

All notable changes to the `mebius` package are documented here. This project
adheres to [Semantic Versioning](https://semver.org). The public API is stable
within a major version.

## 0.1.0

- Initial release.
- Gateway contract aligned with the Mebius stream engine: the access token is
  passed via the `?token=` query parameter (the form the engine enforces) and
  scale playback is served from `/live/{streamId}/index.m3u8`.
- `Mebius.init` / `Mebius.connect` session bootstrap.
- `MebiusClient.createBroadcaster` and `MebiusClient.createPlayer`.
- `MebiusBroadcaster`: `start`, `stop`, `switchCamera`, `setMicEnabled`,
  `setCameraEnabled`, and `started` / `stopped` / `stats` events.
- `MebiusPlayer`: `play`, `stop`, `setVolume`, low-latency and scale modes,
  and `playing` / `buffering` / `ended` / `stats` events.
- `MebiusView` widget for broadcaster preview and player surfaces.
- Stable `MebiusError` codes: `TOKEN_EXPIRED`, `PERMISSION_DENIED`,
  `CONNECTION_FAILED`, `NOT_CONNECTED`, `STREAM_NOT_FOUND`, `UNKNOWN`.
