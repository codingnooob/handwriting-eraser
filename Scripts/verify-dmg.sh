#!/bin/sh
set -eu

image=${1:?Usage: Scripts/verify-dmg.sh IMAGE VERSION}
version=${2:?Usage: Scripts/verify-dmg.sh IMAGE VERSION}
case "$image" in /*) ;; *) image="$(pwd)/$image" ;; esac
[ -f "$image" ] || { echo "DMG does not exist: $image" >&2; exit 1; }
workspace=$(mktemp -d "${TMPDIR:-/tmp}/handwriting-eraser-verify.XXXXXX")
mount="$workspace/mount"
mkdir -p "$mount"
attached=false
cleanup() {
    if [ "$attached" = true ]; then hdiutil detach -quiet "$mount" || true; fi
    rm -rf "$workspace"
}
trap cleanup EXIT HUP INT TERM

hdiutil verify -quiet "$image"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$image"
attached=true
app="$mount/Handwriting Eraser.app"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/HandwritingEraser"
[ -x "$binary" ] && [ -f "$plist" ] && [ -f "$app/Contents/Resources/AppIcon.icns" ]
[ -f "$app/Contents/Resources/LICENSE" ] && [ -f "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]
[ -f "$app/Contents/Resources/ThirdParty/Apache-2.0.txt" ]
[ -f "$app/Contents/Resources/ThirdParty/ONNXRuntime-ThirdPartyNotices.txt" ]
[ -f "$mount/Install.txt" ] && [ "$(readlink "$mount/Applications")" = "/Applications" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$version" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "15.0" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = "HandwritingEraser" ]
lipo -verify_arch arm64 "$binary"
lipo -verify_arch x86_64 "$binary"
codesign --verify --deep --strict --verbose=2 "$app"
if otool -L "$binary" | grep -Eq '@rpath/|@loader_path/|@executable_path/'; then
    echo "Unbundled dynamic dependency found in the app." >&2
    exit 1
fi
echo "Verified universal app, signature, metadata, and installation layout: $image"
