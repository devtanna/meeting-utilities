# Contributing to meetingutils

Thanks for helping. This guide covers how to report problems, propose changes and get a pull request merged.

## Reporting bugs

Open an [issue](https://github.com/devtanna/meeting-utilities/issues/new/choose) using the bug template. The most
useful thing to attach is a support report: **Settings › Diagnostics › Preview Support Report**. It is redacted and
contains no meeting titles, notes, transcripts or links. Please check it anyway before you post it.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Proposing features

Open a feature request first for anything bigger than a small fix, so we can agree on the approach before you spend
time on it. meetingutils has a few firm principles, and proposals that conflict with them are unlikely to be accepted:

- **Local only.** No accounts, telemetry, analytics, cloud AI or sync. Network access is limited to model downloads and
  update checks.
- **No audio on disk.** Audio stays in memory buffers. `scripts/audit-no-audio-files.sh` enforces this.
- **MLX stays out of the app process.** Only `InferenceService` links MLX. The release script checks this.
- **Quiet by default.** New sounds, notifications or automations are opt-in.

## Development setup

See [Build from source](README.md#build-from-source). In short:

```sh
cp Config/Identity.example.xcconfig Config/Identity.xcconfig
scripts/bootstrap.sh
make dev-fake     # synthetic calendar and sandbox database, so your real notes are never touched
```

Use `make dev-fake` while developing. To check UI changes without clicking through the app, render snapshots:

```sh
build/dd/Build/Products/Debug/MeetingUtility.app/Contents/MacOS/MeetingUtility \
  -UseFakeCalendar YES -RenderSnapshots /path/to/out -QuitAfterSnapshots YES
```

## Pull requests

1. Fork, then branch from `main`.
2. Keep each PR focused on one change. Put pure logic (dates, scheduling, parsing) in `Packages/MeetingKit/MeetingCore`
   and add tests next to the existing ones.
3. Run `make test` and a Debug build (`make build`). Both must pass.
4. For UI changes, include before and after screenshots, in light and dark mode where relevant.
5. Record notable design choices in [docs/decisions.md](docs/decisions.md).
6. Fill in the PR template.

### Code style

- Swift 6 with strict concurrency. UI and app state are `@MainActor`.
- Follow the patterns in the surrounding code. Settings rows use the components in `App/Sources/Settings/DesignSystem.swift`.
- Comments explain *why*, not what.
- Every control needs an accessibility label, and features must work from the keyboard.

### Dependencies

New Swift packages need a good reason. Pin them exactly in `Package.resolved` and add them to
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with their license.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
