#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/ControlFlip.app"
BUILD_DIR="$PWD/.build"
VERSION=$(<VERSION)
BUILD_NUMBER=$(<BUILD_NUMBER)
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || {
  echo "Некорректные VERSION или BUILD_NUMBER" >&2; exit 1
}
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "${RELEASE_BUILD:-0}" == 1 && ! "$SIGNING_IDENTITY" =~ '^[A-Fa-f0-9]{40}$' ]]; then
  echo "Для выпуска нужен SHA-1 постоянного сертификата в SIGNING_IDENTITY. Временная подпись запрещена." >&2
  exit 1
fi
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
SDK_PATH=$(xcrun --show-sdk-path)
for CPU_ARCH in arm64 x86_64; do
  ARCH_DIR="$BUILD_DIR/$CPU_ARCH"
  mkdir -p "$ARCH_DIR"
  xcrun clang -isysroot "$SDK_PATH" -fobjc-arc -arch "$CPU_ARCH" -mmacosx-version-min=13.0 \
    -c Source/LoginItems.m -o "$ARCH_DIR/LoginItems.o"
  xcrun swiftc -swift-version 5 -O -j 1 -whole-module-optimization \
    -target "$CPU_ARCH-apple-macosx13.0" -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/ModuleCache" \
    -import-objc-header Source/LoginItems.h Source/Core.swift Source/LoginItemManager.swift \
    Source/MenuBarIcon.swift Source/Preferences.swift Source/main.swift \
    -Xlinker "$ARCH_DIR/LoginItems.o" -o "$ARCH_DIR/ControlFlip" \
    -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement
 done
STAGED_APP="$BUILD_DIR/app/ControlFlip.app"
rm -rf "$BUILD_DIR/app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp Assets/ControlFlip.icns "$STAGED_APP/Contents/Resources/ControlFlip.icns"
xcrun lipo -create "$BUILD_DIR/arm64/ControlFlip" "$BUILD_DIR/x86_64/ControlFlip" \
  -output "$STAGED_APP/Contents/MacOS/ControlFlip"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ControlFlip</string>
<key>CFBundleDisplayName</key><string>ControlFlip</string>
<key>CFBundleIdentifier</key><string>local.controlflip.mac</string>
<key>CFBundleExecutable</key><string>ControlFlip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleIconFile</key><string>ControlFlip.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>ControlFlip исправляет раскладку выделенного текста или последнего слова по выбранному сочетанию клавиш.</string>
</dict></plist>
PLIST
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier local.controlflip.mac)
[[ -z "${SIGNING_KEYCHAIN:-}" ]] || SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
case "${SIGNING_STYLE:-self-signed}" in
  self-signed) SIGN_ARGS+=(--timestamp=none) ;;
  developer-id) SIGN_ARGS+=(--timestamp --options runtime) ;;
  *) echo "Неизвестный SIGNING_STYLE" >&2; exit 1 ;;
esac
if [[ -n "${SIGNING_P12_FILE:-}" ]]; then
  python3 Packaging/sign.py "$STAGED_APP"
else
  codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
fi
codesign --verify --strict --all-architectures "$STAGED_APP"
rm -rf "$APP"
ditto "$STAGED_APP" "$APP"
if [[ "$SIGNING_IDENTITY" == - ]]; then
  echo "Локальная тестовая сборка: разрешения могут сбрасываться при пересборке. Для распространения используйте release.command."
fi
echo "Готово: $APP (arm64 + x86_64, macOS 13+)"
