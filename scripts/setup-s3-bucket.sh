#!/bin/bash
# Create and configure an S3 bucket for hosting Valkey packages.
#
# This script:
#   1. Creates an S3 bucket
#   2. Disables "Block Public Access"
#   3. Applies a public-read bucket policy
#   4. Creates OIDC identity provider and IAM role for GitHub Actions
#   5. Verifies public access
#   6. Optionally stores secrets in GitHub
#
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - Sufficient IAM permissions (s3:*, iam:*)
#   - Optional: gh CLI for storing GitHub secrets
#
# Usage:
#   ./setup-s3-bucket.sh [--bucket NAME] [--region REGION] [--repo "owner/repo"]

set -euo pipefail

# Defaults
BUCKET=""
REGION="us-east-1"
REPO=""
ROLE_NAME="GitHubActions-ValkeyPackages"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)      BUCKET="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --repo)        REPO="$2"; shift 2 ;;
    --role-name)   ROLE_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--bucket NAME] [--region REGION] [--repo \"owner/repo\"] [--role-name NAME]"
      echo ""
      echo "  --bucket      S3 bucket name (must be globally unique)."
      echo "                If omitted, prompts interactively."
      echo "  --region      AWS region (default: us-east-1)."
      echo "  --repo        GitHub repo (owner/repo) for OIDC trust and secret storage."
      echo "  --role-name   IAM role name (default: GitHubActions-ValkeyPackages)."
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
# Step 4: Create OIDC provider and IAM role for GitHub Actions
############################################################################
echo ""
echo "=== Step 4: Create OIDC provider and IAM role ==="

# Create GitHub OIDC identity provider (idempotent — ignores if exists)
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &>/dev/null; then
  echo "GitHub OIDC provider already exists, skipping."
else
  THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$THUMBPRINT"
  echo "GitHub OIDC identity provider created."
fi

# Determine OIDC subject filter
if [ -n "$REPO" ]; then
  OIDC_SUBJECT="repo:${REPO}:*"
else
  read -rp "GitHub repo (owner/repo) for OIDC trust: " REPO
  OIDC_SUBJECT="repo:${REPO}:*"
fi

# Create IAM role with trust policy for GitHub OIDC
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "${OIDC_SUBJECT}"
      }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "IAM role '${ROLE_NAME}' already exists, updating trust policy."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
  echo "IAM role '${ROLE_NAME}' created."
fi

# Attach S3 upload permissions to the role
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
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$UPLOAD_POLICY"
echo "Upload policy '${POLICY_NAME}' attached to role."

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "Role ARN: ${ROLE_ARN}"

############################################################################
# Step 5: Verify public access
############################################################################
echo ""
echo "=== Step 5: Verify public access ==="

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
# Step 6: Store secrets in GitHub (optional)
############################################################################
if [ -n "$REPO" ]; then
  echo ""
  echo "=== Step 6: Store secrets in GitHub ==="

  if ! command -v gh &>/dev/null; then
    echo "WARNING: gh CLI not found, skipping GitHub secret storage."
    echo "Store these secrets manually in your repo settings:"
    echo "  S3_BUCKET=${BUCKET}"
    echo "  S3_REGION=${REGION}"
    echo "  AWS_ROLE_TO_ASSUME=${ROLE_ARN}"
  else
    gh secret set S3_BUCKET --body "$BUCKET" --repo "$REPO"
    gh secret set S3_REGION --body "$REGION" --repo "$REPO"
    gh secret set AWS_ROLE_TO_ASSUME --body "$ROLE_ARN" --repo "$REPO"
    echo "S3_BUCKET, S3_REGION, and AWS_ROLE_TO_ASSUME stored in ${REPO}."
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
echo "  IAM Role:        ${ROLE_NAME}"
echo "  Role ARN:        ${ROLE_ARN}"
echo ""
echo "Package managers will use:"
echo "  ${BUCKET_URL}/valkey-9.0/rpm/el9/x86_64/  (example RPM repo)"
echo "  ${BUCKET_URL}/valkey-9.0/deb/debian12/amd64/  (example DEB repo)"
echo ""
if [ -z "$REPO" ]; then
  echo "To store secrets in GitHub, run:"
  echo "  gh secret set S3_BUCKET --body \"${BUCKET}\" --repo owner/repo"
  echo "  gh secret set S3_REGION --body \"${REGION}\" --repo owner/repo"
  echo "  gh secret set AWS_ROLE_TO_ASSUME --body \"${ROLE_ARN}\" --repo owner/repo"
  echo ""
fi
