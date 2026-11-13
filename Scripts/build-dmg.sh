#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

version=${1:?Usage: Scripts/build-dmg.sh VERSION [OUTPUT_DIRECTORY]}
output_directory=${2:-dist}
if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "Version must be a numeric semantic version, e.g. 1.2.0." >&2
    exit 1
fi
mkdir -p "$output_directory"
output_directory=$(cd "$output_directory" && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/handwriting-eraser-dmg.XXXXXX")
trap 'rm -rf "$workspace"' EXIT HUP INT TERM

# Build both architectures separately: SwiftPM versions differ in whether
# they support multiple --arch flags, whereas --triple is supported by both.
for arch in arm64 x86_64; do
    triple="$arch-apple-macosx15.0"
    swift build -c release --product HandwritingEraser --triple "$triple"
    bin_path=$(swift build -c release --triple "$triple" --show-bin-path)
    cp "$bin_path/HandwritingEraser" "$workspace/HandwritingEraser-$arch"
done

stage="$workspace/stage"
app="$stage/Handwriting Eraser.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$workspace/HandwritingEraser-arm64" "$workspace/HandwritingEraser-x86_64" \
    -output "$app/Contents/MacOS/HandwritingEraser"
lipo -verify_arch arm64 "$app/Contents/MacOS/HandwritingEraser"
lipo -verify_arch x86_64 "$app/Contents/MacOS/HandwritingEraser"
chmod 755 "$app/Contents/MacOS/HandwritingEraser"

# All current non-system dependencies are statically linked. Refuse to ship an
# incomplete app if a future change introduces an unbundled dynamic library.
if otool -L "$app/Contents/MacOS/HandwritingEraser" | grep -Eq '@rpath/|@loader_path/|@executable_path/'; then
    echo "The app has a non-system dynamic dependency; bundle it before release." >&2
    exit 1
fi

cp Packaging/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R ThirdParty "$app/Contents/Resources/ThirdParty"
printf 'APPL????' > "$app/Contents/PkgInfo"
ln -s /Applications "$stage/Applications"
cp Packaging/INSTALL.txt "$stage/Install.txt"

identity=${SIGNING_IDENTITY:--}
if [ "$identity" = "-" ]; then
    codesign --force --sign - "$app"
else
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

image="$output_directory/HandwritingEraser-$version-macOS-universal.dmg"
hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Handwriting Eraser $version" \
    -srcfolder "$stage" "$image"
if [ "$identity" != "-" ]; then
    codesign --force --timestamp --sign "$identity" "$image"
    codesign --verify --verbose=2 "$image"
fi
printf '\nCreated %s\n' "$image"
