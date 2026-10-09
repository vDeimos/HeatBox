#!/bin/bash
# Records what the download tool says about a link, as a fixture for the
# probe tests:
#
#     scripts/capture-probe-fixture.sh <name> <link> "<what this sample is>"
#
# It runs the same lookup the engine runs (`Probe.plan`; ProbeTests pin the
# arguments) and keeps only the fields the engine reads. The media addresses,
# request headers and anything else tied to this machine or connection are
# dropped. Writes Fixtures/probe/<name>.json without an "expect" block; record
# that with
#
#     UPDATE_GOLDEN=1 scripts/test.sh --filter ProbeFixtureTests
#
# and read the diff before committing. This is the only thing in the
# repository that contacts a real site, and it is never run by the tests.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <name> <link> \"<what this sample is>\"" >&2
    exit 2
fi
name="$1"; link="$2"; about="$3"

find_tool() {
    local folder
    for folder in /opt/homebrew/bin /usr/local/bin /usr/bin; do
        if [[ -x "$folder/$1" ]]; then echo "$folder/$1"; return; fi
    done
}
ytdlp="$(find_tool yt-dlp)"
deno="$(find_tool deno)"
[[ -n "$ytdlp" ]] || { echo "yt-dlp is not installed. Run: brew install yt-dlp ffmpeg deno" >&2; exit 1; }

arguments=(--ignore-config)
[[ -n "$deno" ]] && arguments+=(--js-runtimes "deno:$deno")
arguments+=(-J --flat-playlist --no-playlist --no-warnings -- "$link")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0
"$ytdlp" "${arguments[@]}" > "$work/out.json" 2> "$work/errors.txt" || status=$?
[[ -s "$work/out.json" ]] || echo null > "$work/out.json"

mkdir -p Fixtures/probe
jq --sort-keys \
   --arg about "$about" --arg link "$link" --arg tool "yt-dlp $("$ytdlp" --version)" \
   --arg captured "$(date -u +%Y-%m-%d)" --argjson status "$status" --rawfile errors "$work/errors.txt" '
def pick(keys): with_entries(select(.key as $key | keys | index($key)));
def trimmed:
    if type != "object" then null else
        pick(["_type", "id", "title", "uploader", "channel", "upload_date", "duration", "duration_string",
              "thumbnail", "webpage_url", "webpage_url_domain", "extractor_key", "live_status", "is_live",
              "was_live", "playlist_count", "chapters", "formats", "entries"])
        | if has("formats") then .formats |= map(pick(
              ["format_id", "ext", "vcodec", "acodec", "width", "height", "fps", "tbr", "filesize",
               "filesize_approx", "format_note", "resolution", "protocol", "dynamic_range", "language"])) else . end
        | if has("chapters") and .chapters != null then .chapters |= map(pick(["start_time", "end_time", "title"])) else . end
        | if has("entries") then .entries |= map(pick(["_type", "id", "title", "url", "duration", "ie_key", "live_status"])) else . end
    end;
{about: $about, link: $link, tool: $tool, captured: $captured, exitStatus: $status,
 errors: ($errors | rtrimstr("\n")), output: trimmed}
' "$work/out.json" > "Fixtures/probe/$name.json"

echo "wrote Fixtures/probe/$name.json (exit status $status)"
