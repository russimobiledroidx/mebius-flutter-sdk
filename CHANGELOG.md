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
