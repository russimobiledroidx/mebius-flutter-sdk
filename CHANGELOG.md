## 0.6.1

- iPhone viewers no longer get stuck on "connecting" on CDN (HLS) streams.
  Every route had 8 s to show a first frame, but a cold CDN edge takes 5–6 s
  per playlist on the first request and AVPlayer then buffers a few 3–4 s
  segments, so healthy HLS routes were abandoned and the next route started
  again from zero. HLS routes (`wide`, `local`, origin) now get 20 s, and past
  that keep going while media is still arriving, up to 30 s. "Still arriving"
  means the player is buffering or the buffered range grew within the last
  5 s: AVPlayer does not report buffering before the first frame, and a live
  playlist's buffer grows one segment at a time. A player error abandons the
  route at once. FLV and WebRTC keep 8 s, unchanged.
- Nothing on the open path can hang forever any more. Gateway requests —
  the route probe, and the SDP exchange for both watching (WHEP) and
  broadcasting (WHIP, `MebiusBroadcaster.start`) — give up after 15 s and are
  aborted, closing the socket. The HLS player's `initialize()` gives up after
  20 s and the FLV player's after 15 s, and the player is disposed at once,
  even if its open never completes. Each then moves on to the next route. An
  answer that still arrives late is cleaned up: the probe's connection is
  closed and a session the gateway created is deleted. A malformed gateway
  URL now reports `CONNECTION_FAILED` instead of `UNKNOWN`.

## 0.6.0

- Quality selection for streams with a rendition ladder (1080p/720p/540p/480p
  at 60 fps, video 6000/3000/2000/1300 kbps).
  `MebiusPlayer.qualities`, `setQuality("auto" | id)`, `setMaxQuality(height)`,
  `setAllowedQualities(ids)`, and the `qualitiesChanged` / `qualityChanged`
  (`MebiusQualityChange`) streams — the same names as the web, Android and iOS
  SDKs. Deliveries now read an optional `renditions` list
  (`MebiusDelivery.renditions`, `MebiusQuality`).
- Auto on a laddered stream plays the `wide` master playlist, so ExoPlayer and
  AVPlayer adapt between rungs natively; on Android that is HLS first, with
  the `fast` (FLV) route kept behind it as a fallback. `setAllowedQualities`
  limits that adaptation (the master is requested with `q=<ids>`), e.g.
  `['1080p', '720p']` on mobile. `setMaxQuality` makes auto play the highest
  allowed rung at or under the cap.
- A manual pick reopens the player on that rung — FLV first on Android —
  keeping the volume, and overrides the cap. A rung that will not open falls
  back to auto, reported as `auto: true`.
- Choices made while a route is still opening are applied once it lands
  (latest wins) instead of opening a second route beside it, and
  `qualityChanged` reports what was actually opened. An open still in flight
  when `stop()` runs is retired: it disposes what it made and can no longer
  replace the session that follows.
- `qualities` is empty and `setQuality` a no-op in `lowLatency` mode, whose
  fallback routes keep the 0.5.1 order and URLs.
- Streams without `renditions` behave exactly as in 0.5.1: `qualities` is
  empty and route selection is unchanged.

## 0.5.1

- Android no longer reopens a healthy `fast` (HTTP-FLV) route every ~14 s.
  media3 reports a live progressive stream's playhead as a constant (1 ms)
  while the picture moves, so the stall detector — which watched the playhead
  — declared every FLV session frozen ten seconds in and reopened it, and the
  viewer saw "reconnecting" on a fast connection. On FLV the detector now
  watches the buffered end, which moves while media arrives and stops when the
  route dies. HLS still uses the playhead.

## 0.5.0

- Android plays the buffered `fast` route (HTTP-FLV), the route the web SDK
  plays through flv.js: a few seconds behind live instead of the ten-plus of
  CDN HLS. The gateway lists it first, so it is tried first; `wide`, `local`
  and the origin playlist stay the fallbacks, in that order. Android's player
  (media3) demuxes FLV natively and plays the live response as a progressive
  stream. iOS keeps `wide`: AVPlayer has no FLV support.
- The route probe reads only the status line. It downloaded the whole body,
  which on a live FLV route never ends; it now closes the connection after
  the headers, for every route.
- Android viewers get a picture on the CDN route. Delivery paths such as
  `/d/wide/{id}` have no `.m3u8` extension, and the Android player picks the
  container from the URL, so it opened the HLS playlist as a progressive file
  and failed with `UnrecognizedInputFormatException` on every route. The
  player is now told the stream is HLS. iOS was unaffected (AVPlayer reads the
  response's content type).
- `Mebius.connect(...).createPlayer()` no longer throws `NOT_CONNECTED`. The
  client was marked connected on a microtask, so creating a player in the same
  synchronous block as `connect` — the README's own example — failed. The client
  is connected when `connect` returns, as on Android; the `connected` event is
  still delivered on a microtask so a listener attached right after `connect`
  hears it.

## 0.4.0

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
