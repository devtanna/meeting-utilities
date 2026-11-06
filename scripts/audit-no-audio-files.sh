#!/bin/zsh
# Privacy audit (§13.6, R17). Run while a capture session is active (or right after one):
#   scripts/audit-no-audio-files.sh [seconds]
# 1. Records file-system writes of the app and its inference service with fs_usage (needs sudo).
# 2. Scans the app's data folder and temp directories for audio files.
set -uo pipefail
SECS="${1:-60}"
OUT="$(mktemp -d)/fs_usage.txt"
echo "Tracing writes for ${SECS}s (sudo required)…"
sudo fs_usage -w -f filesys MeetingUtility InferenceService > "$OUT" 2>/dev/null & PID=$!
sleep "$SECS"; sudo kill "$PID" 2>/dev/null
HITS=$(grep -Ei '\.(wav|m4a|caf|aif|aiff|mp3|aac|flac|pcm|raw)\b' "$OUT" | grep -Ei 'open|write|create' || true)
SCAN=$(find "$HOME/Library/Application Support/com.devtanna.meetingutils" "$TMPDIR" /private/var/folders -maxdepth 6 \
        \( -iname '*.wav' -o -iname '*.m4a' -o -iname '*.caf' -o -iname '*.aif*' -o -iname '*.pcm' -o -iname '*.mp3' \) \
        -newermt "-1 day" 2>/dev/null | grep -i meetingutility || true)
if [ -n "$HITS$SCAN" ]; then echo "FAIL: audio file activity found"; echo "$HITS"; echo "$SCAN"; exit 1; fi
echo "PASS: no audio file writes by MeetingUtility/InferenceService; no audio files in app data or temp. Trace: $OUT"
