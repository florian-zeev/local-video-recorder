#!/usr/bin/env bash
# Build MeetingRecorder.app - a minimal .app bundle so TCC sees the binary
# as its own responsible process (not the terminal that launched it).
#
# Usage:
#   ./build-app.sh                       # release build, leaves bundle in repo
#   ./build-app.sh debug                 # debug build
#   ./build-app.sh --install             # release build, also copies to /Applications/
#   ./build-app.sh debug --install       # combined
#
# After building, launch with:
#   open MeetingRecorder.app
# or, when installed:
#   open /Applications/MeetingRecorder.app

set -euo pipefail

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --install|-i)  INSTALL=1 ;;
        *) echo "Usage: $0 [debug|release] [--install]" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MeetingRecorder"
APP_BUNDLE="$REPO_ROOT/$APP_NAME.app"
BIN_SRC="$REPO_ROOT/.build/arm64-apple-macosx/$CONFIG/$APP_NAME"

echo "==> Building (${CONFIG})..."
swift build -c "$CONFIG"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "Build did not produce binary at $BIN_SRC" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_SRC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.mergeflow.MeetingRecorder</string>
    <key>CFBundleName</key>
    <string>MeetingRecorder</string>
    <key>CFBundleDisplayName</key>
    <string>Meeting Recorder</string>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MeetingRecorder records the microphone alongside system audio.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>MeetingRecorder transcribes recordings locally on this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so TCC has a stable identity to bind permissions to.
echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"

if [[ "$INSTALL" -eq 1 ]]; then
    INSTALL_DEST="/Applications/$APP_NAME.app"
    # macOS won't let us overwrite a running app — quit it first.
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "==> Quitting running $APP_NAME..."
        pkill -x "$APP_NAME" || true
        # Brief settle window so the lock on the bundle clears.
        for _ in 1 2 3 4 5; do
            pgrep -x "$APP_NAME" >/dev/null || break
            sleep 0.5
        done
    fi
    echo "==> Installing to ${INSTALL_DEST}..."
    rm -rf "$INSTALL_DEST"
    cp -R "$APP_BUNDLE" "$INSTALL_DEST"
    # Re-register so LaunchServices/Spotlight pick up the new copy immediately.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -f "$INSTALL_DEST" >/dev/null 2>&1 || true
    echo "Installed: $INSTALL_DEST"
    echo "Launch via Spotlight (Cmd-Space) or: open \"$INSTALL_DEST\""
else
    echo "Launch: open \"$APP_BUNDLE\""
    echo "Tip: pass --install to also copy into /Applications/."
fi
