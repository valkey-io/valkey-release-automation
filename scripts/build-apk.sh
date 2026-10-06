#!/bin/sh
# Build Valkey APK packages inside an alpine:<release> container.
#
# Environment:
#   VALKEY_VERSION         x.y.z or x.y.z-rcN (required)
#   PLATFORM_ID            e.g. alpine3.22 (required)
#   EXPECTED_ARCH          x86_64 | aarch64 (required)
#   VALKEY_SOURCE_TARBALL  exact-SHA source tarball to build instead of the tag
#   ALLOW_BRANCH_FALLBACK  "true" only on the pre-tag dev/PR path
#   DOC_VERSION            override the valkey-doc release (default MAJOR.MINOR.0)
#
# Mounts:
#   /scripts                 scripts/ (ro)
#   /packaging-common        packaging/common/apk (ro)
#   /packaging-templates     packaging/templates/apk (ro)
#   /packaging-rpm           packaging/<N.M>/rpm (ro) - shared valkey-conf.patch
#   /packaging-override      packaging/<N.M>/apk (ro, optional)
#   /source                  dir holding VALKEY_SOURCE_TARBALL (ro, optional)
#   /output                  built .apk files are copied here
#
# Packages are signed with a throwaway key generated here. Only the
# repository index is signed with the real key, in the publish job; the
# signed index pins every package by checksum.
set -eu

: "${VALKEY_VERSION:?}" "${PLATFORM_ID:?}" "${EXPECTED_ARCH:?}"

# These values reach URLs, sed expressions and the generated APKBUILD (a
# shell script abuild sources), so reject anything that is not a release
# version before using them.
is_version() {
  printf '%s\n' "$1" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?'
}
if ! is_version "$VALKEY_VERSION"; then
  echo "ERROR: invalid VALKEY_VERSION '${VALKEY_VERSION}' (expected x.y.z or x.y.z-rcN)" >&2
  exit 1
fi
if [ -n "${DOC_VERSION:-}" ] && ! is_version "$DOC_VERSION"; then
  echo "ERROR: invalid DOC_VERSION '${DOC_VERSION}'" >&2
  exit 1
fi

echo "============================================="
echo "Building on $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "Architecture: ${EXPECTED_ARCH}"
echo "Valkey Version: ${VALKEY_VERSION}"
echo "============================================="
echo ""

echo "::group::Install build tools"
# abuild -r installs makedepends later, so keep the package index around.
apk update
apk add alpine-sdk bash wget
# Same system account as the package's pre-install script, so package()
# can set valkey ownership on the data and log directories.
addgroup -S valkey 2>/dev/null || true
adduser -S -D -H -h /var/lib/valkey -s /sbin/nologin -G valkey valkey 2>/dev/null || true
echo "::endgroup::"
echo ""

# Bounded download (GNU wget otherwise retries 20 times with a 15-minute
# read timeout). Returns wget's status: 8 means the server answered with an
# error such as 404, anything else non-zero is a transport failure.
fetch() {
  wget -q --timeout=60 --tries=3 --retry-connrefused "$1" -O "$2"
}

echo "::group::Prepare packaging files"
# Merge order matches build-rpm.sh: common files, then the rendered
# APKBUILD (a version may ship its own APKBUILD.template), then the shared
# config patch, then any other version-specific flat files.
WORKDIR=/work/valkey
mkdir -p "$WORKDIR"
cp -r /packaging-common/. "$WORKDIR"/

OVERRIDE_ARGS=""
if [ -d /packaging-override ]; then
  OVERRIDE_ARGS="--override-templates-dir /packaging-override"
fi
# shellcheck disable=SC2086
bash /scripts/generate-from-templates.sh \
  --type apk \
  --version "${VALKEY_VERSION}" \
  --templates-dir /packaging-templates \
  $OVERRIDE_ARGS \
  --output-dir "$WORKDIR"
