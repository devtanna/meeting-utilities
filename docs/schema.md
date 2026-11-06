# Database schema and migrations

Location: `~/Library/Application Support/<bundle-id>/store.sqlite` (+ `-wal`, `-shm`), directory 0700, files 0600.
WAL journal, `synchronous=FULL`, foreign keys on. One writer (GRDB `DatabasePool`).

| Migration | Contents |
|---|---|
| `v1-initial-schema` | The §18.3 reference schema verbatim (notebooks, calendar_bindings, calendar_identity_aliases, occurrences, documents, document_revisions, meeting_sessions with the `one_active_capture` partial unique index, transcript_segments, summary_versions, automatic_actions, durable_jobs, scoped_settings, FTS5 `search_documents`). |
| `v2-repairs-and-meta` | `identity_repairs` (reversible "Link to existing notebook" records) and `app_meta` (`schema_version`, `min_compatible_schema`). |

Rules implemented in `MeetingData`:
- Before migrating an existing database, a consistent copy is written with the SQLite backup API to `Backups/`.
- An app refuses to open a database whose `min_compatible_schema` is newer than it supports (no automatic downgrade).
- FTS rows are written in the same transaction as content and deleted explicitly on content/notebook deletion.
- Ownership is checked on writes (occurrence documents must belong to the occurrence's notebook).
- Session state changes go through `CaptureState.canTransition`.
- Erase-all removes the database, WAL/SHM and `Backups/`; model files are a separate choice.

Scoped settings keys: `autoJoin` (Bool) and `linkOverride` (`{url, scope}`) at scope `occurrence` or `notebook`.
