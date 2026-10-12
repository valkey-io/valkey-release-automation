#!/bin/sh
# Install the built APKs the way users will: from a signed repository,
# pinned with the @valkey tag. Runs inside a fresh alpine:<release>
# container (the same release the packages were built for).
#
# Usage: test_apk_repo.sh <dir-with-apks> <expected-pkgver>
#
# The packages and index are signed with a test key by sign-apk.sh, as the
# publish job signs them with the release key. The checks cover what users
# depend on: an untrusted index is refused, the tagged install resolves to
# these packages and not to Alpine's own valkey, a re-signed package
# verifies on its own, and a package that does not match the signed index
# is rejected.
set -eu

PKG_SRC="$1"
EXPECTED="$2"
REPO=/tmp/valkey-repo
ARCH="$(apk --print-arch)"
FAILURES=0

ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; FAILURES=$((FAILURES + 1)); }

apk add --no-cache abuild python3 >/dev/null

echo "=== Build a signed repository from the packages ==="
# Sign with a test key through sign-apk.sh, as the publish job signs with
# the release key: re-sign every package, index, sign the index.
KEY_DIR=/tmp/valkey-test-key
mkdir -p "$KEY_DIR" "$REPO/$ARCH"
openssl genrsa -out "$KEY_DIR/private.rsa" 2048 2>/dev/null
openssl rsa -in "$KEY_DIR/private.rsa" -pubout -out "$KEY_DIR/valkey-test.rsa.pub" 2>/dev/null
cp "$PKG_SRC"/*.apk "$REPO/$ARCH"/
# shellcheck disable=SC2046
APK_KEY_DIR="$KEY_DIR" sh "$(dirname "$0")/sign-apk.sh" all "$REPO/$ARCH" "$ARCH" "${EXPECTED%-r*}" \
  valkey-test.rsa.pub "valkey test repo" $(cd "$REPO/$ARCH" && ls -- *.apk)

echo "@valkey $REPO" >> /etc/apk/repositories

echo "=== Untrusted repository is refused ==="
apk update >/dev/null 2>&1 || true
if apk add valkey@valkey >/dev/null 2>&1; then
  bad "install from a repository signed by an unknown key was refused"
  apk del valkey >/dev/null 2>&1 || true
else
  ok "install from a repository signed by an unknown key was refused"
fi

echo "=== Trusted repository installs every tagged package ==="
cp "$KEY_DIR/valkey-test.rsa.pub" /etc/apk/keys/valkey-test.rsa.pub
apk update >/dev/null
# Every package this build produced, e.g. valkey valkey-dev valkey-openrc.
PKGS="$(for f in "$REPO/$ARCH"/*.apk; do
  f="${f##*/}"; echo "${f%-*-r*.apk}@valkey"
done | sort -u | tr '\n' ' ')"
# shellcheck disable=SC2086
if apk add $PKGS >/dev/null 2>&1; then
  ok "apk add $PKGS"
else
  bad "apk add $PKGS"
  # shellcheck disable=SC2086
  apk add $PKGS 2>&1 | sed 's/^/    /'
fi
INSTALLED="$(apk info -v 2>/dev/null | sed -n 's/^valkey-\([0-9].*\)$/\1/p')"
if [ "$INSTALLED" = "$EXPECTED" ]; then
  ok "installed valkey $INSTALLED from the tagged repository"
else
  bad "installed valkey $EXPECTED from the tagged repository (got: ${INSTALLED:-none})"
fi
if [ "$(readlink /usr/bin/redis-cli 2>/dev/null)" = valkey-cli ]; then
  ok "valkey-compat-redis installed from the tagged repository"
else
  bad "valkey-compat-redis installed from the tagged repository"
fi

echo "=== Re-signed packages verify and install outside the repository ==="
MAIN="$(find "$REPO/$ARCH" -name "valkey-${EXPECTED}.apk")"
if apk verify "$MAIN" >/dev/null 2>&1; then
  ok "apk verify $(basename "$MAIN")"
else
  bad "apk verify $(basename "$MAIN")"
fi
if tar -tzf "$MAIN" 2>/dev/null | grep -qx '.SIGN.RSA256.valkey-test.rsa.pub'; then
  ok "package carries an RSA256 signature by the repository key"
else
  bad "package carries an RSA256 signature by the repository key"
fi

echo "=== A package that does not match the signed index is rejected ==="
# shellcheck disable=SC2046
apk del $(echo "$PKGS" | sed 's/@valkey//g') >/dev/null 2>&1
apk cache clean >/dev/null 2>&1 || true
cp "$MAIN" /tmp/main.apk.orig
# Append a byte: same name and version, different checksum.
printf 'x' >> "$MAIN"
if apk add valkey@valkey >/dev/null 2>&1; then
  bad "tampered package was rejected"
  apk del valkey >/dev/null 2>&1 || true
else
  ok "tampered package was rejected"
fi
cp /tmp/main.apk.orig "$MAIN"

echo "RESULT: ${FAILURES} failure(s)"
[ "$FAILURES" -eq 0 ]
