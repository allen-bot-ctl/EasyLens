#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_dir="$script_dir/.build/EasyLensTranslationProbe.app"
binary="$app_dir/Contents/MacOS/EasyLensTranslationProbe"
mkdir -p "$app_dir/Contents/MacOS"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.nangua.EasyLens.LocalTranslationProbe</string>
  <key>CFBundleName</key><string>EasyLens Local Translation Probe</string>
  <key>CFBundleExecutable</key><string>EasyLensTranslationProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

swiftc -parse-as-library "$script_dir/local_translation_probe.swift" -o "$binary" \
  -framework AppKit -framework SwiftUI -framework Translation
exec "$binary" "$@"
