# Mebius Client SDK — Canonical API Contract

Semua platform WAJIB ekspos API surface yang identik (nama method & event sama).
Bahasa beda (Dart/Swift/Kotlin/TS), tapi kontraknya sama persis.

## Init & Connect
- Mebius.init({ appId, gateway })   // gateway = signaling endpoint Mebius, BUKAN MediaMTX
- client = Mebius.connect({ token }) // token short-lived dari backend, secret ga pernah di client

## Broadcaster (publisher)
- broadcaster = client.createBroadcaster({ video, audio })
- broadcaster.start(streamId) / .stop()
- broadcaster.switchCamera() / .setMicEnabled(bool) / .setCameraEnabled(bool)

## Player (viewer)
- player = client.createPlayer({ mode: "low-latency" | "scale" })
- player.play(streamId, viewTarget) / .stop() / .setVolume(0..1)

## Events
- client.on("connected" | "disconnected" | "error", cb)
- broadcaster.on("started" | "stopped" | "stats", cb)
- player.on("playing" | "buffering" | "ended" | "stats", cb)

## ATURAN ABSTRAKSI (wajib, tidak boleh dilanggar)
- broadcaster.start  -> internal WHIP ke gateway (HIDDEN)
- player mode low-latency -> WHEP ; mode scale -> HLS (HIDDEN, auto-pilih)
- Semua koneksi lewat `gateway` Mebius. MediaMTX/MediaMTX-URL TIDAK BOLEH muncul
  di public API, log, atau error message.
- Kata "WHIP/WHEP/HLS/MediaMTX/FLV" TIDAK BOLEH bocor ke nama method/param/event publik.
- Error message ke developer harus pakai istilah Mebius sendiri (mis. "MebiusConnectionError"),
  bukan istilah protokol mentah.

## Token & Auth (kontrak dengan backend)
- Client TIDAK PERNAH pegang appSecret.
- Token = JWT short-lived yang di-mint backend dari (appId + appSecret).
- SDK terima token sebagai string lewat Mebius.connect({ token }).
- Kalau token expired -> event "error" dengan code "TOKEN_EXPIRED", app diharapkan refresh token.

## Versioning
- SemVer. Public API stabil per major version.
- Perubahan breaking pada kontrak ini = major bump di SEMUA platform serentak.
