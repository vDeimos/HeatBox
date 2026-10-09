# Testing

## Automatic

```
scripts/lint.sh     source rules the compiler does not enforce
scripts/test.sh     Swift Testing: unit and golden tests, then the real-tool integration tests
scripts/build.sh --universal --check    build the .app, start it, wait for its window and queue, quit
scripts/check-tool-lock.sh              download every pinned tool and check its size and SHA-256 (weekly in CI)
```

| Level | What | Where |
| --- | --- | --- |
| Unit | Every engine decision: names, links, messages, recipes, validator, state transitions, retry, schedule, parsers, disk space, diagnostics | `Tests/EngineTests` |
| Golden | Recipe to exact yt-dlp and FFmpeg arguments, as JSON; re-record with `UPDATE_GOLDEN=1` and read the diff | `Fixtures/golden` |
| Probe | Recorded lookups replayed; no site is contacted | `Fixtures/probe` |
| Integration | Real yt-dlp, FFmpeg, ffprobe against generated media and a local server; a missing tool fails, never skips | `Tests/IntegrationTests` |
| Live (opt-in) | `LIVE_TOOLS=1 scripts/test.sh --filter LiveToolInstall` installs all four tools from their real addresses and checks the pins | `Tests/IntegrationTests` |

CI runs lint, build, tests, a universal release build and the launch check on every push to `main` and to a `heatbox/…` release branch, and on every pull request. A phase or release is not recorded as done until the CI run for its own commit has been read and is green. Tests must not time the machine tightly; a shared runner is slower.

## Manual checklist (before a release)

The screens are not covered by automated tests. Go through this on a real Mac, with a scratch folder for downloads (`--support-folder=<path>` after the program name keeps your own data out of it). Each line has gone wrong at least once in one of the two source apps or in this one.

Launch options that help: `--pretend-missing=deno,ffmpeg` shows the Setup screen, `--update-notice=<file>` shows the notice of a new version, and `--no-glass` draws the app the way macOS 13 to 15 do. On macOS 26 or later go through the screens once with it and once without.

**First run**
- A Mac without Homebrew's tools shows the Setup screen, with the artwork and no sidebar; the sidebar appears when the tools are found; Install the Programs ends with "Everything is installed."; a video then downloads
- Settings > Tools lists each tool as installed by the app with the pinned version; Update yt-dlp says it is current or installs a newer one
- The app icon shows in the Dock, Finder and the app switcher
- An unsigned copy from a zip is blocked until Open Anyway, and then opens

**Download**
- One video shows explained choices with sizes; Download is disabled until one is picked
- The file has a clean name and lands in the site's folder; looking the same video up again says it is already downloaded
- A video with a very long title in Chinese, Japanese, Korean or emoji is saved, its name cut between whole characters; with subtitles on, the subtitle file sits beside it under the same name
- A link from inside a playlist gives one video with the playlist offered separately; two links and a playlist each ask first with a count
- A bad link gives one plain sentence; a live or upcoming stream is refused with a sentence
- With almost no free space on the destination disk, Download says how much is free instead of starting

**Clips, chapters, Customize**
- Typing, dragging and arrow keys move the clip handles; the clip's length matches the times; a video with chapters offers one file per chapter
- Customize opens with ten groups; the command underneath matches what runs; Save as Preset, rename, delete, export and import work; an imported preset with `--exec` is refused
- All Formats lists the table and a picked pair downloads; the comment picker finds a chapter list

**Queue**
- Cancel (under a row's more button) leaves no files behind; Pause keeps the partial file and Resume carries on; Cmd-Q during a download asks, and after reopening the job is Paused
- Later schedules a download and it keeps its time across a restart; Start Now begins it early
- Wi-Fi off mid-download shows "Trying again in…" and back on lets it finish; a speed limit visibly caps the speed
- A failed download offers Retry; the log window shows the command and the tool's lines

**Library, Following, Convert**
- Pictures with lengths, search, Sort by and Show in the toolbar, By channel; the detail pane opens beside the tiles and closes with its button and with Esc; Space previews; a renamed file shows as missing; Move to Trash can be undone
- Follow, Check now, pick new videos, download; survives a restart
- Each of the four conversions makes a correct file beside the original; a tiny file refuses to shrink; Send to iPhone and Share open AirDrop and the share menu

**Spoken words, sign-in, tour, command bar**
- Switching spoken search on counts videos as they are read; a word said in a captioned video is found with its time; listening waits for mains power and macOS asks permission once
- Copy my sign-in (needs a person: it reads a browser) works or says what to allow; the saved sign-in is used only while its switch is on
- The tour shows once and again from Help > Welcome Tour; Cmd-K opens the command bar over every screen

**Accessibility (VoiceOver on, keyboard only, large text)**
- Every sidebar entry reads its name and "selected"; Library tiles read as buttons and offer Play from the actions menu; icon-only buttons read what they do
- With System Settings > Keyboard > "Keyboard navigation" **off**: Tab reaches the link box, the versions and the Library's tiles; up and down pick a version; Cmd-Return downloads; the arrows move across the Library's tiles and groups and the page follows; Return plays, Space previews, Esc closes the details; Return in the search box plays nothing
- With it **on**: Tab reaches every control on Download, Queue, Library, Following, Convert, Settings and Customize, each with a ring that follows its shape and is not cut off; sheets, the tour and the command bar close with Escape
- Settings > Large text enlarges everything without clipping the main screens

**Diagnostics and notices**
- Settings > Save Diagnostics… writes a file that holds no link, title, file name or user name
- Help > Licences and Notices opens the notice file

**Upgrade and second copies**
- With HeatBox open, opening a second copy from another folder brings the first to the front and starts nothing
- `scripts/build.sh --install` over a 1.0.0 `Studio x Phobos.app` leaves one app, `HeatBox.app`; the Library, queue and settings are as they were; a `studioxphobos://open?url=…` link opens HeatBox

**Release package**
- `scripts/package.sh` produces the zip and checksum; the checksum verifies; the unzipped app passes `codesign --verify` and launches

## Phobos's final checks (still apply)

Sponsor cuts stay in step with the sound; a song from a "Name - Topic" channel keeps correct artist, album, title, track number and cover; a music video's "(Official Video)" is dropped; a talk downloaded as audio keeps its title and invents no album; a playlist of songs has no numbers in front of file names.
