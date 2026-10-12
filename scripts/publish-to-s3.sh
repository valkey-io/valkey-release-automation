#!/bin/bash
# Sign packages, build RPM/DEB/APK repositories, and upload to S3.
# Usage: publish-to-s3.sh <version> <gpg_fingerprint> <artifacts_dir> <s3_bucket> <s3_region> [<apk_key_file>]
#
# AWS credentials are expected to be configured via OIDC
# (aws-actions/configure-aws-credentials) before calling this script.
#
# <apk_key_file> is the APK repository private key (PEM). It is required
# once APK publishing is enabled by committing the matching public key as
# packaging/common/apk/keys/valkey-packages.rsa.pub. APK signing runs in
# Docker containers of each Alpine release.
set -euo pipefail

VERSION="$1"
GPG_KEY="$2"
ARTIFACTS_DIR="$3"
S3_BUCKET="$4"
S3_REGION="$5"
APK_KEY_FILE="${6:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APK_KEY_NAME="valkey-packages.rsa.pub"
APK_PUBLIC_KEY="${REPO_ROOT}/packaging/common/apk/keys/${APK_KEY_NAME}"
PLATFORMS="${REPO_ROOT}/.github/package-platforms.json"

MAJOR="${VERSION%%.*}"
MINOR_PART="${VERSION#*.}"
MINOR="${MINOR_PART%%.*}"
REPO_NAME="valkey-${MAJOR}.${MINOR}"
STAGING="staging"

