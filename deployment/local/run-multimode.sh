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
# Boots docker-compose-postgresql-multimode.yml: the four Fineract instance
# modes against PostgreSQL and LocalStack S3.
#
#   ./run-multimode.sh          build the image if needed, then bring the stack up
#   ./run-multimode.sh down     tear it down, volumes included
#
# Passwords are generated per run and only ever live in this shell's
# environment. Export them yourself to keep a stack across invocations.

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly compose_file="${repo_root}/docker-compose-postgresql-multimode.yml"
readonly bucket="${FINERACT_CONTENT_BUCKET:-fineract-content}"

export IMAGE_NAME="${IMAGE_NAME:-fineract:local}"
export FINERACT_DB_PASSWORD="${FINERACT_DB_PASSWORD:-$(openssl rand -hex 24)}"
export FINERACT_MASTER_PASSWORD="${FINERACT_MASTER_PASSWORD:-$(openssl rand -hex 24)}"
export FINERACT_KEYSTORE_PASSWORD="${FINERACT_KEYSTORE_PASSWORD:-$(openssl rand -hex 24)}"

cd "${repo_root}"

if [[ "${1:-up}" == "down" ]]; then
  docker compose -f "${compose_file}" down -v
  exit 0
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo ">> building ${IMAGE_NAME} with jib"
  ./gradlew --no-daemon --console=plain :fineract-provider:jibDockerBuild \
    "-Djib.to.image=${IMAGE_NAME}" -x test -x cucumber
fi

echo ">> starting postgres and localstack"
docker compose -f "${compose_file}" up -d db localstack
docker compose -f "${compose_file}" exec -T localstack \
  awslocal s3api create-bucket --bucket "${bucket}"

echo ">> starting the four instance modes"
docker compose -f "${compose_file}" up -d

echo ">> waiting for the write and read modes to report healthy"
for service in fineract-write fineract-read; do
  container="$(docker compose -f "${compose_file}" ps -q "${service}")"
  for _ in $(seq 1 120); do
    state="$(docker inspect -f '{{.State.Health.Status}}' "${container}")"
    [[ "${state}" == "healthy" ]] && break
    [[ "${state}" == "unhealthy" ]] && { echo "${service} is unhealthy" >&2; exit 1; }
    sleep 5
  done
  echo "   ${service}: ${state}"
done

docker compose -f "${compose_file}" ps
