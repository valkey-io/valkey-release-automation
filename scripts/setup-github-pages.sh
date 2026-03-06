#!/bin/bash
# Setup script for GitHub Pages package repository deployment.
# This script configures everything needed on the GitHub side:
#   1. Generates a GPG signing key
#   2. Stores it as a GitHub Actions secret
#   3. Enables read/write workflow permissions
#   4. Creates the gh-pages branch
#   5. Configures GitHub Pages to deploy from that branch
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - gpg installed
#   - Must be run from inside the git repository
#
# Usage:
#   ./setup-github-pages.sh [--repo "owner/repo"] [--key-name "Name"] [--key-email "email@example.com"]

set -euo pipefail

# Defaults
KEY_NAME="Valkey Package Signing Key"
KEY_EMAIL="packages@valkey.io"
REPO=""
S3_BUCKET=""
S3_REGION=""
AWS_KEY_ID=""
AWS_SECRET=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --key-name)    KEY_NAME="$2"; shift 2 ;;
    --key-email)   KEY_EMAIL="$2"; shift 2 ;;
    --s3-bucket)   S3_BUCKET="$2"; shift 2 ;;
    --s3-region)   S3_REGION="$2"; shift 2 ;;
    --aws-key-id)  AWS_KEY_ID="$2"; shift 2 ;;
    --aws-secret)  AWS_SECRET="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--repo \"owner/repo\"] [--key-name \"Name\"] [--key-email \"email@example.com\"]"
      echo "          [--s3-bucket BUCKET] [--s3-region REGION]"
      echo "          [--aws-key-id KEY_ID] [--aws-secret SECRET]"
      echo ""
      echo "  --repo        Target repository (e.g., \"myuser/valkey-release-automation\")."
      echo "                If omitted, auto-detects from the current git remote."
      echo "  --s3-bucket   S3 bucket name for package hosting."
      echo "  --s3-region   S3 bucket region (e.g., us-east-1)."
      echo "  --aws-key-id  AWS Access Key ID for S3 uploads."
      echo "  --aws-secret  AWS Secret Access Key for S3 uploads."
      echo ""
      echo "If S3/AWS options are omitted, the script will prompt interactively."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Determine target repository
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "ERROR: Not in a GitHub repository or gh CLI not authenticated."
    echo "Run 'gh auth login' first, or specify --repo owner/repo."
    exit 1
  }
fi
echo "Repository: ${REPO}"

############################################################################
# Step 1: Generate GPG signing key
############################################################################
echo ""
echo "=== Step 1: Generate GPG signing key ==="

if gpg --list-keys "${KEY_EMAIL}" &>/dev/null; then
  echo "GPG key for ${KEY_EMAIL} already exists, skipping generation."
else
  gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 3y
%commit
EOF
  echo "GPG key generated for ${KEY_NAME} <${KEY_EMAIL}>"
fi

FINGERPRINT=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^fpr/ {print $10; exit}')
echo "Fingerprint: ${FINGERPRINT}"

############################################################################
# Step 2: Store GPG private key as GitHub Actions secret
############################################################################
echo ""
echo "=== Step 2: Store GPG_PRIVATE_KEY secret ==="

gpg --armor --export-secret-keys "${KEY_EMAIL}" | gh secret set GPG_PRIVATE_KEY --repo "${REPO}"
echo "Secret GPG_PRIVATE_KEY stored."

# Verify
gh secret list --repo "${REPO}" | grep -q GPG_PRIVATE_KEY && echo "Verified: secret exists." || {
  echo "ERROR: Secret was not created."
  exit 1
}

############################################################################
# Step 2b: Store S3 credentials as GitHub Actions secrets
############################################################################
echo ""
echo "=== Step 2b: Store S3 credentials ==="

if [ -z "$S3_BUCKET" ]; then
  read -rp "S3 Bucket name: " S3_BUCKET
fi
if [ -z "$S3_REGION" ]; then
  read -rp "S3 Region (e.g., us-east-1): " S3_REGION
fi
if [ -z "$AWS_KEY_ID" ]; then
  read -rp "AWS Access Key ID: " AWS_KEY_ID
fi
if [ -z "$AWS_SECRET" ]; then
  read -rsp "AWS Secret Access Key: " AWS_SECRET
  echo ""
fi

gh secret set S3_BUCKET --body "$S3_BUCKET" --repo "$REPO"
gh secret set S3_REGION --body "$S3_REGION" --repo "$REPO"
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_KEY_ID" --repo "$REPO"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET" --repo "$REPO"
echo "S3 secrets stored."

############################################################################
# Step 3: Enable read/write workflow permissions
############################################################################
echo ""
echo "=== Step 3: Enable workflow read/write permissions ==="

gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true

echo "Workflow permissions set to read/write."

############################################################################
# Step 4: Create gh-pages branch
############################################################################
echo ""
echo "=== Step 4: Create gh-pages branch ==="

CURRENT_BRANCH=$(git branch --show-current)

if git ls-remote --exit-code origin gh-pages &>/dev/null; then
  echo "gh-pages branch already exists, skipping."
else
  # Create orphan branch with just .nojekyll
  git checkout --orphan gh-pages
  git rm -rf . &>/dev/null || true
  touch .nojekyll
  git add .nojekyll
  git commit -m "Initialize gh-pages branch"
  git push origin gh-pages
  git checkout "${CURRENT_BRANCH}"
  echo "gh-pages branch created and pushed."
fi

############################################################################
# Step 5: Configure GitHub Pages
############################################################################
echo ""
echo "=== Step 5: Configure GitHub Pages ==="

# Check if Pages is already enabled
PAGES_STATUS=$(gh api "repos/${REPO}/pages" --jq '.build_type' 2>/dev/null || echo "not_enabled")

if [ "${PAGES_STATUS}" = "not_enabled" ]; then
  gh api -X POST "repos/${REPO}/pages" \
    -f "source[branch]=gh-pages" -f "source[path]=/" -f "build_type=legacy"
  echo "GitHub Pages enabled (deploy from gh-pages branch)."
else
  gh api -X PUT "repos/${REPO}/pages" \
    -f "source[branch]=gh-pages" -f "source[path]=/" -f "build_type=legacy"
  echo "GitHub Pages updated (deploy from gh-pages branch)."
fi

############################################################################
# Summary
############################################################################
echo ""
echo "============================================="
echo "Setup complete!"
echo "============================================="
echo ""
echo "  Repository:  ${REPO}"
echo "  GPG Key:     ${KEY_NAME} <${KEY_EMAIL}>"
echo "  Fingerprint: ${FINGERPRINT}"
echo "  Secret:      GPG_PRIVATE_KEY"
echo "  S3 Bucket:   ${S3_BUCKET}"
echo "  S3 Region:   ${S3_REGION}"
echo "  Pages:       gh-pages branch"
echo ""
echo "Export the public key for reference:"
echo "  gpg --armor --export ${KEY_EMAIL} > GPG-KEY-valkey.asc"
echo ""
echo "Packages will be published to:"
echo "  https://${S3_BUCKET}.s3.${S3_REGION}.amazonaws.com"
echo ""
echo "Install instructions will be at:"
echo "  https://$(echo ${REPO} | tr '/' '.github.io/')"
echo ""
