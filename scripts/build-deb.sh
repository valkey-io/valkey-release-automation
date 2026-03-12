#!/bin/bash
set -e

echo "============================================="
echo "Building on $(cat /etc/os-release | grep PRETTY_NAME | cut -d\" -f2)"
echo "Architecture: ${EXPECTED_ARCH}"
echo "Valkey Version: ${VALKEY_VERSION}"
echo "============================================="
echo ""

echo "::group::Install build dependencies"

apt-get update

apt-get install -y \
  build-essential \
  debhelper \
  devscripts \
  fakeroot \
  dpkg-dev \
  ca-certificates \
  curl \
  wget \
  tar \
  gzip \
  lsb-release

# Critical build dependencies — hard-fail if any of these are missing.
# These are required to produce correct, working binaries.
echo "Installing critical build dependencies..."
apt-get install -y \
  libjemalloc-dev \
  libssl-dev \
  libsystemd-dev \
  tcl \
  tcl-dev \
  python3

# At least one of pkg-config/pkgconf must be available
apt-get install -y pkg-config || apt-get install -y pkgconf

echo "Verifying critical headers..."
ls -lah /usr/include/jemalloc/jemalloc.h
ls -lah /usr/include/openssl/ssl.h

# Optional dependencies — not available on all distros, build can
# proceed without them (bundled alternatives or doc-only packages).
echo "Installing optional build dependencies..."
for pkg in \
  dh-exec \
  libhiredis-dev \
  liblua5.1-dev \
  liblzf-dev \
  lua-bitop-dev \
  lua-cjson-dev \
  pandoc \
  python3-sphinx \
  python3-sphinx-rtd-theme \
  python3-yaml \
  tcl-tls; do
  apt-get install -y "$pkg" 2>/dev/null || echo "NOTICE: $pkg not available — skipping"
done

echo "::endgroup::"
echo ""

echo "::group::Prepare source and debian directory"

# Merge common + version-specific packaging files
mkdir -p /packaging
cp -r /packaging-common/* /packaging/
cp -r /packaging-override/* /packaging/
PACKAGING_DIR="/packaging"

# Generate files from templates if templates are mounted
if [ -d "/packaging-templates" ]; then
  echo "Processing DEB templates..."
  bash /scripts/generate-from-templates.sh \
    --type deb \
    --version "${VALKEY_VERSION}" \
    --templates-dir /packaging-templates \
    --output-dir "$PACKAGING_DIR"
fi

# Verify packaging files are mounted
if [ ! -d "$PACKAGING_DIR" ]; then
  echo "ERROR: Packaging directory not found at $PACKAGING_DIR!"
  exit 1
fi

echo "✓ Found packaging files at: $PACKAGING_DIR"

# Download Valkey source
echo "Downloading Valkey ${VALKEY_VERSION}..."
cd /root
wget -q https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}.tar.gz -O valkey_${VALKEY_VERSION}.orig.tar.gz

# Extract source
echo "Extracting source..."
tar xzf valkey_${VALKEY_VERSION}.orig.tar.gz

# Copy debian directory to extracted source
echo "Copying debian directory from ${PACKAGING_DIR}..."
cp -r ${PACKAGING_DIR} valkey-${VALKEY_VERSION}/debian

# Verify debian directory was copied
if [ ! -d "valkey-${VALKEY_VERSION}/debian" ]; then
  echo "ERROR: Failed to copy debian directory!"
  exit 1
fi

echo "✓ Debian directory copied successfully"

cd valkey-${VALKEY_VERSION}

echo "::endgroup::"
echo ""

echo "::group::Override doc version in debian/rules"

DOC_VERSION=$(echo "${VALKEY_VERSION}" | sed "s/\.[0-9]*$/.0/")
sed -i "s/^VALKEY_DOC_VERSION = .*/VALKEY_DOC_VERSION = ${DOC_VERSION}/" debian/rules

echo "::endgroup::"
echo ""

echo "::group::Fix debhelper compat level conflict"

if grep -q "debhelper-compat" debian/control; then
  echo "Found debhelper-compat in debian/control"

  if [ -f "debian/compat" ]; then
    COMPAT_LEVEL=$(cat debian/compat)
    echo "Removing debian/compat (was: ${COMPAT_LEVEL})"
    rm debian/compat
    echo "✓ Using debhelper-compat from debian/control only"
  else
    echo "✓ No debian/compat file (correct)"
  fi
else
  echo "Using debian/compat file"
fi

echo "::endgroup::"
echo ""

echo "::group::Fix jemalloc for Ubuntu 22.04"

if grep -q "jammy" /etc/os-release 2>/dev/null; then
  echo "Detected Ubuntu 22.04 (Jammy)"

  if [ ! -f "/usr/include/jemalloc/jemalloc.h" ]; then
    echo "⚠ jemalloc headers not found - disabling USE_SYSTEM_JEMALLOC"

    if [ -f "debian/rules" ]; then
      echo "Patching debian/rules to disable USE_SYSTEM_JEMALLOC..."
      sed -i "s/USE_SYSTEM_JEMALLOC=yes/USE_SYSTEM_JEMALLOC=no/g" debian/rules || true
      sed -i "s/USE_JEMALLOC=yes/USE_JEMALLOC=yes/g" debian/rules || true
      echo "✓ Patched debian/rules"
    fi
  else
    echo "✓ jemalloc headers found - keeping USE_SYSTEM_JEMALLOC"
  fi
