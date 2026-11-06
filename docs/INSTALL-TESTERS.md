# Installing Meeting Utility on a test Mac

Requirements: an Apple Silicon Mac (M1 or later) running macOS 15 or newer. 16 GB memory is recommended for
transcription + summaries; everything else works on any Apple Silicon Mac.

## 1. Copy and install

1. Copy `MeetingUtility-<version>-arm64.dmg` to the Mac (AirDrop, USB stick, shared folder…).
2. Open the DMG and drag **MeetingUtility** onto **Applications**.
3. Eject the DMG.

## 2. First launch (this test build is not notarized yet)

This build is signed for development only (no Apple Developer ID yet), so macOS blocks the first launch:

1. Double-click **MeetingUtility** in Applications. macOS says it can't verify the app — click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down to the message about MeetingUtility and click
   **Open Anyway**, then confirm with your password/Touch ID.
3. The app starts. It has no Dock icon: look for the calendar icon in the menu bar.

You only need to do this once per installed copy. After installing a newer test build, repeat step 2 and expect
macOS to ask for calendar/microphone permissions again (a development-signed build has a new identity each time).

## 3. Setup assistant

The setup assistant opens automatically. You can press **Finish Setup** as soon as your calendars are selected.

| Step | What to expect |
|---|---|
| Presentation | Menu bar or Notch. The notch mode shows a small capsule on Macs without a notch. |
| Calendars | macOS asks for "full access". The app only reads events. Choose which calendars to show. |
| Reminders | Turning them on asks for notification permission. 10 minutes is preselected; 5/10/15 can be combined. |
| Auto join | Off by default. It only opens the link at the start time. |
| Do Not Disturb | Optional; requires creating one Shortcut (Settings › Focus › Open Setup Guide). |
| Transcription | Download the speech model (2.5 GB), test the microphone and system audio (each shows a macOS prompt). |
| Summaries | Download the summary model (2.3 GB). |

## 4. What to try

- **Agenda:** click the menu-bar item, use ↑/↓ and Return to join, ⌘O for notes, right-click a meeting for more.
- **Global shortcuts:** none by default; record your own in Settings › General (agenda, join, notes, Talktrack, hide Talktrack, Settings).
- **Notes:** open notes for a recurring meeting; series notes are shared, dated notes are per occurrence. Check that
  next week's occurrence shows the earlier date in the history list.
- **Talktrack:** Notebook › Talktrack tab › Open Teleprompter. Space starts/pauses scrolling.
- **Transcription:** after the models are installed and both audio tests pass, join a meeting from the agenda with
  *Auto transcribe* on, or right-click a meeting › Start Transcription. Stop or extend from the agenda's red banner.
  Summaries appear in the notebook's Summary tab after the transcript is saved.
- **Quarter tracker:** the chip in the agenda (click for details); Settings › General › Compact status › Quarter.

## 5. Reporting problems

Settings › Diagnostics › Preview Support Report shows a redacted report (no meeting titles, notes, transcripts or
links). Save it and send it along with a description of what happened.

## Uninstall

Quit from the agenda (Quit Meeting Utility), delete the app from Applications, and optionally delete
`~/Library/Application Support/com.devtanna.meetingutils` (notes, transcripts and downloaded models).
Settings › Data › Erase All Data does the same from inside the app.
