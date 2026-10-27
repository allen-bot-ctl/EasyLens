#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
cd "$repo_dir"

configuration=${EASYLENS_BUILD_CONFIGURATION:-debug}
case "$configuration" in
  debug|release) ;;
  *) echo "Unsupported build configuration: $configuration" >&2; exit 2 ;;
esac
swift build --product EasyLens -c "$configuration"
bin_dir=$(swift build -c "$configuration" --show-bin-path)

app_dir="$repo_dir/build/EasyLens.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/EasyLens" "$app_dir/Contents/MacOS/EasyLens.next"
mv -f "$app_dir/Contents/MacOS/EasyLens.next" "$app_dir/Contents/MacOS/EasyLens"
chmod 755 "$app_dir/Contents/MacOS/EasyLens"
codesign --force --sign - --identifier ai.nangua.EasyLens "$app_dir"
codesign --verify --strict "$app_dir"
echo "$app_dir"
