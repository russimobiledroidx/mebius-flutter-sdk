# Changelog

All notable changes to the `mebius` package are documented here. This project
adheres to [Semantic Versioning](https://semver.org). The public API is stable
within a major version.

## 0.1.0

- Initial release.
- `Mebius.init` / `Mebius.connect` session bootstrap.
- `MebiusClient.createBroadcaster` and `MebiusClient.createPlayer`.
- `MebiusBroadcaster`: `start`, `stop`, `switchCamera`, `setMicEnabled`,
  `setCameraEnabled`, and `started` / `stopped` / `stats` events.
- `MebiusPlayer`: `play`, `stop`, `setVolume`, low-latency and scale modes,
  and `playing` / `buffering` / `ended` / `stats` events.
- `MebiusView` widget for broadcaster preview and player surfaces.
- Stable `MebiusError` codes: `TOKEN_EXPIRED`, `PERMISSION_DENIED`,
  `CONNECTION_FAILED`, `NOT_CONNECTED`, `STREAM_NOT_FOUND`, `UNKNOWN`.
