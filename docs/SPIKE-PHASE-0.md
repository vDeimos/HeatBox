# Phase 0 spike report

Run on 2026-10-06 on the maintainer's Mac: macOS 27.0.1 (26A434), Apple silicon, Swift 6.4, **Command Line Tools only** (`xcode-select -p` is `/Library/Developer/CommandLineTools`; Xcode is not installed). Tools from Homebrew: yt-dlp 2026.08.19, Deno 2.9.7, FFmpeg and ffprobe in `/opt/homebrew/bin`.

Neither source app was modified. Source commits: Phobos `cfda768`, YT-DLP Studio `73ed761` (unchanged since the analysis).

## (a) SwiftUI `@State` and tests without Xcode

| Check | Command | Result |
| --- | --- | --- |
| `@State` on the macOS 27 SDK | `swiftc -target arm64-apple-macos13.0 a.swift` | **Fails**: `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. `@State` is a macro in this SDK and the plugin is not in the Command Line Tools (`usr/lib/swift/host/plugins` holds only `libObservationMacros`, `libSwiftMacros` and `testing/`) |
| `@State` on the older SDK | same, with `-sdk …/SDKs/MacOSX26.5.sdk` | Compiles and runs. Not relied on: that SDK can vanish with a tools update |
| `State` struct used directly | `private let n = State(initialValue: 0)`, read through `.wrappedValue` / `.projectedValue` | Compiles and runs on the macOS 27 SDK |
| Other wrappers | `swiftc -typecheck` on each | `@Binding`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `@Environment`, `@AppStorage`, `@FocusState`, `@SceneStorage`, `@GestureState`, `@Namespace`, `@ScaledMetric`, `@Published` all compile |
| XCTest | `swift test` with `import XCTest` | **Fails**: `unable to resolve module dependency: 'XCTest'` |
| Swift Testing, default flags | `swift test` with `import Testing` | Fails: `TestingMacros` plugin not found |
| Swift Testing, plugin path given | `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` | **Passes** (1 test). Wrapped as `scripts/test.sh` |
| With Xcode | GitHub Actions `macos-latest` (Xcode 26.6, Swift 6.3.3), run 37425032893 | Lint, build, `scripts/test.sh` (plain `swift test`), universal release build and `--smoke` all pass. That runner is one Xcode release behind this Mac's SDK, so it does not show how Xcode 27 treats `@State` |

Conclusion: Phobos's "`@State` does not build with the Command Line Tools" is true on the current toolchain; Studio's free use of `@State` would not build on this Mac today. Decision in ADR-006: SwiftPM, Swift Testing, and one source rule (no `@State` attribute) so the project builds with or without Xcode.

"With Xcode" could not be checked locally because Xcode is not installed; CI covers it.

## (b) Universal build

`swift build -c release --arch arm64 --arch x86_64` completes in about 20 s. `lipo -archs` on the product prints `x86_64 arm64`. The toolchain warns that x86_64 is deprecated for the SDK's default deployment target (noted in ADR-002). The product path comes from `--show-bin-path` because it differs between SwiftPM versions.

## (c) yt-dlp and Deno

Each run used a clean environment (`env -i HOME=$HOME PATH=/usr/bin:/bin`), `--ignore-config --simulate`, and `--` before one public YouTube link.

| Flags | Result |
| --- | --- |
| `--js-runtimes deno:/opt/homebrew/bin/deno` | No warning; 24 formats listed |
| `--no-js-runtimes` | `WARNING: [youtube] No supported JavaScript runtime could be found … YouTube extraction without a JS runtime has been deprecated, and some formats may be missing`; the same 24 formats for this video |
| neither flag, Deno not on `PATH` | Same warning |

Conclusion: yt-dlp 2026.08.19 still extracts this video without Deno but calls that deprecated and warns of missing formats, and it does not find Homebrew's Deno by itself under a fixed `PATH`. `--js-runtimes deno:<path>` works and silences the warning. Rule 4 of the plan stands: always pass it when Deno is present, and treat a missing Deno as a setup problem to explain, not a hard stop.

## (d) What each source app stores (for the Phase 7 importers)

Read from source; on-disk state checked on this Mac without opening any value.

### Phobos

| Data | Location | Source |
| --- | --- | --- |
| Settings (one JSON blob) | `UserDefaults` key `settings.v2`, domain = bundle ID. Default bundle ID `local.phobos.Phobos` (`build.sh:42`, overridable by `PHOBOS_BUNDLE_ID`); earlier identifier `local.deimos.phobos` is migrated from | `App/SettingsStore.swift:81,94-111` |
| Library | `~/Library/Application Support/Phobos/library.json` | `App/LibraryStore.swift:53-57` |
| Thumbnails | `~/Library/Application Support/Phobos/thumbs/` | `App/LibraryStore.swift:58` |
| Queue | `~/Library/Application Support/Phobos/queue.json` | `App/QueueStore.swift:541-542` |
| Following | `~/Library/Application Support/Phobos/following.json` | `App/FollowingStore.swift:36-37` |
| Transcripts | `~/Library/Application Support/Phobos/transcripts.sqlite` | `App/SpokenIndex.swift:74-75` |
| YouTube sign-in cookies | `~/Library/Application Support/Phobos/cookies.txt` (mode 600) | `App/SettingsStore.swift:117-118` |
| Managed tools folder (never populated) | `~/Library/Application Support/Phobos/bin` | `Engine/Tools.swift:14-15` |

On this Mac: `~/Library/Application Support/Phobos` does not exist, and the only preferences file is named for the old app (`local.<user>.phobos.plist`) (keys `settings.v2`, `useBrowserLogin`, plus window frames). So the importer must look in **both** `local.phobos.Phobos` and `local.deimos.phobos`, and must cope with no library at all.

### YT-DLP Studio (macOS)

| Data | Location | Source |
| --- | --- | --- |
| Current options (JSON) | `UserDefaults` key `currentOptions.v1`, domain `com.local.ytdlpstudio` (`build.sh:11`) | `Models/OptionsStore.swift:18` |
| User presets (JSON) | key `userPresets.v1` | `Models/OptionsStore.swift:19` |
| Tool overrides | keys `ytdlpOverride`, `ffmpegOverride` | `Services/ToolLocator.swift:18-32` |
| Concurrency, finish sound | keys `maxConcurrent`, `playSound` | `YTDLPStudioApp.swift:26` |
| Scratch files | system temporary directory, `ytdlp-studio-*` | `Services/DownloadManager.swift:249-257`, `ChapterTagger.swift:68` |

Studio keeps nothing in `Application Support`. On this Mac `com.local.ytdlpstudio.plist` holds only a window frame: no saved options or presets yet, so the importer's "nothing to import" path is the common case here.

(The Windows edition's `settings.json` is out of scope per ADR-001.)
