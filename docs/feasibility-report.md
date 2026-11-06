# Feasibility report (Phase A)

| Step | Result | Go? |
|---|---|---|
| A1 dependency graph | Exact pins resolve and build for macOS 15.0 with mlx-swift-lm traits disabled; Package.resolved committed. Metal toolchain had to be downloaded (`xcodebuild -downloadComponent MetalToolchain`). | Go |
| A2 XPC + Metal | `InferenceService.xpc` embedded; `default.metallib` bundled in the service only; ping + MLX op run in a separate process (Debug and Release). | Go |
| A3 Parakeet | Pinned revision 8ae15530…, SHA-256s in catalog; `fromDirectory` + in-memory 16 kHz PCM; load 0.2–0.6 s; RTF 0.004–0.4; exact transcript of a synthetic fixture; no audio file used by the app. | Go |
| A4 Qwen | Pinned revision 50d42775…; local tokenizer + chat template; schema-valid JSON; injection text not followed; owner only when stated. | Go |
| A5 two-source capture | Implemented (AVAudioEngine + tap-only private aggregate, reverse-order cleanup, own-process exclusion). **Not yet exercised on hardware**: needs the owner to grant microphone + audio-capture prompts and run Settings › Transcription tests, speakers and headphones. | Pending owner test |
| A6 Focus Shortcut | CLI flags verified (`run <id> --input-path --output-path --output-type`, `list --show-identifiers`). Shortcut must be built by the owner from `Shortcuts/FocusShortcutSetup.md` and tested on macOS 27 and 15. | Pending owner test |
| A7 notch panel | Geometry from safe-area insets/auxiliary areas, unit-tested with notched and external-display metrics; no-notch capsule path runs here. Notched hardware check open. | Go (fallback), notch open |
| A8 measurements | See `performance-report.md`. | Go |

No spec runtime was replaced (no Python/Node/Ollama/HTTP/FFmpeg/virtual drivers).