echo "Publishing to S3: version=${VERSION}, major=${MAJOR}, minor=${MINOR}, repo=${REPO_NAME}"
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

  # Hydrate the packages this repository already serves. The indexes are
  # regenerated from the staging directory, so without this a patch release
  # would publish metadata listing only itself and delist every earlier
  # patch from yum, even though their files remain in the bucket. Packages
  # only: the metadata is rebuilt below over the union. Fails closed - a
  # listing error must not regenerate indexes from a partial set.
  aws s3 sync "s3://${S3_BUCKET}/packaging/${REPO_NAME}/rpm/${platform}/${arch}/" "$dest/" \
    --exclude "*" --include "*.rpm" --region "$S3_REGION"

  cp "$dir"/*.rpm "$dest/" 2>/dev/null || true

  # Sign only this run's packages (required for gpgcheck=1). Hydrated
  # packages were signed at their own publication; re-signing DEBs is not
  # idempotent, so the same only-new rule is used for both families.
  echo "  Signing RPM packages..."
  for src_file in "$dir"/*.rpm; do
    [ -f "$src_file" ] || continue
    rpmsign --define "%_gpg_name ${GPG_KEY}" \
            --define "%__gpg /usr/bin/gpg" \
            --define "%_gpg_digest_algo sha256" \
            --addsign "${dest}/$(basename "$src_file")"
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

  # Hydrate existing packages before regenerating Packages/Release, for the
  # same reason as the RPM loop above: apt only sees what the index lists.
  aws s3 sync "s3://${S3_BUCKET}/packaging/${REPO_NAME}/deb/${platform}/${arch}/" "$dest/" \
    --exclude "*" --include "*.deb" --region "$S3_REGION"

  cp "$dir"/*.deb "$dest/" 2>/dev/null || true

  # Sign only this run's packages: debsigs is not idempotent, and hydrated
  # packages carry the signature from their own publication.
  echo "  Signing DEB packages..."
  for src_file in "$dir"/*.deb; do
    [ -f "$src_file" ] || continue
    debsigs --sign=origin --default-key="${GPG_KEY}" "${dest}/$(basename "$src_file")"
  done

  cd "$dest"
  # dpkg-scanpackages writes Filename relative to the directory it scans, but
  # apt resolves Filename against the sources.list URI -- the platform
  # directory, one level up. Scan from there so the paths line up.
  # --multiversion is what makes hydration mean anything for apt: without
  # it dpkg-scanpackages keeps only the newest version of each package and
  # the index delists every earlier patch despite their files being present.
  ( cd .. && dpkg-scanpackages --multiversion --arch "$arch" "$arch" ) > Packages
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
# Build APK repositories
################################################################################
# Public key in one normalized form, or nothing if the file is not a key.
public_key_of() { # <-in|-pubin -in> <file>
  openssl rsa "$@" -pubout 2>/dev/null | grep -v '^-----' | tr -d '\n'
}

# Each Alpine release gets an image with abuild and python3 installed in a
# run without the key; every signing step then runs without network.
declare -A APK_SIGN_IMAGES=()
prepare_apk_sign_image() { # <container>; sets SIGN_IMAGE
  local container="$1" prep="valkey-apk-sign-prep-$$"
  if [ -z "${APK_SIGN_IMAGES[$container]:-}" ]; then
    SIGN_IMAGE="valkey-apk-sign:${container#*:}"
    if ! docker run --name "$prep" "$container" apk add --no-cache abuild python3; then
      docker rm -f "$prep" >/dev/null 2>&1 || true
      echo "ERROR: could not prepare the APK signing image for ${container}" >&2
      exit 1
    fi
    docker commit "$prep" "$SIGN_IMAGE" >/dev/null
    docker rm "$prep" >/dev/null
    APK_SIGN_IMAGES[$container]="$SIGN_IMAGE"
  fi
  SIGN_IMAGE="${APK_SIGN_IMAGES[$container]}"
}

# sign-apk.sh steps run as this user, without network or capabilities.
# Keyless steps parse the packages; the keyed step sees only the scratch
# directory of files to sign, never the repository that is uploaded.
APK_DOCKER=(docker run --rm --network none --user "$(id -u):$(id -g)"
  --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp
  -v "${SCRIPT_DIR}/sign-apk.sh:/sign-apk.sh:ro")
apk_keyless() { # <repo> <work> <sign-apk.sh args>...
  local repo="$1" work="$2"
  shift 2
  "${APK_DOCKER[@]}" -v "${repo}:/repo" -v "${work}:/work" \
    -v "${APK_PUBLIC_KEY}:/apk-key/${APK_KEY_NAME}:ro" \
    "$SIGN_IMAGE" sh /sign-apk.sh "$@"
}
apk_keyed() { # <work> <file>...
  local work="$1"
  shift
  "${APK_DOCKER[@]}" -v "${work}:/work" -v "${APK_KEY_FILE}:/apk-key/private.rsa:ro" \
    "$SIGN_IMAGE" sh /sign-apk.sh sign /work "$APK_KEY_NAME" "$@"
}

APK_DIRS=()
for dir in "${ARTIFACTS_DIR}"/valkey-apks-*/; do
  [ -d "$dir" ] && APK_DIRS+=("$dir")
done

if [ "${#APK_DIRS[@]}" -eq 0 ]; then
  echo "No APK artifacts to publish."
elif [ ! -f "$APK_PUBLIC_KEY" ]; then
  # The committed public key is the switch: users trust it, so publishing
  # starts only once it is reviewed into the repository.
  echo "::warning::APK publishing is not enabled: ${APK_PUBLIC_KEY#"${REPO_ROOT}/"} is not committed. Skipping ${#APK_DIRS[@]} APK artifact(s)."
