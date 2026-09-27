#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" != "--skip-build" ]]; then
    ./scripts/build.sh
fi
app="${PWD}/build/Dock Preview.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
staging="$(mktemp -d "${PWD}/build/dmg-staging.XXXXXX")"
mounted=false
cleanup() {
    if $mounted; then hdiutil detach "$staging/mount"; fi
    rm -rf "$staging"
}
trap cleanup EXIT
payload="$staging/payload"
mkdir -p "$payload/.background" "$staging/mount"
if [[ ! -x build/dmg-tools/bin/python3 ]]; then
    python3 -m venv build/dmg-tools
fi
build/dmg-tools/bin/python3 -m pip install --disable-pip-version-check -r scripts/dmg-requirements.txt
xcrun swiftc -module-cache-path .build/module-cache scripts/make-dmg-background.swift -o build/make-dmg-background
build/make-dmg-background "$payload/.background/install.png"
ditto "$app" "$payload/Dock Preview.app"
# A membership-free distribution must not depend on a personal development identity.
codesign --force --sign - "$payload/Dock Preview.app"
codesign --verify --strict "$payload/Dock Preview.app"
ln -s /Applications "$payload/Applications"
cp docs/Installation-EN.txt "$payload/Installation Guide - English.txt"
cp docs/Installation-ZH.txt "$payload/安装指南 - 简体中文.txt"
cp LICENSE "$payload/License.txt"
output="${PWD}/build/Dock-Preview-${version}-arm64.dmg"
hdiutil create -ov -volname "Dock Preview" -srcfolder "$payload" -format UDRW "$staging/writable.dmg"
hdiutil attach -nobrowse -mountpoint "$staging/mount" "$staging/writable.dmg"
mounted=true
build/dmg-tools/bin/python3 scripts/dmg-layout.py "$staging/mount"
hdiutil detach "$staging/mount"
mounted=false
hdiutil convert "$staging/writable.dmg" -format UDZO -ov -o "$output"
hdiutil verify "$output"
printf 'DMG: %s\n' "$output"
