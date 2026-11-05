#!/bin/zsh
set -e

DIR="${0:A:h}"
SRC="$DIR/AutoAppHPD.swift"
CLIENT_SRC="$DIR/NativeApkProtect.swift"
BANGCLE_SRC="$DIR/BangcleService.swift"
APP="$DIR/.build/AutoAppHPD.app"
BIN="$APP/Contents/MacOS/AutoAppHPD"
VERSION="$(cat "$DIR/VERSION")"
RESOURCES="$APP/Contents/Resources"
ARCH="$(uname -m)"
MODULE_CACHE="${TMPDIR:-/tmp}/AndroidReleaseToolModuleCache"
NEEDS_BUILD=0

[[ ! -x "$BIN" || "$SRC" -nt "$BIN" || "$BANGCLE_SRC" -nt "$BIN" || "$DIR/VERSION" -nt "$BIN" || "$0" -nt "$BIN" ]] && NEEDS_BUILD=1
if [[ -x "$BIN" ]] && ! file "$BIN" | grep -q " $ARCH"; then
  NEEDS_BUILD=1
fi

if (( NEEDS_BUILD )); then
  mkdir -p "$APP/Contents/MacOS"
  for BUILD_ARCH in arm64 x86_64; do
    xcrun swiftc -parse-as-library -target "$BUILD_ARCH-apple-macos12.0" \
      -module-cache-path "$MODULE_CACHE" -file-prefix-map "$DIR=." -O -framework AppKit -framework WebKit "$SRC" "$BANGCLE_SRC" -o "$BIN.$BUILD_ARCH"
  done
  xcrun lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
  rm "$BIN.arm64" "$BIN.x86_64"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string AutoAppHPD' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.local.AndroidReleaseTool' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string AutoAppHPD' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string AutoAppHPD' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 12.0' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$APP/Contents/Info.plist"
fi

mkdir -p "$RESOURCES"
cp -f "$DIR/VasDolly.jar" "$RESOURCES/VasDolly.jar"
cp -f "$DIR/channels.txt" "$RESOURCES/channels.txt"
if [[ ! -f "$RESOURCES/apkprotect" || "$CLIENT_SRC" -nt "$RESOURCES/apkprotect" || "$0" -nt "$RESOURCES/apkprotect" ]]; then
  for BUILD_ARCH in arm64 x86_64; do
    xcrun swiftc -parse-as-library -target "$BUILD_ARCH-apple-macos12.0" \
      -module-cache-path "$MODULE_CACHE" -file-prefix-map "$DIR=." -O "$CLIENT_SRC" -o "$RESOURCES/apkprotect.$BUILD_ARCH"
  done
  xcrun lipo -create "$RESOURCES/apkprotect.arm64" "$RESOURCES/apkprotect.x86_64" -output "$RESOURCES/apkprotect"
  rm "$RESOURCES/apkprotect.arm64" "$RESOURCES/apkprotect.x86_64"
fi
xcrun lipo "$BIN" -verify_arch arm64 x86_64
xcrun lipo "$RESOURCES/apkprotect" -verify_arch arm64 x86_64
chmod +x "$RESOURCES/apkprotect"
codesign --force --sign - "$RESOURCES/apkprotect"
cp -f "$DIR/assets/AutoAppHPD.icns" "$RESOURCES/AutoAppHPD.icns"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AutoAppHPD.icns' "$APP/Contents/Info.plist"
xattr -cr "$APP"

if ! codesign --verify "$APP" >/dev/null 2>&1; then
  codesign --force --sign - "$APP"
fi

[[ "${1:-}" == "--build-only" ]] && exit 0
open "$APP"
