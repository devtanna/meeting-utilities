# Security policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/devtanna/meeting-utilities/security/advisories/new)
and include:

- what the problem is and what it allows an attacker to do
- steps to reproduce, or a proof of concept
- the app version (**Settings › About**) and your macOS version

You should get a reply within a few days. Once a fix ships, the advisory is published and you are credited unless
you'd rather not be.

## Scope

Particularly relevant areas:

- anything that could send meeting content (audio, transcripts, notes, calendar data) off the Mac
- audio reaching disk
- the model downloader (host allow-list, checksum verification) and the XPC boundary to `InferenceService`
- update signing and verification (Sparkle EdDSA)
