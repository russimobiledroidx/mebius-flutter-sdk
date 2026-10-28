## 0.1.0

- First release.
- `MebiusScreenAgent`: enroll a device, keep it online over the agent
  event stream (reconnecting with backoff), publish the primary display
  when a session starts, and apply remote mouse and keyboard input in
  `control` sessions (CoreGraphics on macOS, `SendInput` on Windows).
  Releases anything still held when a session ends.
- `MebiusSecureCredentialStore`: device credentials in the OS keychain.
- `MebiusScreenViewer` and `MebiusScreenView`: watch a session (with TURN
  servers when the engine provides them) and drive it, with batched input
  and token renewal.
