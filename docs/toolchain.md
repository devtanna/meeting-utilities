# Toolchain (verified 5 Nov 2026)

| Item | Version |
|---|---|
| macOS (build/verification host) | 27.0.1 (26A434), Mac17,16, 64 GB, no notch |
| Xcode | 27.2 (27B52), used via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9), language mode 6 |
| Metal toolchain | 27B47 (`xcodebuild -downloadComponent MetalToolchain`) |
| XcodeGen | 2.46.0 (Homebrew) |
| Deployment target | macOS 15.0, arm64 only |

Package graph (exact pins, see `Package.resolved` and `Packages/InferenceEngines/Package.resolved`):
GRDB 7.12.0 · Sparkle 2.10.1 · KeyboardShortcuts 3.1.0 · mlx-swift 0.32.3 · mlx-swift-lm 3.32.3 (traits: none) ·
mlx-audio-swift 0.1.7 · swift-transformers 1.4.0 (transitive: swift-huggingface 0.13.0, swift-jinja 3.0.0,
swift-collections 1.7.5, swift-numerics 1.1.1, swift-crypto 4.5.2, swift-asn1 1.7.4, swift-syntax 603.0.2 prebuilt,
yyjson 0.13.0, eventsource 1.6.0).

Notes
- SwiftPM's CLI cannot compile Metal; MLX is always built with `xcodebuild` (the app build or the
  `inference-bench` scheme). `swift test` is used only for `Packages/MeetingKit`, which has no MLX dependency.
- The FoundationModelsIntegration trait of mlx-swift-lm is disabled with `traits: []` in
  `Packages/InferenceEngines/Package.swift`; the graph builds for macOS 15.0.
- mlx-audio-swift's debug-only `unsafeFlags` did not block the local-package build in Xcode 27.2.
