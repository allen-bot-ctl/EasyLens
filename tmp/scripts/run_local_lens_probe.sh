#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
app_dir="$script_dir/.build/EasyLensProbe.app"
binary="$app_dir/Contents/MacOS/EasyLensProbe"
mkdir -p "$app_dir/Contents/MacOS"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.nangua.EasyLens.LocalProbe</string>
  <key>CFBundleName</key><string>EasyLens Local Probe</string>
  <key>CFBundleExecutable</key><string>EasyLensProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

swiftc -parse-as-library "$script_dir/screen_lens_probe.swift" "$script_dir/ProbeLogger.swift" -o "$binary" \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework Vision \
  -framework NaturalLanguage -framework SwiftUI -framework Translation
exec "$binary" "$@"
