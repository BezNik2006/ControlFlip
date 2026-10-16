#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ "${1:-}" != --skip-build ]]; then ./build.command; fi
DMG_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PWD/ControlFlip.app/Contents/Info.plist")
DMG_OUTPUT="$PWD/ControlFlip-$DMG_VERSION-Universal.dmg"
DMG_WORK="$PWD/.build/dmg-styled"
DMG_SOURCE="$DMG_WORK/ControlFlip"
rm -rf "$DMG_WORK"
mkdir -p "$DMG_SOURCE"
ditto "$PWD/ControlFlip.app" "$DMG_SOURCE/ControlFlip.app"
ln -sfn /Applications "$DMG_SOURCE/Программы"
cp "$PWD/Assets/installer-background.tiff" "$DMG_SOURCE/.background.tiff"
cp "$PWD/Assets/ControlFlip.icns" "$DMG_SOURCE/.VolumeIcon.icns"
# FinderInfo on a signed app bundle is rejected by modern codesign verification.
if /usr/bin/xattr -p com.apple.FinderInfo "$DMG_SOURCE/ControlFlip.app" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$DMG_SOURCE/ControlFlip.app"
fi
codesign --verify --strict "$DMG_SOURCE/ControlFlip.app"
python3 "$PWD/Packaging/finder_layout.py" prepare "$DMG_SOURCE"
# Build the filesystem in userspace, then compress it as a standard UDIF image.
hdiutil makehybrid -hfs -hfs-volume-name ControlFlip -hfs-openfolder "$DMG_SOURCE" -ov -o "$DMG_WORK/ControlFlip-hybrid.dmg" "$DMG_SOURCE"
python3 "$PWD/Packaging/finder_layout.py" patch "$DMG_WORK/ControlFlip-hybrid.dmg" "$DMG_SOURCE/.DS_Store"
hdiutil convert "$DMG_WORK/ControlFlip-hybrid.dmg" -ov -format UDZO -o "$DMG_OUTPUT"
hdiutil verify "$DMG_OUTPUT"
echo "Готово: $DMG_OUTPUT"
