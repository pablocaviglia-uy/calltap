#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$ICONSET/icon_512x512@2x.png" Resources/AppIcon.png
echo "wrote Resources/AppIcon.icns"
