#!/bin/bash
# Regenerates Resources/AppIcon.icns from the paw geometry in PawIcon.swift.
# Only needed when the artwork changes — the .icns is committed.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O Sources/BadgersBLELock/PawIcon.swift Tools/main.swift -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK/AppIcon.iconset"

mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Built $(pwd)/Resources/AppIcon.icns"
