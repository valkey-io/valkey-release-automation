#!/bin/bash
# Generate version-specific packaging files from templates.
#
# Usage:
#   generate-from-templates.sh --type rpm|deb|apk --version <VALKEY_VERSION> \
#     --templates-dir <path> --output-dir <path> \
#     [--override-templates-dir <path>]
#
# --override-templates-dir is optional. When set, the renderer looks there
# first for each template file (control.template, rules.template,
# valkey.spec.template, APKBUILD.template, changelog-<MAJOR>.<MINOR>) and
# falls back to --templates-dir if the file isn't present in the override
# dir. This lets a single version ship a tweaked template under
# packaging/<version>/<type>/ without duplicating the shared templates used
# by every other version.

set -e

TYPE=""
VERSION=""
TEMPLATES_DIR=""
OUTPUT_DIR=""
OVERRIDE_TEMPLATES_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)       TYPE="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --templates-dir) TEMPLATES_DIR="$2"; shift 2 ;;
    --override-templates-dir) OVERRIDE_TEMPLATES_DIR="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TYPE" ] || [ -z "$VERSION" ] || [ -z "$TEMPLATES_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: $0 --type rpm|deb|apk --version <VERSION> --templates-dir <DIR> --output-dir <DIR> [--override-templates-dir <DIR>]" >&2
  exit 1
fi

# Return the path to a template file, preferring the override dir if present.
# Usage: tpl=$(resolve_template <filename>)
resolve_template() {
  local name="$1"
  if [ -n "$OVERRIDE_TEMPLATES_DIR" ] && [ -f "${OVERRIDE_TEMPLATES_DIR}/${name}" ]; then
    echo "${OVERRIDE_TEMPLATES_DIR}/${name}"
  else
    echo "${TEMPLATES_DIR}/${name}"
  fi
}

# Derive version components
MAJOR_VERSION="${VERSION%%.*}"
# DOC_VERSION: MAJOR.MINOR.0
MINOR_PART="${VERSION#*.}"
MINOR="${MINOR_PART%%.*}"
DOC_VERSION="${MAJOR_VERSION}.${MINOR}.0"

# Templates are only for major version >= 8 (7.x maintains files directly)
if [ "$MAJOR_VERSION" -lt 8 ]; then
  echo "Skipping template generation for major version ${MAJOR_VERSION} (templates are for 8.x+ only)"
  exit 0
fi

# Determine extra build flags based on version
# USE_FAST_FLOAT is supported in Valkey 8.1+
EXTRA_BUILD_FLAGS=""
if [ "$MAJOR_VERSION" -gt 8 ] || { [ "$MAJOR_VERSION" -eq 8 ] && [ "$MINOR" -ge 1 ]; }; then
  EXTRA_BUILD_FLAGS=" USE_FAST_FLOAT=yes"
fi

# Bundled client library: hiredis before 9.0, libvalkey from 9.0 on.
if [ "$MAJOR_VERSION" -ge 9 ]; then
  BUNDLED_DEP_NAME="libvalkey"
  BUNDLED_DEP_PROVIDES="Provides:       bundled(libvalkey) = 1.0.0"
  BUNDLED_DEP_DIR="libvalkey"
else
  BUNDLED_DEP_NAME="hiredis"
  BUNDLED_DEP_PROVIDES="Provides:       bundled(hiredis)"
  BUNDLED_DEP_DIR="hiredis"
fi

echo "Generating ${TYPE} files for Valkey ${VERSION} (major=${MAJOR_VERSION}, doc=${DOC_VERSION})"

if [ "$TYPE" = "deb" ]; then
  # Process control template
  control_tpl="$(resolve_template control.template)"
  if [ -f "$control_tpl" ]; then
    sed -e "s/@@MAJOR_VERSION@@/${MAJOR_VERSION}/g" \
        -e "s/@@MINOR@@/${MINOR}/g" \
      "$control_tpl" > "${OUTPUT_DIR}/control"
    echo "  Generated: control (from $control_tpl)"
  fi

  # Process rules template
  rules_tpl="$(resolve_template rules.template)"
  if [ -f "$rules_tpl" ]; then
    sed -e "s/@@DOC_VERSION@@/${DOC_VERSION}/g" \
        -e "s/@@EXTRA_BUILD_FLAGS@@/${EXTRA_BUILD_FLAGS}/g" \
      "$rules_tpl" > "${OUTPUT_DIR}/rules"
    chmod +x "${OUTPUT_DIR}/rules"
    echo "  Generated: rules (from $rules_tpl)"
  fi

elif [ "$TYPE" = "rpm" ]; then
  # Load changelog (override dir wins if it ships its own fragment)
  CHANGELOG_FILE="$(resolve_template "changelog-${MAJOR_VERSION}.${MINOR}")"
  if [ -f "$CHANGELOG_FILE" ]; then
    CHANGELOG=$(cat "$CHANGELOG_FILE")
    echo "  Using changelog: $CHANGELOG_FILE"
  else
    echo "WARNING: No changelog file found at ${CHANGELOG_FILE}" >&2
    CHANGELOG="* $(date +'%a %b %d %Y') Build System <build@valkey.io> - ${VERSION}-1"$'\n'"- Automated build"
  fi

  # Process spec template
  spec_tpl="$(resolve_template valkey.spec.template)"
  if [ -f "$spec_tpl" ]; then
    # Use a temp file for multi-step sed to avoid issues with special chars
    TMPFILE=$(mktemp)

    # For RPM, EXTRA_BUILD_FLAGS needs a leading backslash-newline if non-empty
    RPM_EXTRA_FLAGS=""
    if [ -n "$EXTRA_BUILD_FLAGS" ]; then
      RPM_EXTRA_FLAGS=" \\\\\n    ${EXTRA_BUILD_FLAGS# }"
    fi

    sed \
      -e "s/@@MAJOR_VERSION@@/${MAJOR_VERSION}/g" \
      -e "s/@@MINOR@@/${MINOR}/g" \
      -e "s/@@SPEC_VERSION@@/${VERSION}/g" \
      -e "s/@@BUNDLED_DEP_NAME@@/${BUNDLED_DEP_NAME}/g" \
      -e "s|@@BUNDLED_DEP_PROVIDES@@|${BUNDLED_DEP_PROVIDES}|g" \
      -e "s/@@BUNDLED_DEP_DIR@@/${BUNDLED_DEP_DIR}/g" \
      -e "s|@@EXTRA_BUILD_FLAGS@@|${RPM_EXTRA_FLAGS}|g" \
      "$spec_tpl" > "$TMPFILE"

    # Replace @@CHANGELOG@@ with actual changelog content
    # Use awk to handle multi-line replacement
    awk -v changelog="$CHANGELOG" '{
      if ($0 == "@@CHANGELOG@@") {
        print changelog
      } else {
        print
      }
    }' "$TMPFILE" > "${OUTPUT_DIR}/valkey.spec"

    rm -f "$TMPFILE"
    echo "  Generated: valkey.spec (from $spec_tpl)"
  fi

