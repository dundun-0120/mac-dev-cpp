#!/bin/bash
# Builds "Mac DevC++.app" (native arm64 Swift/AppKit, ad-hoc signed) and installs it to /Applications.
# The dist/ copy is deleted afterwards so Launch Services never registers a second app entry.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mac DevC++.app"
TARGET="/Applications/$APP_NAME"
DIST="dist/$APP_NAME"
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf dist
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

echo "==> swiftc (arm64)"
swiftc -O -target arm64-apple-macos14.0 \
  -o "$DIST/Contents/MacOS/CppDev" Sources/main.swift \
  -framework AppKit -framework Foundation

cp Info.plist "$DIST/Contents/Info.plist"
printf 'APPL????' > "$DIST/Contents/PkgInfo"
cp -R Resources/. "$DIST/Contents/Resources/"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"
fi

echo "==> codesign (ad-hoc)"
codesign --force --sign - --identifier com.qoder.cppdev "$DIST"
codesign --verify "$DIST" && echo "signature ok"
lipo -archs "$DIST/Contents/MacOS/CppDev"

echo "==> selftest"
"$DIST/Contents/MacOS/CppDev" --selftest | tail -2

echo "==> install to $TARGET"
rm -rf "$TARGET"
cp -R "$DIST" "$TARGET"
codesign --force --sign - --identifier com.qoder.cppdev "$TARGET"

# Drop the temporary bundle and any stale registrations from earlier builds.
"$LSR" -u "$DIST" >/dev/null 2>&1 || true
"$LSR" -u /private/tmp/CppDevTest.app >/dev/null 2>&1 || true
rm -rf dist

echo "==> done: $TARGET"
