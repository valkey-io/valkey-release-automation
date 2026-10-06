#!/bin/sh
# Install the built APKs the way users will: from a signed repository,
# pinned with the @valkey tag. Runs inside a fresh alpine:<release>
# container (the same release the packages were built for).
#
# Usage: test_apk_repo.sh <dir-with-apks> <expected-pkgver>
#
# The index is signed with a throwaway key here, as the publish job signs it
# with the real one. The checks cover what users depend on: an untrusted
# index is refused, the tagged install resolves to these packages and not
# to Alpine's own valkey, and a package that does not match the signed
# index is rejected.
set -eu

PKG_SRC="$1"
EXPECTED="$2"
REPO=/tmp/valkey-repo
ARCH="$(apk --print-arch)"
FAILURES=0

ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; FAILURES=$((FAILURES + 1)); }

apk add --no-cache abuild >/dev/null

echo "=== Build a signed repository from the packages ==="
mkdir -p "$REPO/$ARCH"
cp "$PKG_SRC"/*.apk "$REPO/$ARCH"/
cd "$REPO/$ARCH"
# --rewrite-arch: apk downloads a package from <repo>/<arch in the index>/,
# so noarch subpackages (-doc, -openrc, compat-redis*) must be indexed under
# this directory's arch, as abuild does for its own repositories.
apk index --allow-untrusted --rewrite-arch "$ARCH" -o APKINDEX.tar.gz -d "valkey test repo" ./*.apk
openssl genrsa -out /tmp/valkey-test.rsa 2048 2>/dev/null
openssl rsa -in /tmp/valkey-test.rsa -pubout -out /tmp/valkey-test.rsa.pub 2>/dev/null
abuild-sign -k /tmp/valkey-test.rsa -p valkey-test.rsa.pub APKINDEX.tar.gz
cd /

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
cp /tmp/valkey-test.rsa.pub /etc/apk/keys/valkey-test.rsa.pub
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

echo "=== A package that does not match the signed index is rejected ==="
# shellcheck disable=SC2046
apk del $(echo "$PKGS" | sed 's/@valkey//g') >/dev/null 2>&1
apk cache clean >/dev/null 2>&1 || true
MAIN="$(find "$REPO/$ARCH" -name "valkey-${EXPECTED}.apk")"
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
