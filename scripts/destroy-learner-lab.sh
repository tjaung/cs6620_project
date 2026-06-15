#!/usr/bin/env bash
set -euo pipefail

# Fill these in from AWS Academy Learner Lab "AWS Details".
# Do not commit real credential values.
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID_VALUE:-}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY_VALUE:-}"
AWS_SESSION_TOKEN_VALUE="${AWS_SESSION_TOKEN_VALUE:-}"
AWS_REGION_VALUE="${AWS_REGION_VALUE:-us-east-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" || "${value}" == PASTE_* || "${value}" == *"PASTE_"* ]]; then
    echo "Missing required value: ${name}"
    echo "Export ${name} before running this script."
    exit 1
  fi
}

terraform_destroy() {
  local stack_name="$1"
  local stack_dir="$2"
  shift 2

  if [[ ! -d "${stack_dir}" ]]; then
    echo "Skipping ${stack_name}: ${stack_dir} does not exist."
    return 0
  fi

  if [[ ! -d "${stack_dir}/.terraform" ]]; then
    echo "Initializing ${stack_name}..."
    terraform -chdir="${stack_dir}" init
  fi

  echo "Destroying ${stack_name}..."
  terraform -chdir="${stack_dir}" destroy "$@" -auto-approve
}

get_terraform_output() {
  local stack_dir="$1"
  local output_name="$2"

  terraform -chdir="${stack_dir}" output -raw "${output_name}" 2>/dev/null || true
}

require_value "AWS_ACCESS_KEY_ID_VALUE" "${AWS_ACCESS_KEY_ID_VALUE}"
require_value "AWS_SECRET_ACCESS_KEY_VALUE" "${AWS_SECRET_ACCESS_KEY_VALUE}"
require_value "AWS_SESSION_TOKEN_VALUE" "${AWS_SESSION_TOKEN_VALUE}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_VALUE}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_VALUE}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN_VALUE}"
export AWS_DEFAULT_REGION="${AWS_REGION_VALUE}"
export AWS_REGION="${AWS_REGION_VALUE}"

cat <<EOF
This will destroy the Terraform-managed security scan infrastructure:

- Lambda stack
- SAST EC2 stack
- Pentest EC2 stack
- S3 artifact bucket stack

Region: ${AWS_REGION_VALUE}

EOF

read -r -p "Type 'destroy' to continue: " CONFIRM
if [[ "${CONFIRM}" != "destroy" ]]; then
  echo "Canceled."
  exit 0
fi

terraform_destroy "Lambda" "${ROOT_DIR}/lambda"
terraform_destroy "SAST EC2 service" "${ROOT_DIR}/sast/terraform"
terraform_destroy "Pentest EC2 service" "${ROOT_DIR}/pentest/terraform"

SOURCE_BUCKET_NAME="$(get_terraform_output "${ROOT_DIR}/s3" "bucket_name")"
if [[ -n "${SOURCE_BUCKET_NAME}" ]]; then
  echo "Emptying S3 bucket ${SOURCE_BUCKET_NAME}..."
  aws s3 rm "s3://${SOURCE_BUCKET_NAME}" --recursive || true
fi

terraform_destroy "S3 artifact bucket" "${ROOT_DIR}/s3" \
  -var="aws_region=${AWS_REGION_VALUE}"

echo "Teardown complete."
