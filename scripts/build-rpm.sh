#!/bin/bash
set -e

echo "============================================="
echo "Building on $(cat /etc/os-release | grep PRETTY_NAME | cut -d\" -f2)"
echo "Architecture: ${EXPECTED_ARCH}"
echo "Valkey Version: ${VALKEY_VERSION}"
echo "============================================="
echo ""

echo "::group::Install git and build dependencies"

if [ "$PLATFORM_FAMILY" = "suse" ]; then
  zypper refresh
  zypper install -y \
    rpm-build \
    rpmdevtools \
    gcc \
    make \
    jemalloc-devel \
    libopenssl-devel \
    pkg-config \
    procps \
    python3 \
    sysuser-shadow \
    sysuser-tools \
    tcl \
    systemd-devel \
    systemd \
    libsystemd0 \
    wget \
    tar \
    gzip

  # Try to install pandoc for docs on SUSE
  if zypper install -y pandoc python3-yaml; then
    echo "✓ pandoc installed"
  else
    echo "⚠ pandoc installation failed"
  fi

else
  # RHEL-based
  if command -v dnf &> /dev/null; then
    PKG_MGR="dnf"
  else
    PKG_MGR="yum"
  fi

  # Install EPEL if needed
  if [ "$EPEL_PACKAGE" != "none" ] && [ "$EPEL_PACKAGE" != "skip" ]; then
    echo "Installing EPEL: ${EPEL_PACKAGE}"
    $PKG_MGR install -y ${EPEL_PACKAGE} || echo "EPEL installation failed (non-critical)"
  elif [ "$EPEL_PACKAGE" = "skip" ]; then
    echo "Skipping EPEL (not available for this platform yet)"
  else
    echo "Skipping EPEL (not needed for this platform)"
  fi

  # Install build dependencies
  $PKG_MGR install -y \
    rpm-build \
    rpmdevtools \
    gcc \
    make \
    jemalloc-devel \
    openssl \
    openssl-devel \
    pkgconfig \
    procps-ng \
    python3 \
    systemd-devel \
    systemd-rpm-macros \
    tcl \
    wget \
    tar \
    gzip

  # Only Amazon Linux has pandoc for docs
  if [ "$PLATFORM_ID" = "amzn2023" ]; then
    $PKG_MGR install -y pandoc python3-pyyaml || echo "pandoc not available"
  fi
fi

echo "::endgroup::"
echo ""

echo "::group::Setup RPM build environment"

# Merge common + version-specific packaging files
mkdir -p /packaging
cp -r /packaging-common/* /packaging/
cp -r /packaging-override/* /packaging/
PACKAGING_DIR="/packaging"

# Generate files from templates if templates are mounted
if [ -d "/packaging-templates" ]; then
  echo "Processing RPM templates..."
  bash /scripts/generate-from-templates.sh \
    --type rpm \
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
ls -la "$PACKAGING_DIR"

# Detect rpmbuild directory (SUSE uses /usr/src/packages, others use ~/rpmbuild)
if [ "$PLATFORM_FAMILY" = "suse" ]; then
  BUILD_ROOT="/usr/src/packages"
else
  BUILD_ROOT="$HOME/rpmbuild"
fi

echo "Using build root: $BUILD_ROOT"

# Create rpmbuild structure
mkdir -p $BUILD_ROOT/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Copy spec file
if [ -f "$PACKAGING_DIR/valkey.spec" ]; then
  cp "$PACKAGING_DIR/valkey.spec" $BUILD_ROOT/SPECS/valkey.spec
else
  echo "ERROR: Cannot find spec file"
  ls -la "$PACKAGING_DIR"
  exit 1
fi

# Copy all source files
cp "$PACKAGING_DIR"/valkey.logrotate $BUILD_ROOT/SOURCES/ || echo "No logrotate file"
cp "$PACKAGING_DIR"/valkey*.service $BUILD_ROOT/SOURCES/ || echo "No service files"
cp "$PACKAGING_DIR"/valkey*.target $BUILD_ROOT/SOURCES/ || echo "No target files"
cp "$PACKAGING_DIR"/valkey.tmpfiles.d $BUILD_ROOT/SOURCES/ || echo "No tmpfiles"
cp "$PACKAGING_DIR"/valkey.sysctl $BUILD_ROOT/SOURCES/ || echo "No sysctl"
cp "$PACKAGING_DIR"/valkey-user.conf $BUILD_ROOT/SOURCES/ || echo "No user conf"
cp "$PACKAGING_DIR"/macros.valkey $BUILD_ROOT/SOURCES/ || echo "No macros"
cp "$PACKAGING_DIR"/migrate_redis_to_valkey.bash $BUILD_ROOT/SOURCES/ || echo "No migration script"
cp "$PACKAGING_DIR"/valkey-conf.patch $BUILD_ROOT/SOURCES/ || echo "No conf patch"

# Copy appropriate README (copy both to be safe, spec will use correct one)
cp "$PACKAGING_DIR"/README.SUSE $BUILD_ROOT/SOURCES/ 2>/dev/null || echo "No README.SUSE (not critical)"
cp "$PACKAGING_DIR"/README.RHEL $BUILD_ROOT/SOURCES/ 2>/dev/null || echo "No README.RHEL (not critical)"

# Override version fields in spec to match input version
sed -i "s/^Version:.*/Version:        ${VALKEY_VERSION}/" $BUILD_ROOT/SPECS/valkey.spec
DOC_VERSION=$(echo "${VALKEY_VERSION}" | sed "s/\.[0-9]*$/.0/")
sed -i "s/^%global doc_version.*/%global doc_version ${DOC_VERSION}/" $BUILD_ROOT/SPECS/valkey.spec

