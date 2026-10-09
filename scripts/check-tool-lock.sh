#!/bin/bash
# check-tool-lock.sh: download every file tools.lock.json names and check its
# size and SHA-256 against the lock.
#
#   scripts/check-tool-lock.sh            every file (about 240 MB in all)
#   scripts/check-tool-lock.sh --head     only ask each address for its size
#
# The app refuses a file that does not match, so a builder that moves or
# replaces a release breaks "Install the Programs" for everyone until the lock
# is updated. This finds that out before a person does. It changes nothing:
# the lock is only read. TOOL_LOCK=<file> checks another lock file. A scheduled workflow runs it once a week
# (.github/workflows/tool-lock.yml).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HEAD_ONLY=0
case "${1:-}" in
  "") ;;
  --head) HEAD_ONLY=1 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

LOCK="${TOOL_LOCK:-tools.lock.json}"
[ -f "$LOCK" ] || { echo "There is no $LOCK here." >&2; exit 1; }

# One line per distinct file: address, fingerprint, size, and who uses it.
rows="$(/usr/bin/python3 - "$LOCK" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
seen = {}
for tool, entry in sorted(lock["tools"].items()):
    for arch, item in sorted(entry["artifacts"].items()):
        url = item["url"]
        if not url.startswith("https://"):
            sys.exit(f"{tool} ({arch}): the address is not https: {url}")
        key = (url, item["sha256"], item["size"])
        seen.setdefault(key, []).append(f"{tool}/{arch}")
for (url, sha, size), users in seen.items():
    print("\t".join([url, sha, str(size), ",".join(users)]))
PY
)"
[ -n "$rows" ] || { echo "$LOCK names no files." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
count=0

while IFS=$'\t' read -r url sha size users; do
  count=$((count + 1))
  if [ "$HEAD_ONLY" -eq 1 ]; then
    # https only, also after a redirect, as the app insists.
    got="$(curl --silent --show-error --location --head --proto '=https' --proto-redir '=https' \
      --retry 3 --max-time 60 --write-out '%{http_code} %header{content-length}' --output /dev/null "$url" || true)"
    code="${got%% *}"
    length="${got#* }"
    if [ "$code" != "200" ]; then
      echo "FAIL $users: $url answered $code"
      failures=$((failures + 1))
    elif [ -n "$length" ] && [ "$length" != "$size" ]; then
      echo "FAIL $users: $url is $length bytes, the lock says $size"
      failures=$((failures + 1))
    else
      echo "ok   $users: answers, $size bytes"
    fi
    continue
  fi
  file="$WORK/$count"
  if ! curl --silent --show-error --fail --location --proto '=https' --proto-redir '=https' \
      --retry 3 --max-time 900 --output "$file" "$url"; then
    echo "FAIL $users: could not download $url"
    failures=$((failures + 1))
    continue
  fi
  actual_size="$(wc -c < "$file" | tr -d '[:space:]')"
  actual_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  rm -f "$file"
  if [ "$actual_size" != "$size" ]; then
    echo "FAIL $users: $url is $actual_size bytes, the lock says $size"
    failures=$((failures + 1))
  elif [ "$actual_sha" != "$sha" ]; then
    echo "FAIL $users: $url has SHA-256 $actual_sha, the lock says $sha"
    failures=$((failures + 1))
  else
    echo "ok   $users: $size bytes, SHA-256 matches"
  fi
done <<< "$rows"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $count files do not match $LOCK. Do not change the lock to match without" >&2
  echo "finding out why the file changed (docs/RELEASING.md, \"The tool lock\")." >&2
  exit 1
fi
echo "All $count files match $LOCK."
