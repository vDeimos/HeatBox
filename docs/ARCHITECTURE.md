# Architecture

This page is the short map of the code.

```
Sources/Engine   Foundation + SQLite only. Decides everything: names, arguments, states, messages, paths.
Sources/App      SwiftUI + AppKit. Draws engine state and forwards intent. Decides nothing.
Tests/           Swift Testing: unit and golden tests, real-tool integration tests, a queue harness.
```

Rules that shape the code (plan Section 3.2): the engine never imports a UI framework; planners return values and runners execute them; one `ProcessRunner` starts every tool from a fixed path with an environment built from scratch, in its own process group; every yt-dlp call carries `--ignore-config` and `--`; each job writes only in its own workspace and the engine moves finished files out; settings are defaults, a download's tweaks do not persist; all user-facing text lives in `Messages`; views hold copies of engine snapshots and never touch the filesystem.

Data flow of a download: Download screen (`DownloadDraft`) → `JobRequest` → `JobQueue` (actor) → `ToolJobWorker` → look-up (`Probe`) → comment chapters → yt-dlp (`YtdlpCommand`) → per file: retag, loudness, re-encode (`PostProcess`) → `Delivery` → `LibraryRepository` → published back to the Queue and Library screens.

Persistence (ADR-007): versioned JSON for settings, presets, queue and following; SQLite for the Library and transcripts; all under `~/Library/Application Support/Studio x Phobos`. Tools live in its `bin/`, installed by `ToolProvisioner` from `tools.lock.json` (ADR-003).

Build: `scripts/build.sh` assembles and ad-hoc signs the `.app` (ADR-010); `scripts/package.sh` packs the release zip; CI (`.github/workflows/ci.yml`) lints, builds and tests each ready pull request, and also builds the universal app and launches it on `main` and on request (`scripts/check.sh` runs the same locally; docs/TESTING.md); `release.yml` runs on a tag.
