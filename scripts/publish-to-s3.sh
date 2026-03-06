#!/bin/bash
# Sign packages, build RPM/DEB repositories, and upload to S3.
# Usage: publish-to-s3.sh <version> <gpg_fingerprint> <artifacts_dir> <s3_bucket> <s3_region>
#
# Environment variables:
#   AWS_ACCESS_KEY_ID     - AWS access key (from GitHub secrets)
#   AWS_SECRET_ACCESS_KEY - AWS secret key (from GitHub secrets)
set -euo pipefail

VERSION="$1"
GPG_KEY="$2"
ARTIFACTS_DIR="$3"
S3_BUCKET="$4"
S3_REGION="$5"

MAJOR="${VERSION%%.*}"
REPO_NAME="valkey-${MAJOR}"
STAGING="staging"

echo "Publishing to S3: version=${VERSION}, major=${MAJOR}, repo=${REPO_NAME}"
echo "  Bucket: ${S3_BUCKET}, Region: ${S3_REGION}"

mkdir -p "${STAGING}"

################################################################################
# Build RPM repositories
################################################################################

# Import GPG key into RPM database (needed for rpmsign)
echo "Importing GPG key into RPM database..."
gpg --armor --export "$GPG_KEY" > /tmp/gpg-key-valkey.asc
rpm --import /tmp/gpg-key-valkey.asc

for dir in "${ARTIFACTS_DIR}"/valkey-rpms-*/; do
  [ -d "$dir" ] || continue
  artifact=$(basename "$dir" | sed 's/valkey-rpms-//')
  arch="${artifact##*-}"
  platform="${artifact%-*}"
  dest="${STAGING}/${REPO_NAME}/rpm/${platform}/${arch}"

  echo "=== RPM repo: ${REPO_NAME}/${platform}/${arch} ==="
  mkdir -p "$dest"
  cp "$dir"/*.rpm "$dest/" 2>/dev/null || true

  # Sign individual RPM packages (required for gpgcheck=1)
  echo "  Signing RPM packages..."
  for rpm_file in "$dest"/*.rpm; do
    [ -f "$rpm_file" ] || continue
    rpmsign --define "%_gpg_name ${GPG_KEY}" \
            --define "%__gpg /usr/bin/gpg" \
            --define "%_gpg_digest_algo sha256" \
            --addsign "$rpm_file"
  done

  createrepo_c --update "$dest"

  gpg --batch --yes --detach-sign --armor \
      --default-key "$GPG_KEY" \
      "$dest/repodata/repomd.xml"

  echo "  Done: $(ls "$dest"/*.rpm 2>/dev/null | wc -l) RPMs"
done

################################################################################
# Build DEB repositories
################################################################################
generate_release() {
  local dir="$1"
  local arch="$2"

  echo "Archive: stable"
  echo "Component: main"
  echo "Architecture: ${arch}"
  echo "Date: $(date -Ru)"

  for algo_name in MD5Sum SHA1 SHA256; do
    case "$algo_name" in
      MD5Sum) cmd="md5sum" ;;
      SHA1)   cmd="sha1sum" ;;
      SHA256) cmd="sha256sum" ;;
    esac
    echo "${algo_name}:"
    for f in Packages Packages.gz; do
      if [ -f "${dir}/${f}" ]; then
        local size hash
        size=$(stat -c%s "${dir}/${f}")
        hash=$($cmd "${dir}/${f}" | cut -d' ' -f1)
        printf " %s %16d %s\n" "$hash" "$size" "$f"
      fi
    done
  done
}

for dir in "${ARTIFACTS_DIR}"/valkey-debs-*/; do
  [ -d "$dir" ] || continue
  artifact=$(basename "$dir" | sed 's/valkey-debs-//')
  arch="${artifact##*-}"
  platform="${artifact%-*}"
  dest="${STAGING}/${REPO_NAME}/deb/${platform}/${arch}"

  echo "=== DEB repo: ${REPO_NAME}/${platform}/${arch} ==="
  mkdir -p "$dest"
  cp "$dir"/*.deb "$dest/" 2>/dev/null || true

  # Sign individual DEB packages
  echo "  Signing DEB packages..."
  for deb_file in "$dest"/*.deb; do
    [ -f "$deb_file" ] || continue
    debsigs --sign=origin --default-key="${GPG_KEY}" "$deb_file"
  done

  cd "$dest"
  dpkg-scanpackages --arch "$arch" . > Packages
  gzip -9 -k -f Packages

  generate_release "$(pwd)" "$arch" > Release

  gpg --batch --yes --detach-sign --armor \
      --default-key "$GPG_KEY" \
      --output Release.gpg Release
  gpg --batch --yes --clearsign \
      --default-key "$GPG_KEY" \
      --output InRelease Release

  echo "  Done: $(ls *.deb 2>/dev/null | wc -l) DEBs"
  cd - > /dev/null
done

################################################################################
# Export GPG public key
################################################################################
gpg --armor --export "$GPG_KEY" > "${STAGING}/GPG-KEY-valkey.asc"

################################################################################
# Upload to S3
################################################################################
echo ""
echo "Uploading to s3://${S3_BUCKET}/..."
aws s3 sync "${STAGING}/" "s3://${S3_BUCKET}/"
echo "Upload complete."
echo "Packages available at: https://${S3_BUCKET}.s3.${S3_REGION}.amazonaws.com"
