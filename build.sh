#!/bin/zsh
# Bygger "Mute Bridge.app" for Apple Silicon. Krever Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
OUT=build; APP="$OUT/Mute Bridge.app"
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"
(cd "$OUT/obj" && clang -arch arm64 -mmacosx-version-min=12.0 -O2 -c ../../Sources/Gate.c ../../Sources/Route.c)
swiftc -O -target arm64-apple-macos12.0 -import-objc-header Sources/Gate.h Sources/main.swift "$OUT/obj/Gate.o" "$OUT/obj/Route.o" \
  -framework AppKit -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework UserNotifications -framework Accelerate \
  -o "$APP/Contents/MacOS/GranolaMuteBridge"
cp Resources/Info.plist "$APP/Contents/"; cp Resources/Bridge.icns "$APP/Contents/Resources/"
xattr -cr "$APP"
# Fast signeringskrav gjør at macOS husker tillatelsene når du bygger på nytt
codesign --force --sign - -r='designated => identifier "local.codex.granolamutebridge.audio"' "$APP"
echo "Ferdig: $APP"
