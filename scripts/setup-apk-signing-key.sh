#!/bin/bash
# Set up the APK repository signing key:
#   1. Generates a 4096-bit RSA key pair
#   2. Stores the private key as the APK_PRIVATE_KEY GitHub Actions secret
#   3. Writes the public key to packaging/common/apk/keys/valkey-packages.rsa.pub
#
# Committing that public key enables APK publishing: publish-to-s3.sh then
# requires APK_PRIVATE_KEY and checks that it matches the committed key.
#
# The key file name is part of every signature (.SIGN.RSA256.<name>) and
# users install the key under that name, so a new key is a rotation that
# every user has to follow. The script refuses to replace a committed key.
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - openssl installed
#   - Must be run from inside the git repository
#
# Usage:
#   ./setup-apk-signing-key.sh [--repo "owner/repo"] [--backup-dir DIR]

set -euo pipefail

REPO=""
BACKUP_DIR=""
KEY_NAME="valkey-packages.rsa.pub"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--repo \"owner/repo\"] [--backup-dir DIR]"
      echo ""
      echo "  --repo        Target repository (e.g., \"myuser/valkey-release-automation\")."
      echo "                If omitted, auto-detects from the current git remote."
      echo "  --backup-dir  Also keep the private key in DIR (mode 0600) for offline backup."
      echo "                Without it, the only copy is the GitHub secret."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

REPO_ROOT=$(git rev-parse --show-toplevel)
PUBLIC_KEY="${REPO_ROOT}/packaging/common/apk/keys/${KEY_NAME}"

if [ -e "$PUBLIC_KEY" ]; then
  echo "ERROR: ${PUBLIC_KEY#"${REPO_ROOT}/"} already exists."
  echo "Replacing it is a key rotation: every user must install the new key."
  echo "Remove the file deliberately first if that is what you want."
  exit 1
fi
if [ -n "$BACKUP_DIR" ] && [ -e "${BACKUP_DIR}/valkey-packages.rsa" ]; then
  echo "ERROR: ${BACKUP_DIR}/valkey-packages.rsa already exists."
  exit 1
fi

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "ERROR: Not in a GitHub repository or gh CLI not authenticated."
    echo "Run 'gh auth login' first, or specify --repo owner/repo."
    exit 1
  }
fi
echo "Repository: ${REPO}"

# Replacing the secret without replacing the committed public key would
# fail every APK publication; do not overwrite it.
SECRETS=$(gh secret list --repo "${REPO}")
if grep -q '^APK_PRIVATE_KEY\b' <<< "$SECRETS"; then
  echo "ERROR: ${REPO} already has an APK_PRIVATE_KEY secret."
  echo "Delete it deliberately first (gh secret delete APK_PRIVATE_KEY) if you are rotating the key."
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

############################################################################
# Step 1: Generate the key pair
############################################################################
echo ""
echo "=== Step 1: Generate a 4096-bit RSA key pair ==="
(umask 077 && openssl genrsa -out "${WORK}/valkey-packages.rsa" 4096 2>/dev/null)
openssl rsa -in "${WORK}/valkey-packages.rsa" -pubout -out "${WORK}/${KEY_NAME}" 2>/dev/null

############################################################################
# Step 2: Store the private key as a GitHub Actions secret
############################################################################
echo ""
echo "=== Step 2: Store APK_PRIVATE_KEY secret ==="
gh secret set APK_PRIVATE_KEY --repo "${REPO}" < "${WORK}/valkey-packages.rsa"
SECRETS=$(gh secret list --repo "${REPO}")
if grep -q '^APK_PRIVATE_KEY\b' <<< "$SECRETS"; then
  echo "Verified: secret exists."
else
  echo "ERROR: Secret was not created."
  exit 1
fi

if [ -n "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  install -m 600 "${WORK}/valkey-packages.rsa" "${BACKUP_DIR}/valkey-packages.rsa"
  echo "Private key backup: ${BACKUP_DIR}/valkey-packages.rsa"
fi

############################################################################
# Step 3: Write the public key
############################################################################
echo ""
echo "=== Step 3: Write the public key ==="
mkdir -p "$(dirname "$PUBLIC_KEY")"
cp "${WORK}/${KEY_NAME}" "$PUBLIC_KEY"
echo "Public key: ${PUBLIC_KEY#"${REPO_ROOT}/"}"

echo ""
echo "Next: commit ${PUBLIC_KEY#"${REPO_ROOT}/"} to enable APK publishing."
