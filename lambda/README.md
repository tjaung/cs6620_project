# Lambda Repo Reader

This Terraform stack deploys a proof-of-concept Lambda that:

1. Receives an S3 bucket/key from GitHub Actions.
2. Downloads `repo.zip` from S3.
3. Extracts the repository in Lambda `/tmp`.
4. Returns a JSON response with file paths and small text previews.
5. Writes the same response to `result.json` beside the uploaded zip.

Normal AWS account apply order:

```bash
cd s3
terraform init
terraform apply
terraform output bucket_name

cd ../lambda
cp terraform.tfvars.example terraform.tfvars
# edit source_bucket_name, github_owner, and github_repo
terraform init
terraform apply
terraform output github_actions_role_arn
terraform output lambda_function_name
```

In a normal AWS account, this stack can create a GitHub OIDC provider and IAM role so GitHub Actions does not need static AWS secrets.

In AWS Academy Learner Lab, IAM creation is often blocked. Use the root script instead:

```bash
./scripts/deploy-learner-lab.sh
```

That script sets:

```hcl
use_lab_role            = true
create_github_oidc_role = false
```

Lambda then uses the pre-created `LabRole`. GitHub Actions will need temporary Learner Lab credentials as repository secrets because the lab does not allow this project to create the OIDC role.

After applying, put these outputs into the workflow call or repository variables:

```text
SECURITY_SCAN_AWS_ROLE_ARN
SECURITY_SCAN_ARTIFACT_BUCKET
SECURITY_SCAN_LAMBDA_FUNCTION_NAME
SECURITY_SCAN_AWS_REGION
```

`SECURITY_SCAN_AWS_ROLE_ARN` is only available when `create_github_oidc_role = true`.

For Learner Lab mode, add these GitHub Actions secrets instead:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```
