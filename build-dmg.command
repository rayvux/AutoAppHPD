#!/bin/zsh
set -e

DIR="${0:A:h}"
ICON="$DIR/assets/AutoAppHPD.icns"
APP="$DIR/.build/AutoAppHPD.app"
DMG="$DIR/AutoAppHPD.dmg"
PKG="$DIR/AutoAppHPD.pkg"
VERSION="$(cat "$DIR/VERSION")"
STAGE="$(mktemp -d /tmp/android-release-dmg.XXXXXX)"
RW_DMG="${STAGE}.dmg"
ATTACH_PLIST="${STAGE}.plist"
trap 'rm -rf "$STAGE" "$RW_DMG" "$ATTACH_PLIST"' EXIT

"$DIR/AutoAppHPD.command" --build-only
cp -R "$APP" "$STAGE/AutoAppHPD.app"
PKG_ROOT="$(mktemp -d /tmp/android-release-pkg.XXXXXX)"
trap 'rm -rf "$STAGE" "$RW_DMG" "$ATTACH_PLIST" "$PKG_ROOT"' EXIT
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP" "$PKG_ROOT/Applications/AutoAppHPD.app"
pkgbuild --root "$PKG_ROOT" --identifier com.local.AndroidReleaseTool.installer \
  --version "$VERSION" --install-location / --component-plist "$DIR/installer-components.plist" --scripts "$DIR/installer-scripts" "$PKG"
cp "$PKG" "$STAGE/安装并更新.pkg"
ln -s /Applications "$STAGE/Applications"
cp "$ICON" "$STAGE/.VolumeIcon.icns"
xcrun SetFile -a V "$STAGE/.VolumeIcon.icns"

hdiutil create -volname "AutoAppHPD" -srcfolder "$STAGE" \
  -ov -format UDRW "$RW_DMG"
hdiutil attach -readwrite -nobrowse -plist "$RW_DMG" > "$ATTACH_PLIST"
MOUNT_POINT="$(plutil -p "$ATTACH_PLIST" | sed -n 's/.*"mount-point" => "\(.*\)"/\1/p' | tail -1)"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "无法获取 DMG 挂载路径" >&2
  exit 1
fi
xcrun SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT_POINT"
sync
hdiutil detach "$MOUNT_POINT"
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG"
hdiutil verify "$DMG"
echo "DMG 已生成：$DMG"
