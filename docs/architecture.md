# Architecture

```
EventKit ─▶ CalendarRepository actor ─▶ CalendarEngine (snapshots, freshness, generation)
                                         │            │
                                         ▼            ▼
                         MeetingStore.resolveAll   AutomationScheduler ─▶ NotificationController (UNUserNotificationCenter)
                         (identity → UUIDs)         (one timer)       └▶ MeetingCoordinator.join (auto)
                                         │
Agenda (popover or notch panel) ─────────┴──▶ MeetingCoordinator ─▶ LinkOpener (NSWorkspace)
                                                     │       ├─▶ FocusShortcutRunner (/usr/bin/shortcuts)
                                                     │       └─▶ CaptureController (mic: AVAudioEngine; system: Core Audio tap)
                                                     │                 │ ring buffers → resampler → VAD chunks (memory only)
                                                     ▼                 ▼
                                               InferenceClient ══ NSXPCConnection (versioned, Data envelopes) ══▶ InferenceService.xpc
                                                     │                                                         Parakeet (MLXAudioSTT)
                                                     ▼                                                         Qwen 4B (MLXLLM)
                                        MeetingStore (GRDB, single writer) ◀── transcript segments / summary versions
                                                     ▲
                    NotebookView · HistoryView · TalktrackPanel · SettingsView (SwiftUI, AppKit windows/panels)
```

## Module map (spec §4.2 → code)

| Spec module | Code |
|---|---|
| AppShell | `App/Sources/Core` (AppDelegate, AppServices, WindowRouter, PresentationManager in `Presentation/`) |
| AgendaFeature | `App/Sources/Agenda/AgendaView.swift`, `MeetingCore/Agenda.swift` |
| NotebookFeature | `App/Sources/Notebook` |
| HistoryFeature | `App/Sources/History` |
| TalktrackFeature | `App/Sources/Talktrack`, `MeetingCore/Teleprompter.swift` |
| CalendarCore | `App/Sources/Calendar`, `MeetingCore/CalendarModels.swift` |
| MeetingIdentity | `MeetingData/MeetingStore.swift` (resolve, repair/undo) |
| MeetingProviders | `MeetingCore/MeetingProviders.swift`, `App/Sources/Automation/LinkOpener.swift` |
| MeetingSession | `MeetingCore/Session.swift`, `App/Sources/Session/MeetingCoordinator.swift` |
| Automation | `MeetingCore/AutoJoin.swift`, `App/Sources/Automation/AutomationScheduler.swift`, `FocusShortcutRunner.swift` |
| NotificationCore | `MeetingCore/Reminders.swift`, `App/Sources/Automation/NotificationController.swift` |
| AudioCapture | `MeetingAudio` |
| InferenceClient | `App/Sources/Inference/InferenceClient.swift`, `InferenceProtocol` |
| InferenceService | `InferenceService/main.swift`, `InferenceEngines` |
| ModelCatalog | `App/Resources/ModelCatalog.json`, `MeetingCore/ModelCatalog.swift`, `App/Sources/Models/ModelManager.swift` |
| Persistence | `MeetingData` |
| QuarterCore | `MeetingCore/Quarter.swift` |
| UpdateCore | `App/Sources/Core/UpdateController.swift` |
| Diagnostics | `MeetingCore/Diagnostics.swift`, `SupportReport` in `SettingsView.swift` |

## Concurrency
- UI and AppKit on `@MainActor`. `EventKitCalendarRepository` is an actor owning `EKEventStore`; only `Sendable`
  snapshots leave it. GRDB `DatabasePool` serializes writes; reads are concurrent.
- Audio callbacks only copy into preallocated lock-free `SPSCFloatRing`s; conversion, VAD and chunking run on a
  serial processing queue at 10 Hz while capturing.
- Every capture session has a UUID and generation; late XPC results from replaced sessions are dropped; the service
  rejects duplicate/old sequence numbers.
- The inference service is created lazily, runs one heavy job at a time on a serial queue, unloads models after
  30 s idle and exits when the host invalidates its idle connection.
