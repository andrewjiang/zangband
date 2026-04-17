#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Zangband"
APP_PATH="$ROOT_DIR/macos/build/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
IDENTITY="${CODESIGN_IDENTITY:--}"

version_part() {
	awk -v key="$1" '$1 == "#define" && $2 == key { print $3 }' "$ROOT_DIR/src/defines.h"
}

MAJOR="$(version_part VER_MAJOR)"
MINOR="$(version_part VER_MINOR)"
PATCH="$(version_part VER_PATCH)"
EXTRA="$(version_part VER_EXTRA)"
AFTER="$(version_part VER_AFTER | tr -d '"')"

VERSION="$MAJOR.$MINOR.$PATCH"
if [[ "$EXTRA" != "0" ]]; then
	VERSION="$VERSION-pre$EXTRA"
fi
if [[ -n "$AFTER" ]]; then
	VERSION="$VERSION$AFTER"
fi

ARCH="$(uname -m)"
ZIP_PATH="$DIST_DIR/Zangband-$VERSION-macos-$ARCH.zip"
SHA_PATH="$ZIP_PATH.sha256"

cd "$ROOT_DIR"

if [[ ! -x ./config.status ]]; then
	./configure --with-x11=no
fi

make
make -C macos

if [[ ! -d "$APP_PATH" ]]; then
	echo "Missing app bundle: $APP_PATH" >&2
	exit 1
fi

sign_args=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
	sign_args+=(--timestamp=none)
else
	sign_args+=(--options runtime --timestamp)
fi

codesign "${sign_args[@]}" "$APP_PATH/Contents/Resources/zangband"
codesign "${sign_args[@]}" --deep "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"

echo "Release artifact: $ZIP_PATH"
echo "Checksum: $SHA_PATH"
if [[ "$IDENTITY" == "-" ]]; then
	echo "Signing: ad-hoc. Set CODESIGN_IDENTITY to use a Developer ID certificate."
else
	echo "Signing: $IDENTITY"
fi
