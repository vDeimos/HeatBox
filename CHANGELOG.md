# Changelog

Each release's section becomes its release notes exactly (`scripts/release-notes.sh`).

## [Unreleased]

## [1.1.0] - 2026-10-09

The app is now called **HeatBox**, with a new icon and a new look. Studio x Phobos 1.0.0 was its first release under its earlier name.

**If you have Studio x Phobos:** quit it and move it to the Trash before you put HeatBox in your Applications folder. Your library, queue, settings, presets, followed channels and browser buttons are kept; HeatBox uses the same data.

**Opening it the first time:** HeatBox is not signed with an Apple Developer ID and is not notarised. macOS refuses the first time you open it. Close the warning, open System Settings > Privacy & Security, press Open Anyway beside the message about HeatBox, and confirm. You do this once for each new version. The checksum beside the zip lets you check your download first: `shasum -a 256 -c HeatBox-1.1.0-macos-universal.zip.sha256`.

### New

- **A new name, icon and look.** HeatBox's artwork, a warm palette with an Ember accent, the Mac's own sidebar and toolbar, and every screen rebuilt: Download, Queue, Library, Following, Convert, Settings and the first-run Setup. On macOS 26 and later, the bars and labels that float over the content are glass. New installs follow the Mac's light or dark setting.
- **The Library and the versions of a video work from the keyboard.** Tab reaches them; the arrow keys move; Return plays the chosen video; Cmd-Return starts a download. With "Keyboard navigation" on in System Settings, the ring around a button now follows its shape.
- **Queue actions and the Library's search, sort and filter are in the toolbar**, and the sidebar shows how many downloads are in progress, how many videos are saved and how many are new.

### Fixed

- **Very long titles in Chinese, Japanese, Korean or emoji** could make a file name the disk refused, leaving the finished video in the app's working folder. Names are now cut to a length every disk accepts, between whole characters.
- **Two copies of the app can no longer run on the same data at once.** A second copy shows the first and quits, instead of restarting its downloads.
- **Extra options accept only the options the app lists.** A preset (or a pasted option string) that used another option, such as one that runs a program, loads other settings or writes a file outside the download, is refused with a sentence saying why. A file name template can no longer point outside the download folder with `~`, `$` or `..`.

### Unchanged on purpose

- Your existing choices: an install from before this version keeps its theme, accent colour and audio folder.
- The `studioxphobos://` link scheme, the data folder `~/Library/Application Support/Studio x Phobos` and the name `StudioXPhobos` in Activity Monitor, so nothing you have set up stops working.
- Requires macOS 13 or later, on Apple silicon or Intel. This version was run on macOS 26 and 27 on Apple silicon; it was not run on macOS 13 to 15 or on an Intel Mac before release.

## [1.0.0] - 2026-10-07

First release. One app that joins Phobos and YT-DLP Studio.

**Opening it the first time:** Studio x Phobos is not signed with an Apple Developer ID and is not notarised. macOS refuses the first time you open it. Close the warning, open System Settings > Privacy & Security, press Open Anyway beside the message about the app, and confirm. You do this once for each new version. The checksum beside the zip lets you check your download first: `shasum -a 256 -c StudioXPhobos-1.0.0-macos-universal.zip.sha256`.

- One app that joins Phobos's guided downloading, Library, Following and Convert with Studio's Customize, presets and command preview.
- The app installs and updates its own yt-dlp, FFmpeg and Deno, checked against fixed fingerprints.
- A disk-space check before a download, a diagnostics file for bug reports, an app icon and an accessibility pass.
