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
# Runs the dev environment root against a moto server.
#
#   ./validate.sh            init + validate + plan of the whole stack
#   ./validate.sh apply      the above, then apply it
#   ./validate.sh destroy    tear the moto resources down
#
# Start the server first, either with the CLI or the container. The execution
# role attaches AmazonECSTaskExecutionRolePolicy, and moto only knows the AWS
# managed policies when MOTO_IAM_LOAD_MANAGED_POLICIES is set:
#
#   pip install 'moto[server]'
#   MOTO_IAM_LOAD_MANAGED_POLICIES=true moto_server -p 5000
#   docker run -d -p 5000:5000 -e MOTO_IAM_LOAD_MANAGED_POLICIES=true motoserver/moto
#
# The override file and the tfvars are copied into environments/dev for the
# duration of the run and removed again on exit, so the real configuration is
# never left pointing at the emulator. See the README for what moto does not
# tell you.

set -euo pipefail

readonly here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly dev_dir="${here}/../environments/dev"
readonly endpoint="${MOTO_ENDPOINT:-http://localhost:5000}"
readonly state_dir="${here}/.state"
readonly action="${1:-plan}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if ! curl -sf "${endpoint}/moto-api/" >/dev/null; then
  echo "moto is not reachable at ${endpoint}. Start it with:" >&2
  echo "  MOTO_IAM_LOAD_MANAGED_POLICIES=true moto_server -p 5000" >&2
  exit 1
fi

if ! aws --endpoint-url "${endpoint}" iam get-policy \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
  >/dev/null 2>&1; then
  echo "moto does not know the AWS managed policies; restart it with" >&2
  echo "MOTO_IAM_LOAD_MANAGED_POLICIES=true, or the execution role cannot be created." >&2
  exit 1
fi

cleanup() {
  rm -f "${dev_dir}/providers_override.tf" "${dev_dir}/moto.auto.tfvars"
}
trap cleanup EXIT

mkdir -p "${state_dir}"
cp "${here}/providers_override.tf" "${dev_dir}/providers_override.tf"
grep -v '^certificate_arn' "${here}/moto.auto.tfvars" >"${dev_dir}/moto.auto.tfvars"

# The HTTPS listener needs a certificate the emulation knows about rather than
# the placeholder ARN from the tfvars.
certificate_arn="$(aws --endpoint-url "${endpoint}" acm request-certificate \
  --domain-name fineract.moto.test \
  --validation-method DNS \
  --query CertificateArn --output text)"
echo "certificate_arn = \"${certificate_arn}\"" >>"${dev_dir}/moto.auto.tfvars"

cd "${dev_dir}"

terraform init -input=false -reconfigure \
  -backend-config="path=${state_dir}/terraform.tfstate"
terraform validate

case "${action}" in
  plan)
    # MSK and the autoscaling targets are planned but never applied here; see
    # the tfvars for why.
    terraform plan -input=false -var=broker_type=msk -var=enable_autoscaling=true
    ;;
  apply)
    terraform plan -input=false -out="${state_dir}/plan.tfplan"
    terraform apply -input=false "${state_dir}/plan.tfplan"
    ;;
  destroy)
    terraform destroy -input=false -auto-approve
    ;;
  *)
    echo "usage: $0 [plan|apply|destroy]" >&2
    exit 2
    ;;
esac
