# Privacy and data flow

| Data | Where it goes |
|---|---|
| Calendar fields | Read-only EventKit access; transient snapshots in memory; occurrence title/time stored with your notes |
| Notes, Talktrack | Local SQLite |
| Microphone / system audio | Bounded in-memory buffers (≤32 MiB) and in-flight XPC messages only — never written to disk |
| Transcripts, summaries | Local SQLite; exports only where you choose |
| Model downloads | Hugging Face/CDN, pinned revision; requests contain no meeting content |
| App updates | Sparkle appcast (once configured); no system profile |
| Diagnostics | Local OSLog with opaque IDs, counts and codes; user-initiated, previewed support report |

No telemetry, analytics, accounts, cloud AI or sync. The SQLite file is ordinary local plaintext (not app-encrypted)
and may be included in OS backups.

Checks
- `scripts/audit-no-audio-files.sh` — fs_usage trace + file scan during capture (needs sudo).
- Offline inference: after models are installed, disable networking and run Settings › Diagnostics › Run Self-Test
  or a transcription; the service has no networking code and loads only local directories.
- Log redaction: `log show --predicate 'subsystem == "com.devtanna.meetingutils"' --last 1h` shows only IDs, counts,
  codes and states (titles, links, notes and transcript text are never logged).
