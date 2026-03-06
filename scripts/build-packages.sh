#!/usr/bin/env bash
#
# Build Valkey DEB and RPM packages locally using Docker.
#
# The repo is mounted read-only; all build work happens inside the container
# in /build so nothing in the repo is modified.
#
# Usage:
#   ./scripts/build-packages.sh [OPTIONS]
#
# Options:
#   --version VER        Valkey version to build (default: 9.0.2)
#   --output  DIR        Output directory for packages (default: ./output)
#   --deb-only           Build only DEB packages
#   --rpm-only           Build only RPM packages
#   --platform PLATFORM  Build only for a specific platform (e.g. debian12, rocky9)
#   --test               Run test_packages.sh against built packages
#   --list-platforms     List all available platforms and exit
#   --help               Show this help message
#
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
VALKEY_VERSION="9.0.2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$(pwd)/output"
BUILD_DEB=true
BUILD_RPM=true
RUN_TESTS=false
FILTER_PLATFORM=""

# ── Platform definitions ─────────────────────────────────────────────────────
# DEB platforms: id|container|codename
DEB_PLATFORMS=(
  "debian11|debian:11|bullseye"
  "debian12|debian:12|bookworm"
  "debian13|debian:trixie|trixie"
  "ubuntu2204|ubuntu:22.04|jammy"
  "ubuntu2404|ubuntu:24.04|noble"
)

# RPM platforms: id|container|family|epel
RPM_PLATFORMS=(
  "opensuse-15.5|opensuse/leap:15.5|suse|none"
  "opensuse-15.6|opensuse/leap:15.6|suse|none"
  "el8|oraclelinux:8|rhel|oracle-epel-release-el8"
  "el9|oraclelinux:9|rhel|oracle-epel-release-el9"
  "el10|oraclelinux:10|rhel|oracle-epel-release-el10"
  "rocky8|rockylinux:8|rhel|epel-release"
  "rocky9|rockylinux:9|rhel|epel-release"
  "rocky10|rockylinux/rockylinux:10|rhel|epel-release"
  "alma8|almalinux:8|rhel|epel-release"
  "alma9|almalinux:9|rhel|epel-release"
  "alma10|almalinux:10|rhel|epel-release"
  "amzn2023|amazonlinux:2023|rhel|none"
  "fedora39|fedora:39|rhel|none"
  "fedora40|fedora:40|rhel|none"
  "fedora41|fedora:41|rhel|none"
)

# ── Functions ────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^$/s/^#//p' "$0"
  exit 0
}

list_platforms() {
  echo "DEB platforms:"
  for p in "${DEB_PLATFORMS[@]}"; do
    IFS='|' read -r id container codename <<< "$p"
    printf "  %-16s  %s\n" "$id" "$container"
  done
  echo ""
  echo "RPM platforms:"
  for p in "${RPM_PLATFORMS[@]}"; do
    IFS='|' read -r id container family epel <<< "$p"
    printf "  %-16s  %s  (%s)\n" "$id" "$container" "$family"
  done
  exit 0
}

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VALKEY_VERSION="$2"; shift 2 ;;
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --deb-only)   BUILD_RPM=false; shift ;;
    --rpm-only)   BUILD_DEB=false; shift ;;
    --test)       RUN_TESTS=true; shift ;;
    --platform)   FILTER_PLATFORM="$2"; shift 2 ;;
    --list-platforms) list_platforms ;;
    --help|-h)    usage ;;
    *)            err "Unknown option: $1" ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || err "Docker is required but not found in PATH"

if [[ ! -d "${REPO_DIR}/packaging/9.0.x" ]]; then
  err "Packaging directory not found at ${REPO_DIR}/packaging/9.0.x"
fi

mkdir -p "${OUTPUT_DIR}"

log "Valkey version : ${VALKEY_VERSION}"
log "Repo directory : ${REPO_DIR}"
log "Output directory: ${OUTPUT_DIR}"
echo ""

# ── Track results ────────────────────────────────────────────────────────────
PASSED=()
FAILED=()

