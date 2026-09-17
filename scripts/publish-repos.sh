#!/bin/bash
# Generate GitHub Pages site with install instructions and GPG key.
# Packages are hosted on S3; this script only builds the static site.
# Usage: publish-repos.sh <version> <gpg_fingerprint> <repo_url> <pages_url> <s3_bucket> <s3_region> <site_dir> <template_dir>
set -euo pipefail

VERSION="$1"
GPG_KEY="$2"
REPO_URL="$3"
PAGES_URL="$4"
S3_BUCKET="$5"
S3_REGION="$6"
SITE_DIR="$7"
TEMPLATE_DIR="$8"

MAJOR="${VERSION%%.*}"
MINOR_PART="${VERSION#*.}"
MINOR="${MINOR_PART%%.*}"

echo "Generating site: version=${VERSION}, major=${MAJOR}, minor=${MINOR}"
echo "  Repo URL (S3):       ${REPO_URL}"
echo "  Pages URL (GH Pages): ${PAGES_URL}"

mkdir -p "${SITE_DIR}"

################################################################################
# Detect available versions from S3 bucket
################################################################################
echo "Listing versions from s3://${S3_BUCKET}/packaging/..."
AVAILABLE_VERSIONS=""
# Fail closed on discovery errors: a transient listing failure must abort
# rather than publish an index.html that hides every other release line.
# aws s3 ls exits 1 for a NONEXISTENT prefix with no output, which is the
# legitimate first-ever publication; a real API failure exits differently
# and/or writes to stderr, and aborts here.
LS_RC=0
LS_OUT=$(aws s3 ls "s3://${S3_BUCKET}/packaging/" --region "$S3_REGION") || LS_RC=$?
if [ "$LS_RC" -ne 0 ] && { [ "$LS_RC" -ne 1 ] || [ -n "$LS_OUT" ]; }; then
  echo "ERROR: could not list existing package repositories (exit ${LS_RC}); refusing to publish a partial index." >&2
  exit 1
fi
S3_DIRS=$(printf '%s\n' "$LS_OUT" | awk '/PRE valkey-/ {gsub(/PRE /,""); gsub(/\//,""); print}')

for vdir in $S3_DIRS; do
  ver="${vdir#valkey-}"
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${ver}"
  else
    AVAILABLE_VERSIONS="${ver}"
  fi
done

# Always include current version
CURRENT_VER="${MAJOR}.${MINOR}"
if ! echo ",${AVAILABLE_VERSIONS}," | grep -q ",${CURRENT_VER},"; then
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${CURRENT_VER}"
  else
    AVAILABLE_VERSIONS="${CURRENT_VER}"
  fi
fi
echo "Detected versions: ${AVAILABLE_VERSIONS}"

################################################################################
# Generate index.html from template
################################################################################
cp "${TEMPLATE_DIR}/index.html" "${SITE_DIR}/index.html"
sed -i "s|%%PAGES_URL%%|${PAGES_URL}|g" "${SITE_DIR}/index.html"
sed -i "s|%%REPO_URL%%|${REPO_URL}|g" "${SITE_DIR}/index.html"
sed -i "s|%%VERSIONS%%|${AVAILABLE_VERSIONS}|g" "${SITE_DIR}/index.html"

################################################################################
# Static files
################################################################################
touch "${SITE_DIR}/.nojekyll"
gpg --armor --export "$GPG_KEY" > "${SITE_DIR}/GPG-KEY-valkey.asc"

echo "Site ready at ${SITE_DIR}"
