#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --arch arm64
app="${PWD}/build/Dock Preview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/arm64-apple-macosx/release/DockPreview "$app/Contents/MacOS/DockPreview"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"
xcrun swiftc -target arm64-apple-macosx27.0 -module-cache-path "$SWIFTPM_MODULECACHE_OVERRIDE" scripts/make-icon.swift -o .build/make-icon
.build/make-icon .build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
# Keep the explicitly selected identity stable across local rebuilds.
preview_signing_identity="${SIGNING_IDENTITY:-}"
if [[ -z "$preview_signing_identity" && -f .signing-identity ]]; then
    preview_signing_identity="$(cat .signing-identity)"
fi
codesign --force --sign "${preview_signing_identity:--}" "$app"
printf 'Built: %s\n' "$app"