# ── Build a single DEB ───────────────────────────────────────────────────────
build_deb() {
  local id="$1" container="$2" codename="$3"

  log "Building DEB: ${id} (${container})"

  local pkg_output="${OUTPUT_DIR}/deb/${id}"
  mkdir -p "${pkg_output}"

  if docker run --rm \
    -e VALKEY_VERSION="${VALKEY_VERSION}" \
    -e PLATFORM_CODENAME="${codename}" \
    -e DEBIAN_FRONTEND=noninteractive \
    -v "${REPO_DIR}:/repo:ro" \
    -v "${pkg_output}:/output" \
    "${container}" \
    bash -c '
      set -e

      echo "=== Building on $(cat /etc/os-release | grep PRETTY_NAME | cut -d\" -f2) ==="

      apt-get update -qq
      apt-get install -y -qq \
        build-essential debhelper devscripts fakeroot dpkg-dev \
        ca-certificates wget lsb-release \
        libjemalloc-dev libssl-dev libsystemd-dev \
        pkg-config tcl tcl-dev dh-exec 2>&1 | tail -1

      # Optional deps — non-fatal
      for pkg in libhiredis-dev liblua5.1-dev liblzf-dev lua-bitop-dev \
                 lua-cjson-dev pandoc tcl-tls python3-sphinx python3-sphinx-rtd-theme \
                 python3-yaml python3; do
        apt-get install -y -qq "$pkg" 2>/dev/null || true
      done

      # ── Work in /build ──
      mkdir -p /build && cd /build

      wget -q "https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}.tar.gz" \
        -O "valkey_${VALKEY_VERSION}.orig.tar.gz"
      tar xzf "valkey_${VALKEY_VERSION}.orig.tar.gz"

      cp -r /repo/packaging/9.0.x/debian "valkey-${VALKEY_VERSION}/debian"
      cd "valkey-${VALKEY_VERSION}"

      # Fix debhelper compat conflict
      grep -q "debhelper-compat" debian/control && rm -f debian/compat

      # Jemalloc workaround for Jammy
      if grep -q "jammy" /etc/os-release 2>/dev/null; then
        if [ ! -f "/usr/include/jemalloc/jemalloc.h" ]; then
          sed -i "s/USE_SYSTEM_JEMALLOC=yes/USE_SYSTEM_JEMALLOC=no/g" debian/rules || true
        fi
      fi

      # Install remaining build-deps
      if command -v mk-build-deps &>/dev/null; then
        mk-build-deps --install --remove \
          --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes" \
          debian/control 2>/dev/null || true
      fi

      # Update changelog
      DEB_VERSION="${VALKEY_VERSION}-1"
      if ! grep -q "$DEB_VERSION" debian/changelog; then
        DEBFULLNAME="Local Build" DEBEMAIL="dev@local" \
          dch -v "$DEB_VERSION" -D "${PLATFORM_CODENAME}" "Local build"
      fi

      # Build
      USE_D_FLAG=""
      dpkg-checkbuilddeps 2>/dev/null || USE_D_FLAG="-d"
      dpkg-buildpackage -b -us -uc ${USE_D_FLAG}

      # Collect
      cd /build
      find . -maxdepth 1 -name "*.deb" -exec cp {} /output/ \;
      find . -maxdepth 1 -name "*.ddeb" -exec cp {} /output/ \; 2>/dev/null || true

      echo ""
      echo "Built packages:"
      ls -lh /output/*.deb 2>/dev/null || echo "No packages found!"
    '; then
    log "DEB ${id}: OK"
    PASSED+=("deb:${id}")
  else
    log "DEB ${id}: FAILED"
    FAILED+=("deb:${id}")
  fi
  echo ""
}

# ── Build a single RPM ───────────────────────────────────────────────────────
build_rpm() {
  local id="$1" container="$2" family="$3" epel="$4"

  log "Building RPM: ${id} (${container})"

  local pkg_output="${OUTPUT_DIR}/rpm/${id}"
  mkdir -p "${pkg_output}"

  if docker run --rm \
    -e VALKEY_VERSION="${VALKEY_VERSION}" \
    -e PLATFORM_FAMILY="${family}" \
    -e PLATFORM_ID="${id}" \
    -e EPEL_PACKAGE="${epel}" \
    -v "${REPO_DIR}:/repo:ro" \
    -v "${pkg_output}:/output" \
    "${container}" \
    bash -c '
      set -e

      echo "=== Building on $(cat /etc/os-release | grep PRETTY_NAME | cut -d\" -f2) ==="

      if [ "$PLATFORM_FAMILY" = "suse" ]; then
        zypper refresh
        zypper install -y \
          rpm-build rpmdevtools gcc make jemalloc-devel libopenssl-devel \
          pkg-config procps python3 sysuser-shadow sysuser-tools tcl \
          systemd-devel systemd libsystemd0 wget tar gzip
        zypper install -y pandoc python3-yaml 2>/dev/null || true
      else
        PKG_MGR="dnf"
        command -v dnf &>/dev/null || PKG_MGR="yum"

        if [ "$EPEL_PACKAGE" != "none" ]; then
          $PKG_MGR install -y ${EPEL_PACKAGE} 2>/dev/null || true
        fi

        $PKG_MGR install -y \
          rpm-build rpmdevtools gcc make jemalloc-devel openssl-devel \
          pkgconfig procps-ng python3 systemd-devel systemd-rpm-macros \
          tcl wget tar gzip

        if [ "$PLATFORM_ID" = "amzn2023" ]; then
          $PKG_MGR install -y pandoc python3-pyyaml 2>/dev/null || true
        fi
      fi

      # ── Work in /build ──
      if [ "$PLATFORM_FAMILY" = "suse" ]; then
        BUILD_ROOT="/usr/src/packages"
      else
        BUILD_ROOT="/build/rpmbuild"
      fi

      mkdir -p ${BUILD_ROOT}/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

      # Copy spec
      if [ -f /repo/packaging/9.0.x/rpm/valkey-9.0.spec ]; then
        cp /repo/packaging/9.0.x/rpm/valkey-9.0.spec ${BUILD_ROOT}/SPECS/valkey.spec
      else
        cp /repo/packaging/9.0.x/rpm/valkey.spec ${BUILD_ROOT}/SPECS/valkey.spec
      fi

      # Copy supporting files
      for f in valkey.logrotate valkey.tmpfiles.d valkey.sysctl valkey-user.conf \
               macros.valkey migrate_redis_to_valkey.bash valkey-conf.patch \
               README.SUSE README.RHEL; do
        cp "/repo/packaging/9.0.x/rpm/${f}" ${BUILD_ROOT}/SOURCES/ 2>/dev/null || true
      done
      cp /repo/packaging/9.0.x/rpm/valkey*.service ${BUILD_ROOT}/SOURCES/ 2>/dev/null || true
      cp /repo/packaging/9.0.x/rpm/valkey*.target  ${BUILD_ROOT}/SOURCES/ 2>/dev/null || true

      # Download source
      cd ${BUILD_ROOT}/SOURCES
      wget -q "https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}/valkey-${VALKEY_VERSION}.tar.gz"

      # Docs tarball (dummy if download fails)
      wget -q "https://github.com/valkey-io/valkey-doc/archive/9.0.0/valkey-doc-9.0.0.tar.gz" || {
        mkdir -p valkey-doc-9.0.0
        tar czf valkey-doc-9.0.0.tar.gz valkey-doc-9.0.0
        rm -rf valkey-doc-9.0.0
      }

      # Platform macros
      if [ "$PLATFORM_FAMILY" = "suse" ]; then
        echo "%is_suse 1" > ~/.rpmmacros
      else
        echo "%is_rhel 1" > ~/.rpmmacros
      fi

      # Build
      cd ${BUILD_ROOT}/SPECS

      if [[ "$PLATFORM_ID" == fedora* ]]; then
        sed -i "/^BuildRequires:.*pandoc/d" valkey.spec
        sed -i "/^BuildRequires:.*python3-pyyaml/d" valkey.spec
        rpmbuild --define "_topdir ${BUILD_ROOT}" -ba --without doc valkey.spec
      elif command -v pandoc &>/dev/null; then
        rpmbuild --define "_topdir ${BUILD_ROOT}" -ba valkey.spec
      else
        sed -i "/^BuildRequires:.*pandoc/d" valkey.spec
        sed -i "/^BuildRequires:.*python3-pyyaml/d" valkey.spec
        sed -i "/^BuildRequires:.*python3-yaml/d" valkey.spec
        rpmbuild --define "_topdir ${BUILD_ROOT}" -ba --without docs valkey.spec
      fi

      # Collect
      find ${BUILD_ROOT}/RPMS  -name "*.rpm" -exec cp {} /output/ \;
      find ${BUILD_ROOT}/SRPMS -name "*.rpm" -exec cp {} /output/ \;

      echo ""
      echo "Built packages:"
      ls -lh /output/*.rpm 2>/dev/null || echo "No packages found!"
    '; then
    log "RPM ${id}: OK"
    PASSED+=("rpm:${id}")
  else
    log "RPM ${id}: FAILED"
    FAILED+=("rpm:${id}")
  fi
  echo ""
}

# ── Test packages in a fresh container ────────────────────────────────────────
test_deb() {
  local id="$1" container="$2"
  local pkg_dir="${OUTPUT_DIR}/deb/${id}"

  if [[ ! -d "${pkg_dir}" ]] || ! ls "${pkg_dir}"/*.deb &>/dev/null; then
    log "TEST DEB ${id}: SKIP (no packages found)"
    return
  fi

  log "Testing DEB: ${id} (${container})"

  if docker run --rm \
    --privileged \
    -e DEBIAN_FRONTEND=noninteractive \
    -e VALKEY_VERSION="${VALKEY_VERSION}" \
    -v "${REPO_DIR}:/repo:ro" \
    -v "${pkg_dir}:/packages:ro" \
    "${container}" \
    bash -c '
      set -e
      apt-get update -qq
      apt-get install -y -qq procps systemctl 2>/dev/null || true
      bash /repo/scripts/test_packages.sh --pkg-dir=/packages --version=${VALKEY_VERSION}
    '; then
    log "TEST DEB ${id}: OK"
    PASSED+=("test-deb:${id}")
  else
    log "TEST DEB ${id}: FAILED"
    FAILED+=("test-deb:${id}")
  fi
  echo ""
}

test_rpm() {
  local id="$1" container="$2"
  local pkg_dir="${OUTPUT_DIR}/rpm/${id}"

  if [[ ! -d "${pkg_dir}" ]] || ! ls "${pkg_dir}"/*.rpm &>/dev/null; then
    log "TEST RPM ${id}: SKIP (no packages found)"
    return
  fi

  log "Testing RPM: ${id} (${container})"

  if docker run --rm \
    --privileged \
    -e VALKEY_VERSION="${VALKEY_VERSION}" \
    -v "${REPO_DIR}:/repo:ro" \
    -v "${pkg_dir}:/packages:ro" \
    "${container}" \
    bash -c '
      set -e
      bash /repo/scripts/test_packages.sh --pkg-dir=/packages --version=${VALKEY_VERSION}
    '; then
    log "TEST RPM ${id}: OK"
    PASSED+=("test-rpm:${id}")
  else
    log "TEST RPM ${id}: FAILED"
    FAILED+=("test-rpm:${id}")
  fi
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

# Build DEBs
if ${BUILD_DEB}; then
  for p in "${DEB_PLATFORMS[@]}"; do
    IFS='|' read -r id container codename <<< "$p"
    if [[ -n "${FILTER_PLATFORM}" && "${id}" != "${FILTER_PLATFORM}" ]]; then
      continue
    fi
    build_deb "$id" "$container" "$codename"
  done
fi

# Build RPMs
if ${BUILD_RPM}; then
  for p in "${RPM_PLATFORMS[@]}"; do
    IFS='|' read -r id container family epel <<< "$p"
    if [[ -n "${FILTER_PLATFORM}" && "${id}" != "${FILTER_PLATFORM}" ]]; then
      continue
    fi
    build_rpm "$id" "$container" "$family" "$epel"
  done
fi

# ── Run tests ────────────────────────────────────────────────────────────────
if ${RUN_TESTS}; then
  echo ""
  log "Running package tests..."
  echo ""

  if ${BUILD_DEB}; then
    for p in "${DEB_PLATFORMS[@]}"; do
      IFS='|' read -r id container codename <<< "$p"
      if [[ -n "${FILTER_PLATFORM}" && "${id}" != "${FILTER_PLATFORM}" ]]; then
        continue
      fi
      test_deb "$id" "$container"
    done
  fi

  if ${BUILD_RPM}; then
    for p in "${RPM_PLATFORMS[@]}"; do
      IFS='|' read -r id container family epel <<< "$p"
      if [[ -n "${FILTER_PLATFORM}" && "${id}" != "${FILTER_PLATFORM}" ]]; then
        continue
      fi
      test_rpm "$id" "$container"
    done
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "============================================="
echo "BUILD SUMMARY"
echo "============================================="
echo ""

if [[ ${#PASSED[@]} -gt 0 ]]; then
  echo "Passed (${#PASSED[@]}):"
  for p in "${PASSED[@]}"; do echo "  OK   $p"; done
  echo ""
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do echo "  FAIL $f"; done
  echo ""
  echo "Output directory: ${OUTPUT_DIR}"
  exit 1
fi

echo "All builds passed!"
echo "Output directory: ${OUTPUT_DIR}"
echo ""
find "${OUTPUT_DIR}" -type f \( -name "*.deb" -o -name "*.rpm" \) | sort | while read -r f; do
  echo "  $(du -h "$f" | cut -f1)  ${f#${OUTPUT_DIR}/}"
done
