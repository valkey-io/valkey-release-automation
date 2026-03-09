#!/bin/bash
# Create and configure an S3 bucket for hosting Valkey packages.
#
# This script:
#   1. Creates an S3 bucket
#   2. Disables "Block Public Access"
#   3. Applies a public-read bucket policy
#   4. Creates an IAM user with upload permissions
#   5. Generates access keys for the IAM user
#   6. Optionally stores secrets in GitHub
#
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - Sufficient IAM permissions (s3:*, iam:*)
#   - Optional: gh CLI for storing GitHub secrets
#
# Usage:
#   ./setup-s3-bucket.sh [--bucket NAME] [--region REGION] [--iam-user NAME] [--repo "owner/repo"]

set -euo pipefail

# Defaults
BUCKET=""
REGION="us-east-1"
IAM_USER="valkey-ci-uploader"
REPO=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)    BUCKET="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --iam-user)  IAM_USER="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--bucket NAME] [--region REGION] [--iam-user NAME] [--repo \"owner/repo\"]"
      echo ""
      echo "  --bucket    S3 bucket name (must be globally unique)."
      echo "              If omitted, prompts interactively."
      echo "  --region    AWS region (default: us-east-1)."
      echo "  --iam-user  IAM user name for CI uploads (default: valkey-ci-uploader)."
      echo "  --repo      GitHub repo (owner/repo) to store secrets in."
      echo "              If omitted, skips GitHub secret storage."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check prerequisites
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI not found. Install it first:"
  echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

# Verify AWS credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS CLI not configured. Run 'aws configure' first."
  exit 1
fi

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: ${AWS_ACCOUNT}"

############################################################################
# Step 1: Create S3 bucket
############################################################################
echo ""
echo "=== Step 1: Create S3 bucket ==="

if [ -z "$BUCKET" ]; then
  read -rp "S3 Bucket name (globally unique): " BUCKET
fi

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket '${BUCKET}' already exists, skipping creation."
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "Bucket '${BUCKET}' created in ${REGION}."
fi

############################################################################
# Step 2: Disable Block Public Access
############################################################################
echo ""
echo "=== Step 2: Disable Block Public Access ==="

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "Block Public Access disabled."

############################################################################
# Step 3: Apply public-read bucket policy
############################################################################
echo ""
echo "=== Step 3: Apply public-read bucket policy ==="

POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*"
  }]
}
EOF
)

aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"
echo "Public-read bucket policy applied."

############################################################################
# Step 4: Create IAM user with upload permissions
############################################################################
echo ""
echo "=== Step 4: Create IAM user '${IAM_USER}' ==="

if aws iam get-user --user-name "$IAM_USER" &>/dev/null; then
  echo "IAM user '${IAM_USER}' already exists, skipping creation."
else
  aws iam create-user --user-name "$IAM_USER"
  echo "IAM user '${IAM_USER}' created."
fi

UPLOAD_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:DeleteObject"
    ],
    "Resource": [
      "arn:aws:s3:::${BUCKET}",
      "arn:aws:s3:::${BUCKET}/*"
    ]
  }]
}
EOF
)

POLICY_NAME="valkey-s3-upload-${BUCKET}"
aws iam put-user-policy \
  --user-name "$IAM_USER" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$UPLOAD_POLICY"
echo "Upload policy '${POLICY_NAME}' attached."

############################################################################
# Step 5: Generate access keys
############################################################################
echo ""
echo "=== Step 5: Generate access keys ==="

KEY_OUTPUT=$(aws iam create-access-key --user-name "$IAM_USER" --output json)
ACCESS_KEY_ID=$(echo "$KEY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
SECRET_ACCESS_KEY=$(echo "$KEY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

echo "Access Key ID:     ${ACCESS_KEY_ID}"
echo "Secret Access Key: ${SECRET_ACCESS_KEY}"
echo ""
echo "IMPORTANT: Save the Secret Access Key now — it cannot be retrieved again."

############################################################################
# Step 6: Verify public access
############################################################################
echo ""
echo "=== Step 6: Verify public access ==="

TEST_KEY="__setup-test-${RANDOM}.txt"
echo -n "test" > "/tmp/${TEST_KEY}"
aws s3api put-object --bucket "$BUCKET" --key "$TEST_KEY" --body "/tmp/${TEST_KEY}"
rm -f "/tmp/${TEST_KEY}"
BUCKET_URL="https://${BUCKET}.s3.${REGION}.amazonaws.com"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BUCKET_URL}/${TEST_KEY}" 2>/dev/null || echo "000")
aws s3api delete-object --bucket "$BUCKET" --key "$TEST_KEY" >/dev/null

if [ "$HTTP_CODE" = "200" ]; then
  echo "Public read verified (HTTP ${HTTP_CODE})."
else
  echo "WARNING: Public read check returned HTTP ${HTTP_CODE}."
  echo "  The bucket may need a few seconds to propagate. Verify manually:"
  echo "  curl -I ${BUCKET_URL}/GPG-KEY-valkey.asc"
fi

############################################################################
# Step 7: Store secrets in GitHub (optional)
############################################################################
if [ -n "$REPO" ]; then
  echo ""
  echo "=== Step 7: Store secrets in GitHub ==="

  if ! command -v gh &>/dev/null; then
    echo "WARNING: gh CLI not found, skipping GitHub secret storage."
    echo "Store these secrets manually in your repo settings:"
    echo "  S3_BUCKET=${BUCKET}"
    echo "  S3_REGION=${REGION}"
    echo "  AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
    echo "  AWS_SECRET_ACCESS_KEY=<see above>"
  else
    gh secret set S3_BUCKET --body "$BUCKET" --repo "$REPO"
    gh secret set S3_REGION --body "$REGION" --repo "$REPO"
    gh secret set AWS_ACCESS_KEY_ID --body "$ACCESS_KEY_ID" --repo "$REPO"
    gh secret set AWS_SECRET_ACCESS_KEY --body "$SECRET_ACCESS_KEY" --repo "$REPO"
    echo "All 4 secrets stored in ${REPO}."
  fi
fi

############################################################################
# Summary
############################################################################
echo ""
echo "============================================="
echo "S3 bucket setup complete!"
echo "============================================="
echo ""
echo "  Bucket:          ${BUCKET}"
echo "  Region:          ${REGION}"
echo "  URL:             ${BUCKET_URL}"
echo "  IAM User:        ${IAM_USER}"
echo "  Access Key ID:   ${ACCESS_KEY_ID}"
echo ""
echo "Package managers will use:"
echo "  ${BUCKET_URL}/valkey-9.0/rpm/el9/x86_64/  (example RPM repo)"
echo "  ${BUCKET_URL}/valkey-9.0/deb/debian12/amd64/  (example DEB repo)"
echo ""
if [ -z "$REPO" ]; then
  echo "To store secrets in GitHub, run:"
  echo "  gh secret set S3_BUCKET --body \"${BUCKET}\" --repo owner/repo"
  echo "  gh secret set S3_REGION --body \"${REGION}\" --repo owner/repo"
  echo "  gh secret set AWS_ACCESS_KEY_ID --body \"${ACCESS_KEY_ID}\" --repo owner/repo"
  echo "  gh secret set AWS_SECRET_ACCESS_KEY --body \"<secret>\" --repo owner/repo"
  echo ""
fi
