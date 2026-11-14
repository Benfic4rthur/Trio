#!/bin/zsh
# Local Universal build. No upload, installation, launch, remote build, or workflow.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export MACOSX_DEPLOYMENT_TARGET=13.0
sign_identity="${TRIO_SIGN_IDENTITY:--}"

for architecture in arm64 x86_64; do
    swift build --configuration release --product Trio --arch "$architecture" \
        --scratch-path ".build/$architecture" --disable-automatic-resolution
    xcrun swiftc -parse-as-library -swift-version 5 -O \
        -target "$architecture-apple-macos13.0" Tools/LoginHelper.swift \
        -o ".build/$architecture/TrioLoginHelper" -framework AppKit
done

arm_binary_dir="$(swift build --configuration release --arch arm64 --scratch-path .build/arm64 --show-bin-path)"
intel_binary_dir="$(swift build --configuration release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)"

if [[ ! -f Resources/Trio.icns ]]; then
    swift Tools/GenerateIcon.swift
fi

mkdir -p build
staging_dir="$(mktemp -d "$project_dir/build/.trio-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_bundle="$staging_dir/Trio.app"
helper_bundle="$app_bundle/Contents/Library/LoginItems/TrioLoginHelper.app"
helper_executable="$helper_bundle/Contents/MacOS/TrioLoginHelper"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" \
    "$app_bundle/Contents/Library/LaunchAgents" "$helper_bundle/Contents/MacOS"

xcrun lipo -create "$arm_binary_dir/Trio" "$intel_binary_dir/Trio" \
    -output "$app_bundle/Contents/MacOS/Trio"
xcrun lipo -create .build/arm64/TrioLoginHelper .build/x86_64/TrioLoginHelper \
    -output "$helper_executable"
chmod +x "$app_bundle/Contents/MacOS/Trio" "$helper_executable"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
cp Resources/Trio.icns "$app_bundle/Contents/Resources/Trio.icns"
cp Resources/com.allm4.Trio.login.plist "$app_bundle/Contents/Library/LaunchAgents/"
printf 'APPL????' > "$app_bundle/Contents/PkgInfo"
bundle_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
cat > "$helper_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TrioLoginHelper</string>
  <key>CFBundleIdentifier</key><string>com.allm4.Trio.LoginHelper</string>
  <key>CFBundleName</key><string>TrioLoginHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$bundle_short_version</string>
  <key>CFBundleVersion</key><string>$bundle_version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
printf 'APPL????' > "$helper_bundle/Contents/PkgInfo"
plutil -lint "$app_bundle/Contents/Info.plist" \
    "$app_bundle/Contents/Library/LaunchAgents/com.allm4.Trio.login.plist" \
    "$helper_bundle/Contents/Info.plist"

# Set TRIO_SIGN_IDENTITY to a local signing identity for a stable TCC identity.
# The portable default is ad-hoc, with no Apple service or timestamp request.
codesign --force --sign "$sign_identity" --timestamp=none "$helper_bundle"
codesign --force --sign "$sign_identity" --timestamp=none "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
bundle_architectures="$(xcrun lipo -archs "$app_bundle/Contents/MacOS/Trio")"
[[ "$bundle_architectures" == *arm64* && "$bundle_architectures" == *x86_64* ]]
helper_architectures="$(xcrun lipo -archs "$helper_executable")"
[[ "$helper_architectures" == *arm64* && "$helper_architectures" == *x86_64* ]]
codesign --verify --strict --verbose=2 "$helper_bundle"

destination="$project_dir/build/Trio.app"
if [[ -e "$destination" ]]; then
    previous="$project_dir/build/Trio.previous.app"
    if [[ -e "$previous" ]]; then
        previous="$project_dir/build/Trio.previous.$(date +%Y%m%d-%H%M%S).app"
    fi
    mv "$destination" "$previous"
fi
mv "$app_bundle" "$destination"
print "Built Universal app: $destination"
if [[ "$sign_identity" == "-" ]]; then
    print "Signed locally (ad-hoc). For stable Accessibility permission across builds, set TRIO_SIGN_IDENTITY to a local certificate."
fi
