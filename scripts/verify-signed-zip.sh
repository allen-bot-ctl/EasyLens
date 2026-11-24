#!/usr/bin/env bash
set -euo pipefail
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
version="$(node -p 'require("./package.json").version')"
for arch in x64 arm64; do
  want=$arch
  [[ "$arch" != x64 ]] || want=x86_64
  mkdir -p "$staging/$arch"
  (cd dist; shasum -a 256 -c "EasyLens-$version-mac-$arch.zip.sha256")
  /usr/bin/ditto -x -k "dist/EasyLens-$version-mac-$arch.zip" "$staging/$arch"
  app="$staging/$arch/EasyLens.app"
  test -d "$app"
  test "$(lipo -archs "$app/Contents/MacOS/EasyLens")" = "$want"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
  node - "$app" <<'NODE'
const {verifyAppSignature} = require('./electron/mac-self-update');
verifyAppSignature(process.argv[2]).then((result) => {
  if (!result.ok) { console.error(result.reason); process.exitCode = 1; }
});
NODE
  echo "SIGNED-ZIP PASS $arch version=$version actual client verifier"
done

# An internally consistent ad-hoc signature is not our fixed shipping identity.
bad="$staging/negative.app"
ditto "$staging/arm64/EasyLens.app" "$bad"
codesign --force --deep --sign - "$bad"
codesign --verify --deep --strict "$bad"
node - "$bad" <<'NODE'
const {verifyAppSignature} = require('./electron/mac-self-update');
verifyAppSignature(process.argv[2]).then((result) => {
  if (result.ok || !/^signature-/.test(result.reason ?? '')) {
    console.error('Expected client to reject a mismatched signer:', result);
    process.exitCode = 1;
  } else {
    console.log('SIGNED-ZIP NEGATIVE PASS: ' + result.reason);
  }
});
NODE
