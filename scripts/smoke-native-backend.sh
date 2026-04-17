#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/macos/build/ZangbandNative.app"
EXECUTABLE="$APP/Contents/MacOS/ZangbandNative"
LOG="$ROOT_DIR/.context/zangband-native-smoke.log"

cd "$ROOT_DIR"

make -C macos native
plutil -lint "$APP/Contents/Info.plist"
test -x "$EXECUTABLE"
test -d "$APP/Contents/Resources/lib"

mkdir -p "$ROOT_DIR/.context"
"$EXECUTABLE" --new-game > "$LOG" 2>&1 &
pid=$!
sleep 3

if ps -p "$pid" >/dev/null; then
	kill "$pid"
	wait "$pid" 2>/dev/null || true
	echo "Native backend smoke test passed."
else
	echo "Native backend exited during smoke test." >&2
	cat "$LOG" >&2
	exit 1
fi
