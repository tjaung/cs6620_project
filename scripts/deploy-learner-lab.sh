#!/usr/bin/env bash
set -euo pipefail

# Fill these in from AWS Academy Learner Lab "AWS Details".
# Do not commit real credential values.
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID_VALUE:-}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY_VALUE:-}"
AWS_SESSION_TOKEN_VALUE="${AWS_SESSION_TOKEN_VALUE:-}"
AWS_REGION_VALUE="${AWS_REGION_VALUE:-us-east-1}"

# Fill these in for the GitHub repo that will run the workflow.
# github_repo can be left empty to allow all repos under github_owner.
GITHUB_OWNER_VALUE="${GITHUB_OWNER_VALUE:-tjaung}"
GITHUB_REPO_VALUE="${GITHUB_REPO_VALUE:-}"

# Use a unique project name per teammate to avoid IAM/resource name collisions.
PROJECT_NAME_VALUE="${PROJECT_NAME_VALUE:-security-scaner}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" || "${value}" == PASTE_* || "${value}" == *"PASTE_"* ]]; then
    echo "Missing required value: ${name}"
    echo "Edit scripts/deploy-learner-lab.sh and fill in ${name}."
    exit 1
  fi
}

require_value "AWS_ACCESS_KEY_ID_VALUE" "${AWS_ACCESS_KEY_ID_VALUE}"
require_value "AWS_SECRET_ACCESS_KEY_VALUE" "${AWS_SECRET_ACCESS_KEY_VALUE}"
require_value "AWS_SESSION_TOKEN_VALUE" "${AWS_SESSION_TOKEN_VALUE}"
require_value "GITHUB_OWNER_VALUE" "${GITHUB_OWNER_VALUE}"
require_value "PROJECT_NAME_VALUE" "${PROJECT_NAME_VALUE}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_VALUE}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_VALUE}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN_VALUE}"
export AWS_DEFAULT_REGION="${AWS_REGION_VALUE}"
export AWS_REGION="${AWS_REGION_VALUE}"

echo "Deploying S3 artifact bucket..."
terraform -chdir="${ROOT_DIR}/s3" init
terraform -chdir="${ROOT_DIR}/s3" apply \
  -var="aws_region=${AWS_REGION_VALUE}" \
  -var="project_name=${PROJECT_NAME_VALUE}" \
  -auto-approve

SOURCE_BUCKET_NAME="$(terraform -chdir="${ROOT_DIR}/s3" output -raw bucket_name)"

echo "Writing Lambda terraform.tfvars..."
cat > "${ROOT_DIR}/lambda/terraform.tfvars" <<EOF
aws_region              = "${AWS_REGION_VALUE}"
project_name            = "${PROJECT_NAME_VALUE}"
source_bucket_name      = "${SOURCE_BUCKET_NAME}"
use_lab_role            = true
create_github_oidc_role = false
github_owner            = "${GITHUB_OWNER_VALUE}"
github_repo             = "${GITHUB_REPO_VALUE}"
EOF

echo "Deploying Lambda with the Learner Lab LabRole..."
terraform -chdir="${ROOT_DIR}/lambda" init
terraform -chdir="${ROOT_DIR}/lambda" apply -auto-approve

LAMBDA_FUNCTION_NAME="$(terraform -chdir="${ROOT_DIR}/lambda" output -raw lambda_function_name)"

cat <<EOF

Deployment complete.

Use these values in your GitHub workflow inputs or repository variables:

SECURITY_SCAN_AWS_REGION=${AWS_REGION_VALUE}
SECURITY_SCAN_ARTIFACT_BUCKET=${SOURCE_BUCKET_NAME}
SECURITY_SCAN_LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME}

Because AWS Academy Learner Lab blocks IAM role and OIDC provider creation,
also add these temporary Learner Lab values as GitHub Actions secrets:

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID_VALUE}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY_VALUE}
AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN_VALUE}

The workflow can now upload repo.zip to S3 and invoke Lambda with Learner Lab credentials.
EOF
