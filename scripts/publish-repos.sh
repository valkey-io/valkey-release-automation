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

echo "Generating site: version=${VERSION}, major=${MAJOR}"
echo "  Repo URL (S3):       ${REPO_URL}"
echo "  Pages URL (GH Pages): ${PAGES_URL}"

mkdir -p "${SITE_DIR}"

################################################################################
# Detect available versions from S3 bucket
################################################################################
echo "Listing versions from s3://${S3_BUCKET}/..."
AVAILABLE_VERSIONS=""
S3_DIRS=$(aws s3 ls "s3://${S3_BUCKET}/" --region "$S3_REGION" 2>/dev/null | awk '/PRE valkey-/ {gsub(/PRE /,""); gsub(/\//,""); print}') || true

for vdir in $S3_DIRS; do
  ver="${vdir#valkey-}"
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${ver}"
  else
    AVAILABLE_VERSIONS="${ver}"
  fi
done

# Always include current version
if ! echo ",${AVAILABLE_VERSIONS}," | grep -q ",${MAJOR},"; then
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${MAJOR}"
  else
    AVAILABLE_VERSIONS="${MAJOR}"
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
