# Engineering decisions

Recorded per spec §1 ("may tune a numerical parameter after measuring it, but must record the reason") and plan rules.
Confirmed product behaviour (§1 table) was not changed.

| # | Decision | Reason |
|---|---|---|
| D1 | Two local packages (`MeetingKit` with four library targets, `InferenceEngines`) instead of six. SwiftUI features live in the app target. | §4.2 asks for few packages; UI depends on app services, so a separate UI package added only indirection. MLX stays isolated in `InferenceEngines` (service only). |
| D2 | Ad-hoc code signing by default; Apple Development team optional via `Config/Identity.xcconfig`. Hardened Runtime is enabled only with a team. | No signing identity exists on the build Mac (plan open item). Ad-hoc + Hardened Runtime breaks nested framework library validation. Consequence: privacy permissions are re-requested after each new build. |
| D3 | Sparkle starts only when an EdDSA public key and an HTTPS feed (not `*.invalid`) are configured. | The update feed domain is an open item; starting Sparkle against a placeholder would show errors to testers. Restart deferral and no system profiling are implemented and active once configured. |
| D4 | Tap-only private aggregate device (no physical output sub-device). Reads only the tap's buffer when more buffers appear. | Avoids the Meetily duplicate-system-audio regression (§13.2) by construction. |
| D5 | Capture ring buffers are 10 s per source; the 60 s backlog limit is enforced on the utterance queue. | Rings drain every 100 ms, so 10 s is ample; keeps the total PCM/IPC footprint well under the 32 MiB budget (2×3.8 MB rings + ≤2×3.8 MB queued + in-flight). |
| D6 | VAD minimum utterance (300 ms) is measured excluding the 250 ms pre-roll. | Otherwise a 100 ms click plus pre-roll and tail would pass as speech. |
| D7 | Summary sectioning uses a conservative 3.2 chars/token estimate in the host. | Keeps the host free of tokenizer/MLX code; with a 1,200-token response and 700-token prompt overhead the section budget stays inside 8,192 tokens. |
| D8 | Summary temperature 0.2, top-p 0.9, repetition penalty 1.05; one local JSON repair attempt (bracket closing, trailing commas). | Deterministic-leaning output for structured JSON; §22.2 allows one bounded repair. |
| D9 | Validator drops decisions/action items with no valid citation and normalises "unknown/N/A/TBD" owners/dates to null. | §14.5: unsupported items must not be presented as fact. |
| D10 | Duplicate calendar copies (same external ID, both local IDs present in one fetch) get separate notebooks; a third copy is "ambiguous" with suggestions. Unique external-ID matches with a vanished local ID are treated as identifier churn. | §7.2 steps 3 and 5, §7.3 duplicate-copy invariant. |
| D11 | Recovery revisions are snapshotted at most once per 60 s per document (latest 20 kept) rather than on every 300 ms save. | Bounded write volume; conflicts always snapshot the overwritten text. |
| D12 | Inference service validates the host with `setCodeSigningRequirement("identifier \"<bundle id>\"")`. | Works for ad-hoc and team-signed builds; tighten to team/anchor once Developer ID exists. |
| D13 | `-UseFakeCalendar` runs use a separate database folder and preferences suite. | Tests and screenshots must never touch real notes (§23.1). |
| D14 | Model weights are shared between normal and synthetic runs (`Application Support/<bundle>/Models`). | Weights are not meeting content; avoids duplicate 4.7 GB downloads. |
| D15 | Parakeet is called with `chunkDuration 1200` so the library never re-chunks; the app owns chunking (≤12 s + ≤1 s overlap). | §14.1 "configure one owner of chunking". |
| D16 | MLX GPU cache limit 512 MB and `clearCache()` after each chunk/generation. | Keeps loaded-but-idle memory bounded; measured peak stays within the §21.2 working-set aims. |
