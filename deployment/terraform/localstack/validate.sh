#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Runs the dev environment root against LocalStack.
#
#   ./validate.sh            init + validate + plan of the whole stack
#   ./validate.sh apply      the above, then apply the emulated subset
#   ./validate.sh destroy    tear the LocalStack resources down
#
# `plan` covers every resource. `apply` is restricted to the modules LocalStack
# actually emulates under the community/freemium licence: the VPC, the security
# groups, the S3 content bucket, Secrets Manager, SSM Parameter Store and IAM.
# ECS, ECR, ELBv2, RDS and MSK answer with HTTP 501 there; see the README.
#
# The override file and the tfvars are copied into environments/dev for the
# duration of the run and removed again on exit, so the real configuration is
# never left pointing at LocalStack.

set -euo pipefail

readonly here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly dev_dir="${here}/../environments/dev"
readonly endpoint="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
readonly state_dir="${here}/.state"
readonly action="${1:-plan}"

# Modules whose resources LocalStack can actually create.
readonly targets=(
  -target=module.network
  -target=module.security
  -target=module.data
  -target=module.secrets
  -target=module.iam
)

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if ! curl -sf "${endpoint}/_localstack/health" >/dev/null; then
  echo "LocalStack is not reachable at ${endpoint}. Start it with: localstack start -d" >&2
  exit 1
fi

cleanup() {
  rm -f "${dev_dir}/providers_override.tf" "${dev_dir}/localstack.auto.tfvars"
}
trap cleanup EXIT

mkdir -p "${state_dir}"
cp "${here}/providers_override.tf" "${dev_dir}/providers_override.tf"
grep -v '^certificate_arn' "${here}/localstack.auto.tfvars" >"${dev_dir}/localstack.auto.tfvars"

# A certificate the emulation knows about, so the plan of the HTTPS listener is
# not built on a made up ARN. ACM is not always enabled; the placeholder from
# the tfvars is good enough for a plan when it is not.
if certificate_arn="$(aws --endpoint-url "${endpoint}" acm request-certificate \
  --domain-name fineract.localstack.test \
  --validation-method DNS \
  --query CertificateArn --output text 2>/dev/null)"; then
  echo "certificate_arn = \"${certificate_arn}\"" >>"${dev_dir}/localstack.auto.tfvars"
else
  echo ">> acm is not available at ${endpoint}; using the placeholder certificate ARN"
  grep '^certificate_arn' "${here}/localstack.auto.tfvars" >>"${dev_dir}/localstack.auto.tfvars"
fi

cd "${dev_dir}"

terraform init -input=false -reconfigure \
  -backend-config="path=${state_dir}/terraform.tfstate"
terraform validate

case "${action}" in
  plan)
    # Planned with the database and the broker switched back on, so the whole
    # dev topology is exercised even though it cannot be applied here.
    terraform plan -input=false -var=create_database=true -var=broker_type=msk
    ;;
  apply)
    terraform plan -input=false "${targets[@]}" -out="${state_dir}/plan.tfplan"
    terraform apply -input=false "${state_dir}/plan.tfplan"
    ;;
  destroy)
    terraform destroy -input=false -auto-approve "${targets[@]}"
    ;;
  *)
    echo "usage: $0 [plan|apply|destroy]" >&2
    exit 2
    ;;
esac