echo "::endgroup::"
echo ""

echo "::group::Download Valkey source"

cd $BUILD_ROOT/SOURCES

# Download main source if not present
if [ ! -f "valkey-${VALKEY_VERSION}.tar.gz" ]; then
  echo "Downloading Valkey ${VALKEY_VERSION}..."
  wget -q https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}/valkey-${VALKEY_VERSION}.tar.gz
fi

# Extract doc_version from spec file
DOC_VERSION=$(grep "^%global doc_version" $BUILD_ROOT/SPECS/valkey.spec | awk '{print $3}' || echo "${VALKEY_VERSION}")
# If doc_version references %{version}, use VALKEY_VERSION
if [ "$DOC_VERSION" = "%{version}" ] || [ -z "$DOC_VERSION" ]; then
  DOC_VERSION="${VALKEY_VERSION}"
fi

# Always download docs (spec %prep needs it even if not building docs)
if [ ! -f "valkey-doc-${DOC_VERSION}.tar.gz" ]; then
  echo "Downloading Valkey documentation (${DOC_VERSION})..."
  wget -q https://github.com/valkey-io/valkey-doc/archive/${DOC_VERSION}/valkey-doc-${DOC_VERSION}.tar.gz || {
    echo "Doc download failed, creating dummy tarball..."
    mkdir -p valkey-doc-${DOC_VERSION}
    tar czf valkey-doc-${DOC_VERSION}.tar.gz valkey-doc-${DOC_VERSION}
    rm -rf valkey-doc-${DOC_VERSION}
  }
fi

echo "::endgroup::"
echo ""

echo "::group::Build RPM"

cd $BUILD_ROOT/SPECS

# Define platform macros for RPM
if [ "$PLATFORM_FAMILY" = "suse" ]; then
  echo "%is_suse 1" > ~/.rpmmacros
else
  echo "%is_rhel 1" > ~/.rpmmacros
fi

# Build RPM - use --without doc if pandoc not installed
if [[ "$PLATFORM_ID" == fedora* ]]; then
  echo "Building without docs for Fedora..."
  sed -i "/^BuildRequires:.*pandoc/d" valkey.spec
  sed -i "/^BuildRequires:.*python3-pyyaml/d" valkey.spec
  rpmbuild -ba --without doc valkey.spec
elif command -v pandoc &> /dev/null; then
  echo "Building with documentation (pandoc is installed)"
  rpmbuild -ba valkey.spec
else
  echo "Building without documentation (pandoc not available)"
  sed -i "/^BuildRequires:.*pandoc/d" valkey.spec
  sed -i "/^BuildRequires:.*python3-pyyaml/d" valkey.spec
  sed -i "/^BuildRequires:.*python3-yaml/d" valkey.spec
  rpmbuild -ba --without docs valkey.spec
fi

echo "::endgroup::"
echo ""

# Copy RPMs to output
mkdir -p /output
find $BUILD_ROOT/RPMS -name "*.rpm" -type f -exec cp {} /output/ \;
find $BUILD_ROOT/SRPMS -name "*.rpm" -type f -exec cp {} /output/ \;

# List built packages
echo "::group::Binary RPMs"
find $BUILD_ROOT/RPMS -name "*.rpm" -type f -exec ls -lh {} \;
echo "::endgroup::"
echo ""

echo "::group::Source RPMs"
find $BUILD_ROOT/SRPMS -name "*.rpm" -type f -exec ls -lh {} \;
echo "::endgroup::"
echo ""

# Run sanity checks
echo "::group::Package Sanity Checks"

MAIN_RPM=$(find $BUILD_ROOT/RPMS -name "valkey-${VALKEY_VERSION}*.rpm" -type f | grep -v devel | grep -v compat | head -1)

if [ -z "$MAIN_RPM" ]; then
  echo "ERROR: Main valkey RPM not found!"
  exit 1
fi

echo "Checking: $MAIN_RPM"
echo "Architecture: ${EXPECTED_ARCH}"
echo ""

# 1. RPM Query Test
echo "1. RPM Query Test..."
rpm -qip "$MAIN_RPM" || exit 1
echo "   ✓ RPM is valid"
echo ""

# 2. Required Files Test
echo "2. Required Files Test..."
for file in /usr/bin/valkey-server /usr/bin/valkey-cli; do
  if rpm -qlp "$MAIN_RPM" | grep -q "^${file}$"; then
    echo "   ✓ $file"
  else
    echo "   ✗ MISSING: $file"
    exit 1
  fi
done
echo ""

# 3. Architecture Check
echo "3. Architecture Check..."
ARCH=$(rpm -qp --qf "%{ARCH}" "$MAIN_RPM")
if [ "$ARCH" = "${EXPECTED_ARCH}" ] || [ "$ARCH" = "noarch" ]; then
  echo "   ✓ Architecture: $ARCH"
else
  echo "   ✗ Wrong architecture: $ARCH (expected: ${EXPECTED_ARCH})"
  exit 1
fi
echo ""

# 4. Package Size Check
echo "4. Package Size Check..."
SIZE=$(du -h "$MAIN_RPM" | cut -f1)
SIZE_BYTES=$(stat -c%s "$MAIN_RPM")
echo "   Package size: $SIZE"
if [ $SIZE_BYTES -lt 500000 ]; then
  echo "   ✗ Package too small"
  exit 1
else
  echo "   ✓ Package size reasonable"
fi
echo ""

echo "::endgroup::"
echo ""

echo "============================================="
echo "✓ All checks passed for ${PLATFORM_ID} (${EXPECTED_ARCH})"
echo "============================================="
