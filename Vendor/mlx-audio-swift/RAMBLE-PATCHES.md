# mlx-audio-swift (vendored)

Upstream: https://github.com/Blaizzy/mlx-audio-swift, tag 0.1.3 (d302a5c6080d2bb97bae38c7418f82abb76013b6), MIT licence.
Removed: `.git`, `Examples`, `Tests/media`.

Ramble uses only `MLXAudioSTT` (Qwen3-ASR) and `MLXAudioCore`.

## Patches

- `Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift`: Xcode 27 makes capturing a
  non-Sendable value in a `@Sendable` closure an error. The two `compile { }` closures now
  capture `nonisolated(unsafe)` copies. Behaviour is unchanged. Parakeet isn't used by Ramble.

- `Package.swift`: depends on `../mlx-swift-lm` (Ramble's patched copy) instead of the GitHub URL;
  both had the identity `mlx-swift-lm`, which SwiftPM warns will become an error.

When updating, check whether upstream fixed these, then re-apply or drop.
