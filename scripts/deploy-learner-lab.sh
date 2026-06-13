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

terraform_apply() {
  local stack_name="$1"
  local stack_dir="$2"
  shift 2

  echo "Deploying ${stack_name}..."
  terraform -chdir="${stack_dir}" init -upgrade
  if ! terraform -chdir="${stack_dir}" apply "$@" -auto-approve; then
    cat <<EOF

Terraform failed while deploying ${stack_name}.

If this failed while creating an EC2 instance, get the boot log with:

aws ec2 get-console-output \\
  --instance-id INSTANCE_ID_FROM_THE_ERROR \\
  --latest \\
  --output text

EOF
    return 1
  fi
}

echo "Deploying S3 artifact bucket..."
terraform_apply "S3 artifact bucket" "${ROOT_DIR}/s3" \
  -var="aws_region=${AWS_REGION_VALUE}" \
  -var="project_name=${PROJECT_NAME_VALUE}"

SOURCE_BUCKET_NAME="$(terraform -chdir="${ROOT_DIR}/s3" output -raw bucket_name)"

terraform_apply "SAST EC2 service" "${ROOT_DIR}/sast/terraform" \
  -var="region=${AWS_REGION_VALUE}"
SAST_PUBLIC_IP="$(terraform -chdir="${ROOT_DIR}/sast/terraform" output -raw sast_public_ip)"
SAST_HEALTH_ENDPOINT="$(terraform -chdir="${ROOT_DIR}/sast/terraform" output -raw sast_health_endpoint)"

terraform_apply "Pentest EC2 service" "${ROOT_DIR}/pentest/terraform" \
  -var="region=${AWS_REGION_VALUE}"
PENTEST_PUBLIC_IP="$(terraform -chdir="${ROOT_DIR}/pentest/terraform" output -raw pentest_public_ip)"
PENTEST_URL="$(terraform -chdir="${ROOT_DIR}/pentest/terraform" output -raw pentest_url)"
PENTEST_HEALTH_ENDPOINT="$(terraform -chdir="${ROOT_DIR}/pentest/terraform" output -raw health_check_url)"

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

terraform_apply "Lambda with the Learner Lab LabRole" "${ROOT_DIR}/lambda"

LAMBDA_FUNCTION_NAME="$(terraform -chdir="${ROOT_DIR}/lambda" output -raw lambda_function_name)"

cat <<EOF

Deployment complete.

Use these values in your GitHub workflow inputs or repository variables:

SECURITY_SCAN_AWS_REGION=${AWS_REGION_VALUE}
SECURITY_SCAN_ARTIFACT_BUCKET=${SOURCE_BUCKET_NAME}
SECURITY_SCAN_LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME}
SAST_PUBLIC_IP=${SAST_PUBLIC_IP}
SAST_HEALTH_ENDPOINT=${SAST_HEALTH_ENDPOINT}
PENTEST_PUBLIC_IP=${PENTEST_PUBLIC_IP}
PENTEST_URL=${PENTEST_URL}
PENTEST_HEALTH_ENDPOINT=${PENTEST_HEALTH_ENDPOINT}

Because AWS Academy Learner Lab blocks IAM role and OIDC provider creation,
also add these temporary Learner Lab values as GitHub Actions secrets:

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID_VALUE}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY_VALUE}
AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN_VALUE}

The workflow can now upload repo.zip to S3 and invoke Lambda with Learner Lab credentials.
EOF
