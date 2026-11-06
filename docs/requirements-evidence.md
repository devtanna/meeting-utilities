# Requirements evidence (R01–R18)

✅ implemented and verified here · 🧪 implemented, owner/hardware verification pending · ⛔ blocked by an open item

| ID | Status | Evidence |
|---|---|---|
| R01 Native Apple Silicon, low overhead | ✅ / ⛔ signed | arm64-only Release, 60 MB idle, ≈0 % idle CPU (`performance-report.md`). Developer ID signing blocked. |
| R02 Menu-bar / notch switch | ✅ / 🧪 | `PresentationManager`, `NotchPanelController`, `NotchGeometry` tests. Notched MacBook check open. |
| R03 Agenda matches reference | ✅ | `-RenderSnapshots` agenda PNGs with synthetic events (actions, Today/Tomorrow, compact rows, Settings bottom). |
| R04 Selected calendars, live updates | ✅ / 🧪 | `CalendarEngine` (EKEventStoreChanged 300 ms debounce, generations, stale state), fake repository; real permission flows by owner. |
| R05 Meet / Teams / Zoom | ✅ / 🧪 | Link fixture tests (`LinkTests`); real provider smoke checks by owner. |
| R06 Series notebooks + history | ✅ | Identity + persistence tests (rename, reschedule, detached, churn, duplicates, repair/undo, restart). |
| R07 Floating Talktrack | ✅ / 🧪 | `TalktrackPanel`, refresh-rate-independent scrolling test; screen-share behaviour by owner. |
| R08 Optional DND | 🧪 | `FocusShortcutRunner`, parsing tests, setup guide; Shortcut outcomes on 27/15 by owner. |
| R09 Optional auto join | ✅ | `AutoJoinTests` (disabled, override, declined, conflict, reschedule, reserved, ambiguous crash, missed start) + unique ledger test. |
| R10 Reminders 5/10/15 | ✅ / 🧪 | `ReminderTests` (stable IDs, horizon/cap, reconcile); live delivery by owner. |
| R11 Parakeet download | ✅ | App downloader installed + verified it (54 s) and transcribed through XPC (`SelfTest`). Network-off run by owner. |
| R12 Qwen 4B download | ✅ | Same; schema-valid summaries incl. 60-min transcript in 79 s. |
| R13 Auto-transcribe (+summary) controls | ✅ | `AutomationMode` consistency tests; preflight tests; settings toggles. |
| R14 Transcripts/summaries by occurrence | ✅ | Segment idempotency, cascade, export with gaps, month badges tests. |
| R15 Quarter tracker | ✅ | All §17.3 rows, Berlin DST, TZ change, non-Gregorian locale tests. |
| R16 Seamless updates | ⛔ | Sparkle integrated with restart deferral and no profiling; feed/keys/Developer ID open. |
| R17 Local content | ✅ / 🧪 | No networking in service; local-only loaders; `audit-no-audio-files.sh` to run during a real capture. |
| R18 MIT + entitlement interface | ✅ | `LICENSE`, `THIRD_PARTY_NOTICES.md`, `FeatureEntitlementProvider`. |
