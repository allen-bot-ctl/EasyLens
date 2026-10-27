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
identity=${EASYLENS_CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  if security find-certificate -c 'EasyLens Local Development' \
      "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    identity='EasyLens Local Development'
  else
    identity='-'
    echo 'Using ad hoc signing; run scripts/setup-local-signing.sh to keep macOS permissions across builds' >&2
  fi
fi
codesign --force --sign "$identity" --identifier ai.nangua.EasyLens "$app_dir"
codesign --verify --strict "$app_dir"
echo "Signing identity: $identity"
echo "$app_dir"
