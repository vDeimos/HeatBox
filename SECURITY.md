# Security

## Reporting a problem

Please do not open a public issue for a security problem. Use **Report a vulnerability** under this repository's Security tab; if that button is not there, contact the maintainer privately through their GitHub profile ([vDeimos](https://github.com/vDeimos)). Include the app version (Settings > Tools), your macOS version and the steps that show the problem. Only the latest release is supported.

## What the app is trusted with

It runs as an ordinary app under your account, is not sandboxed, and asks for no administrator rights.

| It can | Why |
| --- | --- |
| Run yt-dlp, FFmpeg, ffprobe and Deno | They do the downloading and converting |
| Download those four programs, on request | The Install and Update buttons only; nothing downloads at launch |
| Write to the folders you choose (by default `~/Movies` and `~/Music/HeatBox`) | To save files |
| Read and write `~/Library/Application Support/Studio x Phobos` (the app's name up to 1.0.0; kept so existing installs keep their data) | Its own records, tools and pictures |
| Read one browser's cookies, **only** when you press "Copy my sign-in" | To use your own YouTube sign-in |
| Listen to videos with the Mac's own speech recognition, if you switch it on | Spoken-word search |

## Protections (each is enforced by code and by a test or a lint rule)

- **No shell.** Every tool starts with an argument list from a fixed path; `scripts/lint.sh` fails the build on a shell path. A link, title or file name is one argument.
- **A tool's environment is built from scratch**, not inherited, so shell proxy variables and search paths never reach it.
- **Every yt-dlp call** carries `--ignore-config`, `--` before links, and accepts only `http` and `https` links.
- **Extra arguments are vetted.** Options that run commands, load other configuration or change the app's chosen tools are refused, including abbreviations; imported presets pass the same check.
- **Managed tools are verified.** Each download is checked against a SHA-256 in `tools.lock.json` before it is unpacked, run once, and moved into place; a mismatch installs nothing. Addresses must be `https` and redirects must stay `https`. Update yt-dlp checks the newest release against that release's own published checksums.
- **The link scheme only fills in the Download screen.** `studioxphobos://open?url=…`, dropped links, `.webloc` files and the browser button never start a download.
- **Files are never lost or overwritten.** A taken name gets a number; removal goes to the Trash; conversions write a new file; a re-encode takes its place before the original goes to the Trash.
- **The saved sign-in** is `cookies.txt` with mode 600, only YouTube and Google entries, used only while its switch is on, and excluded by `.gitignore` and by the release packaging guard.
- **The new-version notice** reads one `https` address built into the app, if any, and its button can only open a web page.
- **Private folders.** The app's own folders are created with mode 700.
- **One copy per data folder.** A second copy started on the same data folder shows the first and quits, so two copies never write the same queue and settings.
- **File names fit the disk.** A title is cut between whole characters to a length every disk takes; it can never name a folder, and never leaves its own.
- **No telemetry, no accounts, no server.**

## The supply chain

- Release zips are built by GitHub Actions from a tagged commit with a published SHA-256. On a public repository a build attestation is recorded as well. The workflows' actions are pinned by commit and the runner by its macOS version.
- A weekly workflow downloads every file `tools.lock.json` names and checks it against the lock, so a file that is moved or replaced upstream is noticed.
- Releases are signed ad hoc, **not** with an Apple Developer ID, and not notarised (ADR-010). macOS asks you to approve the first opening in System Settings. Compare the checksum before you do.
- FFmpeg comes from a third-party builder (martin-riedl.de), signed by them, GPL-3.0-or-later. It is pinned and checked by fingerprint, so a changed file is refused, but the fingerprint was taken from that builder's server by the maintainer; the app cannot tell an honest build from a dishonest one that was already published.

## Known limits

- Not sandboxed. Full Disk Access, if you grant it for the sign-in, lets the app read protected files; it uses it only for that.
- Installed tools are verified when installed, not at every launch.
- A force-quit can leave a download's working folder; the next launch cleans or resumes it (nothing runs until you ask).
