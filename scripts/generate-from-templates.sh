#!/bin/bash
# Generate version-specific packaging files from templates.
#
# Usage:
#   generate-from-templates.sh --type rpm|deb --version <VALKEY_VERSION> \
#     --templates-dir <path> --output-dir <path>

set -e

TYPE=""
VERSION=""
TEMPLATES_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)       TYPE="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --templates-dir) TEMPLATES_DIR="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TYPE" ] || [ -z "$VERSION" ] || [ -z "$TEMPLATES_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: $0 --type rpm|deb --version <VERSION> --templates-dir <DIR> --output-dir <DIR>" >&2
  exit 1
fi

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

echo "Generating ${TYPE} files for Valkey ${VERSION} (major=${MAJOR_VERSION}, doc=${DOC_VERSION})"

if [ "$TYPE" = "deb" ]; then
  # Process control template
  if [ -f "${TEMPLATES_DIR}/control.template" ]; then
    sed "s/@@MAJOR_VERSION@@/${MAJOR_VERSION}/g" \
      "${TEMPLATES_DIR}/control.template" > "${OUTPUT_DIR}/control"
    echo "  Generated: control"
  fi

  # Process rules template
  if [ -f "${TEMPLATES_DIR}/rules.template" ]; then
    sed "s/@@DOC_VERSION@@/${DOC_VERSION}/g" \
      "${TEMPLATES_DIR}/rules.template" > "${OUTPUT_DIR}/rules"
    chmod +x "${OUTPUT_DIR}/rules"
    echo "  Generated: rules"
  fi

elif [ "$TYPE" = "rpm" ]; then
  # Determine bundled dependency based on major version
  if [ "$MAJOR_VERSION" -ge 9 ]; then
    BUNDLED_DEP_NAME="libvalkey"
    BUNDLED_DEP_PROVIDES="Provides:       bundled(libvalkey) = 1.0.0"
    BUNDLED_DEP_DIR="libvalkey"
  else
    BUNDLED_DEP_NAME="hiredis"
    BUNDLED_DEP_PROVIDES="Provides:       bundled(hiredis)"
    BUNDLED_DEP_DIR="hiredis"
  fi

  # Determine the spec version (use the version from the existing spec, not the input version,
  # since build-rpm.sh overrides Version: separately)
  SPEC_VERSION="${VERSION}"

  # Load changelog
  CHANGELOG_FILE="${TEMPLATES_DIR}/changelog-${MAJOR_VERSION}.x"
  if [ -f "$CHANGELOG_FILE" ]; then
    CHANGELOG=$(cat "$CHANGELOG_FILE")
  else
    echo "WARNING: No changelog file found at ${CHANGELOG_FILE}" >&2
    CHANGELOG="* $(date +'%a %b %d %Y') Build System <build@valkey.io> - ${VERSION}-1"$'\n'"- Automated build"
  fi

  # Process spec template
  if [ -f "${TEMPLATES_DIR}/valkey.spec.template" ]; then
    # Use a temp file for multi-step sed to avoid issues with special chars
    TMPFILE=$(mktemp)

    sed \
      -e "s/@@MAJOR_VERSION@@/${MAJOR_VERSION}/g" \
      -e "s/@@SPEC_VERSION@@/${SPEC_VERSION}/g" \
      -e "s/@@BUNDLED_DEP_NAME@@/${BUNDLED_DEP_NAME}/g" \
      -e "s|@@BUNDLED_DEP_PROVIDES@@|${BUNDLED_DEP_PROVIDES}|g" \
      -e "s/@@BUNDLED_DEP_DIR@@/${BUNDLED_DEP_DIR}/g" \
      "${TEMPLATES_DIR}/valkey.spec.template" > "$TMPFILE"

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
    echo "  Generated: valkey.spec"
  fi

else
  echo "ERROR: Unknown type '${TYPE}'. Use 'rpm' or 'deb'." >&2
  exit 1
fi

echo "Template processing complete."
