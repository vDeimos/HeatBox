#!/bin/bash
# build.sh: build the app bundle.
#
#   scripts/build.sh               build dist/<App>.app for this Mac
#   scripts/build.sh --universal   build for Apple silicon and Intel together
#   scripts/build.sh --check       also start the built app, wait for its window, and quit it
#   scripts/build.sh --install     also copy it to /Applications (the old copy goes to the Trash) and open it
#
# Options can be combined. Needs only Apple's Command Line Tools, not Xcode.
# --install also moves the app under its earlier name, "Studio x Phobos", to
# the Trash: it has the same identity and data folder, so only one may stay.
# INSTALL_DIR=<folder> installs somewhere else and does not open the app (for
# trying the install step out).
# UPDATE_NOTICE_URL=https://... sets where the app looks for a notice of a
# newer version; without it the built app never looks (ADR-010).
# The app is signed ad hoc (ADR-010): it runs on this Mac, and macOS asks for
# confirmation the first time a copy downloaded from elsewhere is opened.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

UNIVERSAL=0
CHECK=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --check) CHECK=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "This app builds on macOS only." >&2; exit 1; }

# Only the app itself is built and packaged, never the test helpers.
PRODUCT="StudioXPhobos"
# What the app was called in 1.0.0 (ADR-011).
LEGACY_NAME="Studio x Phobos"
flags=(-c release --product "$PRODUCT")
if [ "$UNIVERSAL" -eq 1 ]; then flags+=(--arch arm64 --arch x86_64); fi

echo "1/3 Compiling (a minute or two)..."
swift build "${flags[@]}"
BINARY="$(swift build "${flags[@]}" --show-bin-path)/$PRODUCT"
[ -x "$BINARY" ] || { echo "The build did not produce $BINARY" >&2; exit 1; }

# The name, bundle id, link scheme and version are written in one place,
# Sources/Engine/Engine.swift, and read back from the program itself.
identity="$("$BINARY" --identity)"
field() { printf '%s\n' "$identity" | sed -n "s/^$1=//p"; }
NAME="$(field name)"
EXECUTABLE="$(field executable)"
BUNDLE_ID="$(field bundle)"
SCHEME="$(field scheme)"
VERSION="$(field version)"
for value in "$NAME" "$EXECUTABLE" "$BUNDLE_ID" "$SCHEME" "$VERSION"; do
  [ -n "$value" ] || { echo "The program did not report its identity." >&2; exit 1; }
done
[ "$EXECUTABLE" = "$PRODUCT" ] || { echo "Engine.executableName ($EXECUTABLE) and the product ($PRODUCT) differ." >&2; exit 1; }
# The build number counts commits when this is a git checkout.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "2/3 Assembling $NAME.app ($VERSION, build $BUILD)..."
APP="dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/NOTICES.txt "$APP/Contents/Resources/NOTICES.txt"
# The approved artwork, shown inside the app (ADR-011).
cp Resources/HeatBox/HeatBox_art.png "$APP/Contents/Resources/HeatBoxArt.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>${NAME} listens to videos that have no captions so you can search what was said. This happens on your Mac; nothing is sent anywhere.</string>
    <key>UpdateNoticeURL</key><string>${UPDATE_NOTICE_URL:-}</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video and audio files</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.movie</string><string>public.audio</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}.link</string>
            <key>CFBundleURLSchemes</key><array><string>${SCHEME}</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Nothing but the program, its Info.plist, its icon, its artwork and its licence notice belong in the bundle.
extra="$(find "$APP" -type f ! -path "$APP/Contents/MacOS/$EXECUTABLE" ! -path "$APP/Contents/Info.plist" ! -path "$APP/Contents/Resources/AppIcon.icns" ! -path "$APP/Contents/Resources/NOTICES.txt" ! -path "$APP/Contents/Resources/HeatBoxArt.png" -print)"
[ -z "$extra" ] || { echo "Unexpected files in the bundle:" >&2; echo "$extra" >&2; exit 1; }

# Ad-hoc signature: required on Apple silicon, but not an Apple Developer ID.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "Note: could not sign the app; it should still run."
echo "3/3 Built: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"

if [ "$CHECK" -eq 1 ]; then
  echo "Starting the built app to check that it launches..."
  SUPPORT="$(mktemp -d)"
  trap 'rm -rf "$SUPPORT"' EXIT
  # Its own empty support folder, so the check never reads or changes real data.
  "$APP/Contents/MacOS/$EXECUTABLE" --launch-check "--support-folder=$SUPPORT/support" &
  pid=$!
  ( sleep 60; kill -9 "$pid" 2>/dev/null ) &
  watchdog=$!
  status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "The built app did not launch cleanly (status $status)." >&2; exit 1; }
  [ -f "$SUPPORT/support/queue.json" ] || [ -d "$SUPPORT/support/jobs" ] || { echo "The app did not set up its support folder." >&2; exit 1; }
fi

if [ "$INSTALL" -eq 1 ]; then
  DEST="${INSTALL_DIR:-/Applications}"
  [ -d "$DEST" ] || { echo "There is no folder $DEST to install into." >&2; exit 1; }
  TARGET="$DEST/$NAME.app"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  # The app under either of its names: both run the same program.
  if [ "$DEST" = "/Applications" ] && pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
    echo "Quitting the running $NAME so it can be replaced"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    sleep 2
  fi
  # The copy being replaced, and the app under its earlier name (1.0.0). They
  # share this app's identity, link scheme and data folder, so macOS could
  # open either for a link; the data folder itself is not touched.
  for old in "$TARGET" "$DEST/$LEGACY_NAME.app"; do
    if [ -d "$old" ]; then
      echo "Moving the old $old to the Trash"
      # So that macOS stops offering the copy in the Trash for the app's links.
      "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
      osascript -e "tell application \"Finder\" to delete POSIX file \"$old\"" >/dev/null
    fi
  done
  ditto "$APP" "$TARGET"
  touch "$TARGET"
  "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
  echo "Installed: $TARGET"
  if [ "$DEST" = "/Applications" ]; then open "$TARGET"; fi
fi
