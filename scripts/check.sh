#!/bin/bash
# check.sh: run on this Mac what CI runs, before pushing.
#
#   scripts/check.sh            lint, build and every test (what a pull request runs)
#   scripts/check.sh --full     also the universal release build and the launch
#                               check (what a push to main and a release run)
#   scripts/check.sh --lock     also download every pinned tool and check it
#                               (about 240 MB; what the weekly "Tool lock" run does)
#
# Options can be combined. macOS minutes on GitHub count ten times on a private
# repository, so the expensive checks belong here first (docs/TESTING.md).
# The integration tests need the real tools: brew install yt-dlp ffmpeg deno.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FULL=0
LOCK=0
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    --lock) LOCK=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "HeatBox builds and tests on macOS only." >&2; exit 1; }
missing=()
for tool in yt-dlp ffmpeg ffprobe deno; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "The integration tests need ${missing[*]}: brew install yt-dlp ffmpeg deno" >&2
  exit 1
fi

step() { printf '\n== %s\n' "$1"; }

step "Lint"
scripts/lint.sh
step "Build"
swift build
step "Test"
scripts/test.sh

if [ "$FULL" -eq 1 ]; then
  step "Universal app and launch check"
  scripts/build.sh --universal --check
  binary="$(swift build -c release --product StudioXPhobos --arch arm64 --arch x86_64 --show-bin-path)/StudioXPhobos"
  lipo -archs "$binary" | grep -q arm64
  lipo -archs "$binary" | grep -q x86_64
  "$binary" --smoke
  codesign --verify --deep --strict "dist/HeatBox.app"
fi

if [ "$LOCK" -eq 1 ]; then
  step "Tool lock"
  scripts/check-tool-lock.sh
fi

step "All checks passed"
