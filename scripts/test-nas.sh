#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
xcrun swiftc -O -swift-version 5 -parse-as-library \
    -module-cache-path "$PROJECT_ROOT/.build/module-cache" \
    Sources/MoverCore/*.swift ManualTests/NASSmoke.swift -o .build/nas-smoke
.build/nas-smoke
