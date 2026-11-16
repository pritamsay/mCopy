#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .release
rm -f .release/mCopy-macos-universal.zip
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr dist/myCopy.app .release/mCopy-macos-universal.zip
cd .release
/usr/bin/shasum -a 256 mCopy-macos-universal.zip > SHA256SUMS
print "Packaged GitHub release assets."
