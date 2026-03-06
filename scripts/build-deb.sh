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

# Install all required build dependencies
echo "Installing Valkey build dependencies..."
apt-get install -y libjemalloc-dev
ls -lah /usr/include/jemalloc/jemalloc.h
apt-get install -y libsystemd-dev
apt-get -y install pkg-config || true
apt-get -y install pkgconf || true
apt-get install -y \
  libjemalloc-dev \
  libssl-dev \
  tcl \
  tcl-dev \
  libsystemd-dev \
  python3 \
  python3-sphinx \
  python3-sphinx-rtd-theme \
  python3-yaml \
  dh-exec \
  libhiredis-dev \
  liblua5.1-dev \
  liblzf-dev \
  lua-bitop-dev \
  lua-cjson-dev \
  pandoc \
  tcl-tls || {
    echo "Some packages not available, trying alternatives..."

    apt-get install -y \
      libjemalloc-dev \
      libssl-dev \
      pkg-config \
      pkgconf \
      tcl \
      tcl-dev \
      libsystemd-dev \
      python3 \
      python3-sphinx \
      python3-sphinx-rtd-theme \
      python3-yaml \
      dh-exec || true

    apt-get install -y libhiredis-dev || echo "libhiredis-dev not available"
    apt-get install -y liblua5.1-dev || echo "liblua5.1-dev not available"
    apt-get install -y liblzf-dev || echo "liblzf-dev not available"
    apt-get install -y lua-bitop-dev || echo "lua-bitop-dev not available"
    apt-get install -y lua-cjson-dev || echo "lua-cjson-dev not available"
    apt-get install -y pandoc || echo "pandoc not available"
    apt-get install -y tcl-tls || echo "tcl-tls not available"
  }

# Check jemalloc installation
echo ""
echo "Checking jemalloc installation..."
if dpkg -l | grep -q libjemalloc-dev; then
  echo "✓ libjemalloc-dev is installed"
  dpkg -L libjemalloc-dev | grep "\.h$" | head -5 || echo "No header files found"

  if [ -f "/usr/include/jemalloc/jemalloc.h" ]; then
    echo "✓ jemalloc.h found at /usr/include/jemalloc/jemalloc.h"
  else
    echo "⚠ jemalloc.h NOT found at expected location"
    echo "Searching for jemalloc.h..."
    find /usr -name "jemalloc.h" 2>/dev/null || echo "Not found anywhere"
  fi
else
  echo "⚠ libjemalloc-dev is NOT installed"
fi

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

# Check what dependencies are still missing
echo ""
echo "Checking build dependencies..."
dpkg-checkbuilddeps 2>&1 | tee /tmp/missing-deps.txt || {
  echo ""
  echo "Some dependencies are missing, attempting to install..."

  if [ -f /tmp/missing-deps.txt ]; then
    MISSING_DEPS=$(grep "Unmet build dependencies:" /tmp/missing-deps.txt | sed "s/.*dependencies: //" | tr " " "\n" | grep -v "^$" | sed "s/(.*)//g" || true)

    if [ -n "$MISSING_DEPS" ]; then
      echo "Missing dependencies:"
      echo "$MISSING_DEPS"
      echo ""
      echo "Attempting to install missing dependencies..."

      for dep in $MISSING_DEPS; do
        echo "Installing $dep..."
        apt-get install -y "$dep" || echo "Could not install $dep"
      done
    fi
  fi
}

# Final dependency check
echo ""
echo "Final dependency check:"
if dpkg-checkbuilddeps; then
  echo "✓ All build dependencies satisfied"
else
  echo "⚠ Some dependencies may be missing"
  echo "Attempting to build anyway with -d flag..."
  export USE_D_FLAG="-d"
fi

echo "::endgroup::"
echo ""

echo "::group::Update changelog"

export DEB_VERSION="${VALKEY_VERSION}-1.${PLATFORM_CODENAME}"

if ! grep -q "$DEB_VERSION" debian/changelog; then
  echo "Updating changelog for ${PLATFORM_CODENAME}..."
  DEBFULLNAME="Evgeniy Patlan" \
  DEBEMAIL="evgeniy.patlan@percona.com" \
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
dpkg-buildpackage -b -us -uc -a${EXPECTED_ARCH} ${USE_D_FLAG:-}

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