if [ ! -f "$WORKDIR/APKBUILD" ]; then
  echo "ERROR: no APKBUILD was generated for ${VALKEY_VERSION} (APK packages start at 8.0)" >&2
  exit 1
fi

if [ ! -f /packaging-rpm/valkey-conf.patch ]; then
  echo "ERROR: /packaging-rpm/valkey-conf.patch not found (mount packaging/<N.M>/rpm)" >&2
  exit 1
fi
cp /packaging-rpm/valkey-conf.patch "$WORKDIR"/

if [ -d /packaging-override ]; then
  find /packaging-override -mindepth 1 -maxdepth 1 ! -name '*.template' \
       -exec cp -r {} "$WORKDIR"/ \;
fi
ls -la "$WORKDIR"
echo "::endgroup::"
echo ""

echo "::group::Download Valkey source"
cd "$WORKDIR"
SRC_TARBALL="valkey-${VALKEY_VERSION}.tar.gz"

# SHA-pinned builds: use the mounted exact-commit tarball and fail closed
# if it is missing, so the build cannot drift from the requested SHA.
if [ -n "${VALKEY_SOURCE_TARBALL:-}" ]; then
  if [ ! -f "${VALKEY_SOURCE_TARBALL}" ]; then
    echo "ERROR: VALKEY_SOURCE_TARBALL is set but ${VALKEY_SOURCE_TARBALL} does not exist" >&2
    exit 1
  fi
  echo "Using mounted source tarball ${VALKEY_SOURCE_TARBALL}"
  cp "${VALKEY_SOURCE_TARBALL}" "$SRC_TARBALL"
fi

if [ ! -f "$SRC_TARBALL" ]; then
  echo "Downloading Valkey ${VALKEY_VERSION}..."
  rc=0
  fetch "https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}/valkey-${VALKEY_VERSION}.tar.gz" "$SRC_TARBALL" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$SRC_TARBALL"
    if [ "$rc" -ne 8 ]; then
      echo "ERROR: downloading the ${VALKEY_VERSION} source failed (wget exit ${rc})" >&2
      exit 1
    fi
    # Security: a failed tag download on a release build must fail loudly
    # instead of repackaging the moving branch HEAD as the release. The
    # fallback is reserved for pre-tag PR builds (see build-rpm.sh).
    if [ "${ALLOW_BRANCH_FALLBACK:-}" != "true" ]; then
      echo "ERROR: tag download failed for ${VALKEY_VERSION}; refusing to fall back to the moving branch for a release build."
      echo "Verify the tag exists, or pass an exact source_sha. ALLOW_BRANCH_FALLBACK=true is reserved for pre-tag dev/PR builds."
      exit 1
    fi
    BRANCH_REF="${VALKEY_VERSION%%-*}"
    BRANCH_REF="${BRANCH_REF%.*}"
    echo "Tag ${VALKEY_VERSION} not found, trying branch ${BRANCH_REF} (ALLOW_BRANCH_FALLBACK=true)..."
    fetch "https://github.com/valkey-io/valkey/archive/refs/heads/${BRANCH_REF}.tar.gz" /tmp/branch.tar.gz
    mkdir -p /tmp/repack
    tar xzf /tmp/branch.tar.gz -C /tmp/repack
    mv "/tmp/repack/valkey-${BRANCH_REF}" "/tmp/repack/valkey-${VALKEY_VERSION}"
    tar czf "$SRC_TARBALL" -C /tmp/repack "valkey-${VALKEY_VERSION}"
    rm -rf /tmp/repack /tmp/branch.tar.gz
  fi
fi
echo "::endgroup::"
echo ""

echo "::group::Download Valkey documentation"
DOC_VERSION="${DOC_VERSION:-$(sed -n 's/^_docver=//p' APKBUILD)}"
sed -i "s/^_docver=.*/_docver=${DOC_VERSION}/" APKBUILD
WITH_DOCS=1
if [ -z "$(apk search -x pandoc-cli)" ]; then
  echo "pandoc-cli is not available on this platform; building without valkey-doc"
  WITH_DOCS=0
