#!/bin/sh
set -eu

# A local-only identity keeps macOS TCC permissions attached to EasyLens as
# source files change. It is not suitable for distributing the app.
identity='EasyLens Local Development'
keychain="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    echo "$identity already exists in the login keychain"
    exit 0
fi

umask 077
scratch=$(mktemp -d "${TMPDIR:-/tmp}/easylens-signing.XXXXXX")
trap 'rm "$scratch/key.pem" "$scratch/cert.pem" "$scratch/identity.pem"; rmdir "$scratch"' EXIT
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj "/CN=$identity" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
    -addext 'extendedKeyUsage=codeSigning' \
    -keyout "$scratch/key.pem" -out "$scratch/cert.pem" 2>/dev/null
cat "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/identity.pem"
security import "$scratch/identity.pem" -f pemseq -k "$keychain" -T /usr/bin/codesign
echo "Created $identity in the login keychain"
