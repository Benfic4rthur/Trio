#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_app="$project_dir/build/fixtures/TrioFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O "$project_dir/Tools/CompatibilityFixture.swift" -o "$fixture_app/Contents/MacOS/TrioFixture" -framework AppKit
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrioFixture</string>
<key>CFBundleIdentifier</key><string>com.allm4.TrioFixture</string>
<key>CFBundleName</key><string>Trio Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$fixture_app"
print "$fixture_app"
