#!/bin/bash
# Runs the test suite. With Xcode selected this is plain `swift test`.
# With only the Command Line Tools, Swift Testing's macro plugin is not on the
# default plugin path, so it is added here (see docs/SPIKE-PHASE-0.md).
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
developer_dir="$(xcode-select -p 2>/dev/null || true)"
plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
if [[ "$developer_dir" == */CommandLineTools && -d "$plugins" ]]; then
    flags=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi

exec swift test ${flags[@]+"${flags[@]}"} "$@"
