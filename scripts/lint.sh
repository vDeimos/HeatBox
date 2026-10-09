#!/bin/bash
# Source rules that the compiler does not enforce.
set -euo pipefail
cd "$(dirname "$0")/.."

# The `@State` attribute does not compile with the Command Line Tools alone.
# Use `State(initialValue:)` or `@StateObject` instead.
if grep -rnE '@State([^A-Za-z]|$)' Sources/App | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; then
    echo "error: use State(initialValue:) or @StateObject instead of @State" >&2
    exit 1
fi
# The engine decides; the app draws. Engine files never import a UI framework
# (docs/PROJECT_PLAN.md, Rule 1).
if grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit|Cocoa|UIKit)([^A-Za-z]|$)' Sources/Engine; then
    echo "error: Sources/Engine must not import SwiftUI, AppKit, Cocoa or UIKit (plan Rule 1)" >&2
    exit 1
fi

# No shell, ever: the engine and the app run tools by full path with an
# argument list.
if grep -rnE '"/bin/(ba|z|c|k)?sh"|"/usr/bin/env"' Sources; then
    echo "error: never run a shell from product code" >&2
    exit 1
fi
echo "lint ok"