else
  if [ -z "$APK_KEY_FILE" ] || [ ! -s "$APK_KEY_FILE" ]; then
    echo "ERROR: APK publishing is enabled but no APK signing key was provided (APK_PRIVATE_KEY secret)." >&2
    exit 1
  fi
  APK_KEY_FILE="$(cd "$(dirname "$APK_KEY_FILE")" && pwd)/$(basename "$APK_KEY_FILE")"
  # A wrong secret must fail here, not ship packages users cannot verify.
  secret_public="$(public_key_of -in "$APK_KEY_FILE")"
  committed_public="$(public_key_of -pubin -in "$APK_PUBLIC_KEY")"
  if [ -z "$secret_public" ] || [ -z "$committed_public" ] || [ "$secret_public" != "$committed_public" ]; then
    echo "ERROR: the APK signing key does not match ${APK_PUBLIC_KEY#"${REPO_ROOT}/"}." >&2
    exit 1
  fi
  # Alpine spells x.y.z-rcN as x.y.z_rcN.
  APK_VERSION="${VERSION/-rc/_rc}"

  for dir in "${APK_DIRS[@]}"; do
    artifact=$(basename "$dir" | sed 's/valkey-apks-//')
    arch="${artifact##*-}"
    platform="${artifact%-*}"
    if ! jq -e --arg arch "$arch" '.apk.arch | index($arch)' "$PLATFORMS" >/dev/null ||
       ! branch=$(jq -er --arg id "$platform" '.apk.platform[] | select(.id == $id) | .branch' "$PLATFORMS") ||
       ! container=$(jq -er --arg id "$platform" '.apk.platform[] | select(.id == $id) | .container' "$PLATFORMS"); then
      echo "ERROR: APK artifact ${artifact} does not match an APK platform and arch in ${PLATFORMS}" >&2
      exit 1
    fi
    dest="${STAGING}/${REPO_NAME}/apk/${branch}/${arch}"

    echo "=== APK repo: ${REPO_NAME}/apk/${branch}/${arch} ==="
    mkdir -p "$dest"
    dest="$(cd "$dest" && pwd)"

    # Hydrate existing packages before regenerating APKINDEX, for the same
    # reason as the RPM loop above: apk only sees what the index lists.
    aws s3 sync "s3://${S3_BUCKET}/packaging/${REPO_NAME}/apk/${branch}/${arch}/" "$dest/" \
      --exclude "*" --include "*.apk" --region "$S3_REGION"

    new_pkgs=()
    for src_file in "$dir"/*.apk; do
      [ -f "$src_file" ] || continue
      cp "$src_file" "$dest/"
      new_pkgs+=("$(basename "$src_file")")
    done
    if [ "${#new_pkgs[@]}" -eq 0 ]; then
      echo "ERROR: APK artifact ${artifact} contains no packages" >&2
      exit 1
    fi

    # Re-sign only this run's packages (the build signed them with a
    # throwaway key); hydrated ones carry the release signature already.
    prepare_apk_sign_image "$container"
    work="$(mktemp -d)"
    apk_keyless "$dest" "$work" prepare /repo /work "$arch" "$APK_VERSION" "${new_pkgs[@]}"
    controls=()
    for pkg in "${new_pkgs[@]}"; do
      controls+=("${pkg}/control.tar.gz")
    done
    apk_keyed "$work" "${controls[@]}"
    apk_keyless "$dest" "$work" assemble /repo /work "${new_pkgs[@]}"
    apk_keyless "$dest" "$work" index /repo /work "$arch" "$APK_KEY_NAME" \
      "valkey ${MAJOR}.${MINOR} (Alpine ${branch})"
    apk_keyed "$work" APKINDEX.tar.gz
    mv "${work}/APKINDEX.tar.gz" "${dest}/APKINDEX.tar.gz"
    rm -rf "$work"

    echo "  Done: $(find "$dest" -maxdepth 1 -name '*.apk' | wc -l) APKs"
  done

  cp "$APK_PUBLIC_KEY" "${STAGING}/${APK_KEY_NAME}"
fi

################################################################################
# Export GPG public key
################################################################################
gpg --armor --export "$GPG_KEY" > "${STAGING}/GPG-KEY-valkey.asc"

################################################################################
# Upload to S3
################################################################################
echo ""
echo "Uploading to s3://${S3_BUCKET}/packaging/..."
# Sync without --delete: multiple patch versions (e.g. 9.0.2, 9.0.4)
# share the same repo directory (valkey-9.0/rpm/el9/x86_64/), so
# --delete would remove packages from other patch releases.
aws s3 sync "${STAGING}/" "s3://${S3_BUCKET}/packaging/"
echo "Upload complete."
echo "Packages available at: https://download.valkey.io/packaging"
