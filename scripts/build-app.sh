#!/bin/bash
# Builds build/CallTap.app (ad-hoc signed). Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CallTap"

APP="build/CallTap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CallTap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Replacing the app quits it, which would cut a recording in progress. A recording keeps
    # appending to its temporary tracks, so any track written in the last minute means wait.
    if find "${TMPDIR:-/tmp}" -maxdepth 2 -path '*CallTap-*' -name '*.caf' -mmin -1 2>/dev/null | grep -q .; then
        echo "CallTap is recording (or just finished): not installing. Stop the recording and retry in a minute." >&2
        exit 1
    fi
    pkill -f "$HOME/Applications/CallTap.app/Contents/MacOS/CallTap" || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/CallTap.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "installed $HOME/Applications/CallTap.app"
fi