elif [ "$TYPE" = "apk" ]; then
  # The values below end up in a shell script (the APKBUILD) that abuild
  # sources as root, so only accept release-formatted versions.
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    echo "ERROR: invalid version '${VERSION}' (expected x.y.z or x.y.z-rcN)" >&2
    exit 1
  fi
  # Alpine orders x.y.z_rcN before x.y.z; the upstream tarball keeps -rcN.
  PKGVER="${VERSION/-rc/_rc}"
  APK_BUILD_FLAGS="${EXTRA_BUILD_FLAGS}"
  APK_MAKEDEPENDS=""
  # Zstandard streaming compression (9.2+) links libzstd statically.
  if [ "$MAJOR_VERSION" -gt 9 ] || { [ "$MAJOR_VERSION" -eq 9 ] && [ "$MINOR" -ge 2 ]; }; then
    APK_BUILD_FLAGS="${APK_BUILD_FLAGS} BUILD_ZSTD=yes"
    APK_MAKEDEPENDS=" zstd-dev zstd-static"
  fi

  apkbuild_tpl="$(resolve_template APKBUILD.template)"
  if [ ! -f "$apkbuild_tpl" ]; then
    echo "ERROR: APKBUILD template not found at ${apkbuild_tpl}" >&2
    exit 1
  fi
  sed \
    -e "s/@@PKGVER@@/${PKGVER}/g" \
    -e "s/@@SRCVER@@/${VERSION}/g" \
    -e "s/@@DOC_VERSION@@/${DOC_VERSION}/g" \
    -e "s/@@BUNDLED_DEP_NAME@@/${BUNDLED_DEP_NAME}/g" \
    -e "s/@@BUNDLED_DEP_DIR@@/${BUNDLED_DEP_DIR}/g" \
    -e "s/@@EXTRA_BUILD_FLAGS@@/${APK_BUILD_FLAGS}/g" \
    -e "s/@@EXTRA_MAKEDEPENDS@@/${APK_MAKEDEPENDS}/g" \
    "$apkbuild_tpl" > "${OUTPUT_DIR}/APKBUILD"
  if grep -q '@@[A-Z_]*@@' "${OUTPUT_DIR}/APKBUILD"; then
    echo "ERROR: unresolved placeholders in APKBUILD:" >&2
    grep -n '@@[A-Z_]*@@' "${OUTPUT_DIR}/APKBUILD" >&2
    exit 1
  fi
  echo "  Generated: APKBUILD (from $apkbuild_tpl)"

else
  echo "ERROR: Unknown type '${TYPE}'. Use 'rpm', 'deb' or 'apk'." >&2
  exit 1
fi

echo "Template processing complete."
