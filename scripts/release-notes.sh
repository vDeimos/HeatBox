#!/bin/bash
# release-notes.sh VERSION: print that version's section of CHANGELOG.md, so
# the notes on a release are exactly what the changelog says.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
version="${1:?usage: release-notes.sh VERSION}"
notes="$(awk -v v="$version" '
  /^## \[/ { printing = (index($0, "## [" v "]") == 1) ; next }
  printing { print }
' CHANGELOG.md)"
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "No section for version $version in CHANGELOG.md" >&2
  exit 1
fi
printf '%s\n' "$notes"
