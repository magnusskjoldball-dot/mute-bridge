#!/bin/bash
# Installerer Mute Bridge (og BlackHole 2ch hvis den mangler). Kjør:
#   curl -fsSL https://raw.githubusercontent.com/magnusskjoldball-dot/mute-bridge/main/install.sh | bash
set -e
REPO="magnusskjoldball-dot/mute-bridge"
DEST="${DEST:-/Applications}"
APP="$DEST/Mute Bridge.app"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

if [ "$(uname -m)" != "arm64" ]; then echo "Mute Bridge krever en Mac med Apple Silicon (M1 eller nyere)."; exit 1; fi

if [ -z "$SKIP_BLACKHOLE" ] && [ ! -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
  echo "▸ Installerer BlackHole 2ch (Macen ber om passordet ditt) …"
  curl -fsSL -o bh.pkg "https://github.com/$REPO/releases/download/blackhole-0.7.1/BlackHole2ch.pkg"
  sudo installer -pkg bh.pkg -target / >/dev/null
  sudo killall coreaudiod 2>/dev/null || true
  sleep 2
fi

echo "▸ Laster ned Mute Bridge …"
curl -fsSL -o app.zip "https://github.com/$REPO/releases/latest/download/Mute-Bridge.zip"
pkill -x GranolaMuteBridge 2>/dev/null || true
sleep 1
rm -rf "$APP"
ditto -x -k app.zip "$DEST"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ Mute Bridge er installert."
[ -n "$NO_OPEN" ] && exit 0
open "$APP"
cat <<'T'

Siste steg (bare første gang):
  1. Systeminnstillinger > Personvern og sikkerhet:
       Mikrofon: slå på Mute Bridge
       Input Monitoring: trykk +, velg Mute Bridge fra Programmer, slå den på
     Klikk så på ikonet i menylinjen og velg «Start på nytt».
  2. Discord > Innstillinger > Voice & Video > Input Device = BlackHole 2ch
T
