# Releasing

A release is a tagged commit. GitHub Actions builds, tests and packs it and attaches the result to a **draft** release; a person reads the draft and publishes it. Nothing here signs with an Apple account or publishes by itself. Releases are signed ad hoc and are **not notarised** (ADR-010; confirmed for 1.1.0 on 2026-10-09), so the release notes and the read-me must say how to approve the first opening.

## Steps

1. **Check it works.** Go through `docs/TESTING.md` on Apple silicon and, per ADR-002, on an Intel Mac if one is available (otherwise say so in the release notes).
2. **Set the version.** `Sources/Engine/Engine.swift` (`Engine.version`) is the single source; the build reads it back. Follow semantic versioning.
3. **Write the changelog.** In `CHANGELOG.md` rename the Unreleased heading to `## [X.Y.Z] - YYYY-MM-DD`. That text becomes the release notes.
4. **Commit, tag, push.** A release prepared on its own branch (`heatbox/…`) is merged into `main` first, once its pull request's CI run is green; without a pull request, run CI on the branch by hand (Actions > CI > Run workflow), which also builds the universal app and checks that it launches.
   ```
   git commit -am "Release X.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```
5. **Watch the Release workflow.** A tag push starts it on a GitHub-hosted macOS runner (`macos-26`), which uses paid macOS minutes. It refuses if the tag and `Engine.version` disagree or the changelog has no section for the version, runs lint and every test, and runs `scripts/package.sh`. While the account's minutes are exhausted, build the release locally instead: run `scripts/package.sh` on the tagged commit, then attach `dist/HeatBox-X.Y.Z-macos-universal.zip` and its `.sha256` to a draft release by hand (`gh release create vX.Y.Z <files> --draft --title "HeatBox X.Y.Z" --notes-file <notes> --verify-tag`).
6. **Read the draft** on the Releases page: `HeatBox-X.Y.Z-macos-universal.zip` and its `.sha256`. Download the zip, check the checksum, open it on a clean Mac, then publish.

`scripts/package.sh` can also be run by hand; it leaves the zip and checksum in `dist/`.

## What is in the zip

The app, `Read Me First.txt`, `LICENSE.txt` and `Licences and Notices.txt` (yt-dlp, FFmpeg and Deno are not in the zip; the app installs them on request). The packaging guard refuses a folder that holds a sign-in file, key, environment file, version-control data, database or settings file.

## The new-version notice

The app asks for a notice file only if `UPDATE_NOTICE_URL` was set when it was built. Keep a small JSON file `{ "version": "X.Y.Z", "url": "<releases page>", "note": "" }` somewhere readable without signing in, and set the repository variable `UPDATE_NOTICE_URL` to its `https` address. It needs a public location; while the repository is private leave the variable unset and the app makes no check at all.

## Signing (switch for later, ADR-010)

Releases are ad-hoc signed. With a paid Apple Developer account: add the certificate and notarisation credentials as repository secrets, replace the `codesign --sign -` line in `scripts/build.sh` with the Developer ID identity and hardened-runtime flags, and submit the zip with `notarytool` before attaching it. Only then can a real in-app updater be considered.

## The tool lock

`tools.lock.json` pins each tool the app installs: address, size and SHA-256 for each chip. `scripts/check-tool-lock.sh` downloads every file and checks it; the "Tool lock" workflow runs it every Monday, on request (Actions > Tool lock > Run workflow) and on pull requests that touch the lock. A red run means a builder moved or replaced a file, and "Install the Programs" is broken for everyone until the lock points at a file that exists. **Do not change a fingerprint to match a file that changed under the same address** without finding out why it changed: that is exactly the case the fingerprint is there to catch. Moving to a newer release is the usual fix: new address, size and fingerprint for both chips, `Sources/Engine/Tools/ToolLockData.swift` kept equal (a test compares them), and `Resources/NOTICES.txt` checked.

## Going public (not done; each step waits for the maintainer's word)

The repository is private. 1.1.0 is prepared for a public release, and these are the steps that visibility needs, in order:

1. **Read what becomes visible.** The whole history, every issue, every workflow log and the 1.0.0 release (titled and named Studio x Phobos). The history was rewritten for 1.1.0 as a fresh two-commit history under the GitHub no-reply address, so no personal address is in it. Read it once more on the day, and check the 1.0.0 release.
2. **Make it public** (Settings > General > Danger Zone, or `gh repo edit vDeimos/HeatBox --visibility public --accept-visibility-change-consequences`).
3. **Switch on, under Settings > Code security:** private vulnerability reporting (`SECURITY.md` points at it), secret scanning with push protection, Dependabot alerts. `.github/dependabot.yml` is already there for the actions. None of these three can be switched on usefully while the repository is private on a free account.
4. **Point the issue chooser at the report form:** in `.github/ISSUE_TEMPLATE/config.yml` change the security link from the maintainer's profile to `https://github.com/<owner>/<repository>/security/advisories/new`.
5. **Protect `main`:** require the `build-and-test` check and forbid force pushes (free on a public repository).
6. **Set the description and topics:**
   ```
   gh repo edit vDeimos/HeatBox --description "HeatBox: save videos and audio from the web on your Mac, keep a library, convert files" \
     --add-topic macos --add-topic swift --add-topic swiftui --add-topic yt-dlp --add-topic ffmpeg --add-topic video-downloader --add-topic youtube-downloader
   ```
   Switch on Discussions if wanted.
7. **The build attestation** in the Release workflow starts by itself on a public repository; the next release has one.
8. **The new-version notice** needs a public address: see "The new-version notice" above. Until it is set, the app never looks.

## Names that stay

The app is HeatBox from 1.1.0, in the repository `vDeimos/HeatBox`. The bundle identifier, the `studioxphobos://` scheme, the data folder and the `StudioXPhobos` executable are kept on purpose (ADR-011), so existing installs keep their data and their browser buttons. `studio-x-phobos.presets` inside exported preset files is a file format's name and stays too. The 1.0.0 release keeps its Studio x Phobos title and zip names as history.

## Licences

Before each release check `tools.lock.json` against `Resources/NOTICES.txt`: a new tool, a new builder or a changed licence needs the notice updated in the same commit.
