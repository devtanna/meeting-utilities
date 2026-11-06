# Performance report (Release build, outside the debugger)

Host: Mac17,16, 64 GB, macOS 27.0.1 — the only machine measured. M1 16 GB and 8 GB lower-bound measurements are
open items (plan). Synthetic calendar (`-UseFakeCalendar YES`, 7 events/day), no conferencing app running.

| §21.2 target | Result | Status |
|---|---|---|
| Idle host memory ≤ 100 MiB | 60 MB phys_footprint after settling | ✅ |
| Idle CPU < 0.5 % of a core (10 min avg) | 0.03 s CPU over 120 s steady state ≈ 0.03 % (2-min window; 10-min trace still to run) | ✅ (short window) |
| Idle wakeups ≤ 1/s | `top` idle wakeups: 8 in a 60 s sample ≈ 0.13/s | ✅ |
| Idle AI: no inference process / weights / capture / display loop | No InferenceService process at idle; service exits after 30 s idle | ✅ |
| Speech working set < 5 GiB | Service peak ≈ 3.6 GiB MLX / 4.1 GB footprint (bench incl. both models sequentially) | ✅ |
| Summary working set < 4.5 GiB | Service peak footprint 4.19 GB during 8-section summary | ✅ (close) |
| Sustained transcription, no growing backlog | 600 s audio in 2.6 s compute (RTF 0.004 warm, 0.4 cold first chunk) | ✅ |
| Summary latency < 120 s for 60-min transcript | 78.9 s (8 sections + overview), model load 0.12–0.3 s warm | ✅ |
| App bundle < 120 MiB | 67 MB | ✅ |
| Compressed download < 60 MiB | DMG 19 MB, zip 16 MB | ✅ |
| Host memory during model download/verify | 2.5 GB before fix (autorelease accumulation in SHA-256); fixed with an autorelease pool | ✅ fixed |
| Warm agenda p95 < 150 ms, note open p95 < 100 ms, cold launch < 1 s | Signposts `agenda.open`, `note.open`, `launch` are in place; not yet collected with Instruments | ⏳ |
| PCM/IPC ≤ 32 MiB | Enforced by `AudioBudget` (rings 2×3.8 MB + queues + in-flight); live capture trace pending owner test | ⏳ |

Reproduce: `inference-bench <parakeet> <qwen> <pcm> 600` (Packages/InferenceEngines, Release) and
`MeetingUtility -UseFakeCalendar YES -SelfTest report.json -SelfTestPCM fixture.pcm -SelfTestLong YES`.
