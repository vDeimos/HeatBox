# Contributing to HeatBox

Thank you for looking. HeatBox is a small project with one maintainer, so a short issue before a large change saves us both time.

## Reporting a problem

Open an issue with:

- what you did, what you expected and what happened;
- the diagnostics file from **Settings > Tools > Save Diagnostics…** (it holds versions, switches and error sentences, and no links, titles, file names or user name);
- for a download that fails, the site and, if you are happy to share it, the link. Try **Update yt-dlp** in Settings > Tools first: most sudden failures are a website changing, and a newer yt-dlp fixes them.

Security problems do not go in public issues: see [SECURITY.md](SECURITY.md).

## Suggesting something

Say what you are trying to do rather than which control you want. The app has a guided side and a Customize side; a suggestion usually belongs to one of them.

## Changing the code

You need macOS 13 or later and either Xcode or Apple's Command Line Tools. The integration tests also need the real tools: `brew install yt-dlp ffmpeg deno`.

```sh
scripts/check.sh          # lint, build and every test: what a pull request's CI runs
scripts/check.sh --full   # also the universal build and the launch check
```

Run it before pushing: CI's macOS minutes are limited, and a draft pull request runs no CI until it is marked ready.

The rules that matter most:

- **The engine decides, the app draws.** Anything that is a decision (a name, a command, a state, a sentence shown to the person) lives in `Sources/Engine`, which imports Foundation only, and has a test. `Sources/App` holds views and thin models.
- **No shell, ever.** Tools are started by full path with an argument list.
- **A file is never overwritten or deleted.** A taken name gets a number; removal goes to the Trash.
- **A download's command is covered by a golden fixture.** If you change what yt-dlp or FFmpeg is asked to do, re-record with `UPDATE_GOLDEN=1 scripts/test.sh` and read the diff.
- **Tests do not contact websites** and do not depend on how fast the machine is.
- In `Sources/App`, use `State(initialValue:)` or `@StateObject`, not the `@State` attribute: the project builds without Xcode.
- Words the person reads are plain: say what happened and what to do.

Keep a pull request to one change, say how you checked it, and include screenshots for anything visible. Screens are not covered by automated tests, so say which lines of the checklist in [docs/TESTING.md](docs/TESTING.md) you went through.

## Licence

By contributing you agree that your work is released under the project's MIT licence.

## Conduct

Be kind and assume good faith. The details are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