else
  # Only a missing tag (HTTP error, wget exit 8) means "no docs yet"; a
  # transport failure must not silently ship a release without valkey-doc.
  rc=0
  fetch "https://github.com/valkey-io/valkey-doc/archive/${DOC_VERSION}/valkey-doc-${DOC_VERSION}.tar.gz" \
    "valkey-doc-${DOC_VERSION}.tar.gz" || rc=$?
  if [ "$rc" -eq 8 ]; then
    echo "valkey-doc ${DOC_VERSION} is not published yet; building without valkey-doc"
    rm -f "valkey-doc-${DOC_VERSION}.tar.gz"
    WITH_DOCS=0
  elif [ "$rc" -ne 0 ]; then
    echo "ERROR: downloading valkey-doc ${DOC_VERSION} failed (wget exit ${rc})" >&2
    exit 1
  fi
fi
sed -i "s/^_with_docs=.*/_with_docs=${WITH_DOCS}/" APKBUILD
echo "doc version: ${DOC_VERSION}, with docs: ${WITH_DOCS}"
echo "::endgroup::"
echo ""

echo "::group::Build APKs"
export PACKAGER="Valkey Build System <build@valkey.io>"
abuild-keygen -a -n
# abuild indexes its local output repo and must trust its own key for that.
cp "$HOME"/.abuild/*.rsa.pub /etc/apk/keys/
abuild -F checksum
REPODEST=/work/packages abuild -F -r
echo "::endgroup::"
echo ""

echo "::group::Package Sanity Checks"
PKGVER=$(sed -n 's/^pkgver=//p' APKBUILD)
MAIN_APK=$(find /work/packages -name "valkey-${PKGVER}-r*.apk" -type f | head -1)
if [ -z "$MAIN_APK" ]; then
  echo "ERROR: Main valkey APK not found!"
  find /work/packages -type f
  exit 1
fi
echo "Checking: $MAIN_APK"
echo ""

echo "1. Package metadata..."
PKGINFO=$(tar -xzOf "$MAIN_APK" .PKGINFO 2>/dev/null) || {
  echo "   ✗ cannot read .PKGINFO"
  exit 1
}
echo "$PKGINFO" | grep -E '^(pkgname|pkgver|arch|size|depend|provides) ='
echo "   ✓ Package is readable"
echo ""

echo "2. Required files..."
FILES=$(tar -tzf "$MAIN_APK")
for file in usr/bin/valkey-server usr/bin/valkey-cli etc/valkey/default.conf; do
  if echo "$FILES" | grep -qx "$file"; then
    echo "   ✓ /$file"
  else
    echo "   ✗ MISSING: /$file"
    exit 1
  fi
done
echo ""

echo "3. Architecture..."
ARCH=$(echo "$PKGINFO" | sed -n 's/^arch = //p')
if [ "$ARCH" = "${EXPECTED_ARCH}" ]; then
  echo "   ✓ Architecture: $ARCH"
else
  echo "   ✗ Wrong architecture: $ARCH (expected: ${EXPECTED_ARCH})"
  exit 1
fi
echo ""

echo "4. Package size..."
SIZE_BYTES=$(stat -c%s "$MAIN_APK")
echo "   Package size: ${SIZE_BYTES} bytes"
if [ "$SIZE_BYTES" -lt 500000 ]; then
  echo "   ✗ Package too small"
  exit 1
fi
echo "   ✓ Package size reasonable"
echo "::endgroup::"
echo ""

mkdir -p /output
find /work/packages -name '*.apk' -type f -exec cp {} /output/ \;
echo "Built packages:"
ls -l /output/

echo "============================================="
echo "✓ All checks passed for ${PLATFORM_ID} (${EXPECTED_ARCH})"
echo "============================================="
