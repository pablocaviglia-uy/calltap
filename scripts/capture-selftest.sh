#!/bin/bash
# Records a 1 kHz tone through CallTap's capture code and checks pitch and length, and checks
# the microphone track.
# Usage: scripts/capture-selftest.sh [microphone] [microphone to switch to halfway]
#   microphone defaults to "MacBook" (any part of the device name).
#   Pass the headset's name (e.g. "JBL") to test with its microphone open, which forces the
#   hands-free profile — the case that used to make recordings play 3x too fast.
#   Pass a second name to switch microphones mid-recording; the voice track must stay one
#   48 kHz file as long as the recording.
# You will hear a short beep; macOS asks for microphone and audio-recording access the first time
# (and again after each rebuild, since the test app is ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/selftest"
APP="build/CallTapSelfTest.app"
WORK="$(mktemp -d)"
TARGET="arm64-apple-macosx14.2"
rm -rf "$APP" "$OUT"
mkdir -p "$APP/Contents/MacOS" "$OUT"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>selftest</string>
<key>CFBundleIdentifier</key><string>io.github.pablocaviglia-uy.calltap.selftest</string>
<key>CFBundleName</key><string>CallTap Self-Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>The self-test records the microphone for a few seconds.</string>
<key>NSAudioCaptureUsageDescription</key><string>The self-test records a test tone.</string>
</dict></plist>
PLIST

# CallTapCore as a static module, then the capture sources the app uses plus the test driver.
swiftc -O -target "$TARGET" -parse-as-library -emit-library -static -module-name CallTapCore \
    -emit-module -emit-module-path "$OUT/CallTapCore.swiftmodule" \
    Sources/CallTapCore/*.swift -o "$OUT/libCallTapCore.a"
swiftc -O -target "$TARGET" -I "$OUT" -L "$OUT" -lCallTapCore \
    Sources/CallTap/CoreAudioProperty.swift Sources/CallTap/AudioCapture.swift \
    Sources/CallTap/ProcessTapRecorder.swift Sources/CallTap/MicrophoneRecorder.swift \
    scripts/selftest/main.swift \
    -o "$APP/Contents/MacOS/selftest"
codesign --force --sign - "$APP" >/dev/null 2>&1

# Launched through LaunchServices so macOS attributes the permissions to the self-test app.
open -W -n --stdout "$WORK/out.txt" --stderr "$WORK/out.txt" "$APP" --args "$WORK" "${1:-MacBook}" ${2:+"$2"}
cat "$WORK/out.txt"
grep -q '^PASS' "$WORK/out.txt"