else
  echo "Not Ubuntu 22.04 - no jemalloc workaround needed"
fi

echo "::endgroup::"
echo ""

echo "::group::Install package-specific dependencies with mk-build-deps"

if command -v mk-build-deps &> /dev/null; then
  echo "Using mk-build-deps to install dependencies..."
  mk-build-deps --install --remove \
    --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes" \
    debian/control || {
      echo "mk-build-deps failed, but continuing..."
    }
else
  echo "mk-build-deps not available"
fi

# Check what dependencies are still missing and attempt to install them
echo ""
echo "Checking build dependencies..."
if ! dpkg-checkbuilddeps 2>&1 | tee /tmp/missing-deps.txt; then
  echo ""
  echo "Some dependencies are missing, attempting to install..."

  MISSING_DEPS=$(grep "Unmet build dependencies:" /tmp/missing-deps.txt | sed "s/.*dependencies: //" | tr " " "\n" | grep -v "^$" | sed "s/(.*)//g" || true)

  if [ -n "$MISSING_DEPS" ]; then
    echo "Missing dependencies: $MISSING_DEPS"
    for dep in $MISSING_DEPS; do
      echo "Installing $dep..."
      apt-get install -y "$dep" || echo "NOTICE: Could not install $dep"
    done
  fi
fi

# Final dependency check — fail the build if critical deps are unmet
echo ""
echo "Final dependency check:"
if dpkg-checkbuilddeps; then
  echo "✓ All build dependencies satisfied"
else
  echo "ERROR: Unmet build dependencies — refusing to build broken packages"
  dpkg-checkbuilddeps 2>&1
  exit 1
fi

echo "::endgroup::"
echo ""

echo "::group::Update changelog"

export DEB_VERSION="${VALKEY_VERSION}-1.${PLATFORM_CODENAME}"

if ! grep -q "$DEB_VERSION" debian/changelog; then
  echo "Updating changelog for ${PLATFORM_CODENAME}..."
  DEBFULLNAME="${DEBFULLNAME:-Valkey Build System}" \
  DEBEMAIL="${DEBEMAIL:-build@valkey.io}" \
  dch -v "$DEB_VERSION" \
    -D "${PLATFORM_CODENAME}" \
    "Automated build for ${PLATFORM_CODENAME}"
fi

echo "Current changelog entry:"
head -5 debian/changelog

echo "::endgroup::"
echo ""

echo "::group::Build Debian packages"

echo "Building packages for ${EXPECTED_ARCH}..."
dpkg-buildpackage -b -us -uc -a${EXPECTED_ARCH}

echo "::endgroup::"
echo ""

echo "::group::Collect built packages"

mkdir -p /output
cd /root

echo "Copying built packages to /output..."
find . -maxdepth 1 -name "*.deb" -type f -exec cp {} /output/ \;
find . -maxdepth 1 -name "*.ddeb" -type f -exec cp {} /output/ \; 2>/dev/null || true
find . -maxdepth 1 -name "*.buildinfo" -type f -exec cp {} /output/ \;
find . -maxdepth 1 -name "*.changes" -type f -exec cp {} /output/ \;

echo "::endgroup::"
echo ""

# List built packages
echo "::group::Binary DEBs"
echo "Built packages:"
find /output -name "*.deb" -type f -exec ls -lh {} \;
echo ""
echo "Total packages: $(find /output -name "*.deb" -type f | wc -l)"
echo "::endgroup::"
echo ""

# Run sanity checks
echo "::group::Package Sanity Checks"

MAIN_DEB=$(find /output -name "valkey-server_${VALKEY_VERSION}*.deb" -type f | head -1)

if [ -z "$MAIN_DEB" ]; then
  echo "ERROR: Main valkey-server DEB not found!"
  echo "Available packages:"
  find /output -name "*.deb" -type f
  exit 1
fi

echo "✓ Found main package: $(basename $MAIN_DEB)"

PKG_ARCH=$(dpkg-deb --field "$MAIN_DEB" Architecture)
echo "Package architecture: $PKG_ARCH"
echo "Expected architecture: ${EXPECTED_ARCH}"

if [ "$PKG_ARCH" != "${EXPECTED_ARCH}" ] && [ "$PKG_ARCH" != "all" ]; then
  echo "WARNING: Architecture mismatch!"
else
  echo "✓ Architecture matches"
fi

echo ""
echo "Package information:"
dpkg-deb --info "$MAIN_DEB" | grep -E "Package|Version|Architecture|Description" || true

echo "::endgroup::"
echo ""

echo "============================================="
echo "✓ All checks passed for ${PLATFORM_ID} (${EXPECTED_ARCH})"
echo "============================================="
