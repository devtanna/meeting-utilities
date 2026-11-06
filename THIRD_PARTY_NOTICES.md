# Third-party notices

Meeting Utility's original source is MIT licensed (see `LICENSE`). It links the following packages at the exact
revisions recorded in `Package.resolved`. Their licenses apply to their code. No source files from these projects
were copied into this repository unless listed under "Adapted code".

## Linked into the app (host process)

| Package | Version / revision | License | Source |
|---|---|---|---|
| GRDB.swift | 7.12.0 | MIT | https://github.com/groue/GRDB.swift |
| Sparkle | 2.10.1 | MIT (with bundled components under their own permissive licenses; see Sparkle's LICENSE) | https://github.com/sparkle-project/Sparkle |
| KeyboardShortcuts | 3.1.0 | MIT | https://github.com/sindresorhus/KeyboardShortcuts |

## Linked into the embedded InferenceService only

| Package | Version / revision | License | Source |
|---|---|---|---|
| mlx-swift | 0.32.3 (19601207e9a0) | MIT | https://github.com/ml-explore/mlx-swift |
| mlx-swift-lm | 3.32.3 (3b339ad6e3b3), FoundationModelsIntegration trait disabled | MIT | https://github.com/ml-explore/mlx-swift-lm |
| mlx-audio-swift | 0.1.7 (6fd938669e45) | MIT | https://github.com/Neywa-Labs/mlx-audio-swift |
| swift-transformers | 1.4.0 (402a8a1105f5) | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-huggingface | 0.13.0 | Apache-2.0 | https://github.com/huggingface/swift-huggingface |
| swift-jinja | 3.0.0 | MIT | https://github.com/huggingface/swift-jinja |
| swift-collections | 1.7.5 | Apache-2.0 with Runtime Library Exception | https://github.com/apple/swift-collections |
| swift-numerics | 1.1.1 | Apache-2.0 with Runtime Library Exception | https://github.com/apple/swift-numerics |
| swift-crypto / swift-asn1 | 4.5.2 / 1.7.4 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-syntax (build-time macro support of mlx-swift-lm) | 603.0.2 | Apache-2.0 with Runtime Library Exception | https://github.com/swiftlang/swift-syntax |
| yyjson | 0.13.0 | MIT | https://github.com/ibireme/yyjson |
| eventsource | 1.6.0 | MIT | https://github.com/mattt/EventSource |

The MLX packages' own bundled third-party code (for example Metal kernels and vendored C++ such as xgrammar) is
covered by the notices inside those packages.

## Reference implementations (behavior only, no code copied)

| Project | Revision | License | Used for |
|---|---|---|---|
| MeetingBar | 93a0071b826c | Apache-2.0 | Provider link detection and EventKit adapter design ideas. No code was copied; if code is adapted later, its notice must be added here. |
| Itsycal | master | MIT | Compact month navigation ideas. |
| Meetily | 07c4dfd45361 | MIT | Capture/source separation ideas and the duplicate-system-audio regression case. |
| Mica | 88428bec5896 | — | Counter-example: unconditional Focus off is deliberately NOT implemented. |
| Boring Notch | main | GPL-3.0 | Behavior reference only. No code copied. |
| AudioCap | 6f609e8ad1b1 | BSD-2-Clause | Core Audio tap setup reference. Private TCC APIs are excluded. |

## Models (downloaded only on request; not shipped in the app)

| Model | Revision | License | Attribution |
|---|---|---|---|
| mlx-community/parakeet-tdt-0.6b-v2 | 8ae155301e23d820d82aa60d24817c900e69e487 | CC-BY-4.0 | Parakeet TDT 0.6B v2 by NVIDIA; MLX conversion by mlx-community. |
| mlx-community/Qwen3-4B-Instruct-2507-4bit | 50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b | Apache-2.0 | Qwen3-4B-Instruct-2507 by the Qwen team (Alibaba Cloud); 4-bit MLX conversion by mlx-community. |
