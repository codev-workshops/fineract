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
# Checks the stack started by run-multimode.sh:
#   1. the write and read modes answer UP on /actuator/health
#   2. exactly one batch manager is running
#   3. a document round-trips through the LocalStack S3 content store
#
# The document flow mirrors integration-tests DocumentTest: create a client,
# upload a file against it, download it again and compare the bytes.

set -euo pipefail

readonly project="${COMPOSE_PROJECT_NAME:-fineract}"
readonly s3_endpoint="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
readonly write_url="${FINERACT_WRITE_URL:-http://localhost:8443/fineract-provider/api/v1}"
readonly read_url="${FINERACT_READ_URL:-http://localhost:8444/fineract-provider/api/v1}"
readonly bucket="${FINERACT_CONTENT_BUCKET:-fineract-content}"
readonly auth="${FINERACT_BASIC_AUTH:-mifos:password}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

api() {
  local method="$1" url="$2"
  shift 2
  curl -sS -u "${auth}" -H "Fineract-Platform-TenantId: default" -X "${method}" "${url}" "$@"
}

echo ">> health"
for name_url in "write ${write_url%/api/v1}" "read ${read_url%/api/v1}"; do
  set -- ${name_url}
  status="$(curl -sf "${2}/actuator/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  echo "   ${1}: ${status}"
  [[ "${status}" == "UP" ]] || { echo "${1} mode is not UP" >&2; exit 1; }
done

echo ">> batch manager instances"
managers="$(docker ps -q \
  --filter "label=com.docker.compose.project=${project}" \
  --filter "label=com.docker.compose.service=fineract-batch-manager" | wc -l)"
echo "   running: ${managers}"
[[ "${managers}" -eq 1 ]] || { echo "expected exactly one batch manager, found ${managers}" >&2; exit 1; }

echo ">> document round trip through S3"
client_id="$(api POST "${write_url}/clients" \
  -H 'Content-Type: application/json' \
  -d '{"officeId":1,"legalFormId":1,"firstname":"Doc","lastname":"Roundtrip","locale":"en","dateFormat":"dd MMMM yyyy","active":false}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["clientId"])')"
echo "   client: ${client_id}"

upload="$(mktemp)"
download="$(mktemp)"
trap 'rm -f "${upload}" "${download}"' EXIT
head -c 4096 /dev/urandom >"${upload}"

document_id="$(api POST "${write_url}/clients/${client_id}/documents" \
  -F "file=@${upload};type=application/octet-stream;filename=roundtrip.bin" \
  -F "name=roundtrip" -F "description=s3 round trip" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["resourceId"])')"
echo "   document: ${document_id}"

objects="$(aws --endpoint-url "${s3_endpoint}" s3api list-objects-v2 \
  --bucket "${bucket}" --prefix "documents/clients/${client_id}/" --output json |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Contents", [])))')"
echo "   objects under s3://${bucket}/documents/clients/${client_id}/: ${objects}"
[[ "${objects}" -ge 1 ]] || { echo "nothing was written to the content bucket" >&2; exit 1; }

# Reads go through the read mode, proving it shares the same content store.
curl -sSf -u "${auth}" -H "Fineract-Platform-TenantId: default" \
  "${read_url}/clients/${client_id}/documents/${document_id}/attachment" -o "${download}"

if cmp -s "${upload}" "${download}"; then
  echo "   downloaded bytes match the upload"
else
  echo "downloaded document differs from the uploaded one" >&2
  exit 1
fi

echo ">> all checks passed"
