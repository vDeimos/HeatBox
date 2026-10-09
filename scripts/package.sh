#!/bin/bash
# package.sh: build the universal app and pack it as a release zip with its
# checksum.
#
#   scripts/package.sh            dist/HeatBox-<version>-macos-universal.zip (+ .sha256)
#
# Refuses to pack a folder that holds anything personal (a sign-in file, a
# key, an environment file, version-control data or a database of records).
# Needs the same tools as scripts/build.sh. UPDATE_NOTICE_URL, if set, is
# built into the app (see scripts/build.sh and docs/RELEASING.md).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scripts/build.sh --universal --check

NAME="HeatBox"
APP="dist/$NAME.app"
VERSION="$("$APP/Contents/MacOS/StudioXPhobos" --identity | sed -n 's/^version=//p')"
[ -n "$VERSION" ] || { echo "The app did not report its version." >&2; exit 1; }
BASE="HeatBox-$VERSION-macos-universal"
STAGE="dist/$BASE"

rm -rf "$STAGE" "dist/$BASE.zip" "dist/$BASE.zip.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
cp LICENSE "$STAGE/LICENSE.txt"
cp Resources/NOTICES.txt "$STAGE/Licences and Notices.txt"
cp Resources/READ-ME-FIRST.txt "$STAGE/Read Me First.txt"

# The packaging guard.
bad="$(find "$STAGE" \( -iname 'cookies*' -o -iname '*.cookies' -o -iname '.env*' -o -iname '*.pem' -o -iname '*.p12' \
  -o -iname 'id_rsa*' -o -name '.git*' -o -iname '*.sqlite*' -o -iname 'settings*.json' -o -iname 'queue*.json' \
  -o -iname 'library*.json' -o -name '.DS_Store' \) -print)"
[ -z "$bad" ] || { echo "Refusing to package personal or unwanted files:" >&2; echo "$bad" >&2; exit 1; }

( cd dist && ditto -c -k --norsrc --noextattr --keepParent "$BASE" "$BASE.zip" )
( cd dist && shasum -a 256 "$BASE.zip" > "$BASE.zip.sha256" )
rm -rf "$STAGE"
echo "Packed dist/$BASE.zip"
cat "dist/$BASE.zip.sha256"
