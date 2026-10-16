#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export RELEASE_BUILD=1
: "${SIGNING_IDENTITY:?Укажите SHA-1 постоянного сертификата в SIGNING_IDENTITY}"
export SIGNING_IDENTITY
./test.command
./build.command
python3 Packaging/verify_release.py ControlFlip.app
./make-dmg.command --skip-build
VERSION=$(<VERSION)
DMG="ControlFlip-$VERSION-Universal.dmg"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier local.controlflip.diskimage)
[[ -z "${SIGNING_KEYCHAIN:-}" ]] || SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
if [[ "${SIGNING_STYLE:-self-signed}" == developer-id ]]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi
if [[ -n "${SIGNING_P12_FILE:-}" ]]; then
  python3 Packaging/sign.py "$DMG"
else
  codesign "${SIGN_ARGS[@]}" "$DMG"
fi
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
rm -rf dist
mkdir -p dist
cp "$DMG" dist/
python3 - <<'PY'
from pathlib import Path
import subprocess
result = subprocess.run(["codesign", "-d", "-r-", "ControlFlip.app"],
                        check=True, capture_output=True, text=True)
lines = [line for line in (result.stdout + result.stderr).splitlines()
         if "designated =>" in line]
if len(lines) != 1:
    raise RuntimeError("Missing designated requirement")
Path("dist/Signing.txt").write_text(lines[0] + "\n")
PY
(
  cd dist
  shasum -a 256 "$DMG" > SHA256SUMS.txt
)
echo "Готовые файлы выпуска: $PWD/dist"
echo "Нотариальное заверение Apple не выполнялось. Первое открытие потребует подтверждения в macOS."
