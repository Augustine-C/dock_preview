#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" != "--skip-build" ]]; then
    ./scripts/build.sh
fi
app="${PWD}/build/Dock Preview.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
staging="$(mktemp -d "${PWD}/build/dmg-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Dock Preview.app"
# A membership-free distribution must not depend on a personal development identity.
codesign --force --sign - "$staging/Dock Preview.app"
codesign --verify --strict "$staging/Dock Preview.app"
ln -s /Applications "$staging/Applications"
cp docs/Installation-EN.txt "$staging/Installation Guide - English.txt"
cp docs/Installation-ZH.txt "$staging/安装指南 - 简体中文.txt"
cp LICENSE "$staging/License.txt"
output="${PWD}/build/Dock-Preview-${version}-arm64.dmg"
hdiutil create -ov -volname "Dock Preview" -srcfolder "$staging" -format UDZO "$output"
hdiutil verify "$output"
printf 'DMG: %s\n' "$output"
