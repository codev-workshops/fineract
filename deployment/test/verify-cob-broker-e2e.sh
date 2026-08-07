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
# Phase 3 - Scenario 4: broker manager->worker remote-partitioning E2E (COB).
#
# Boots one batch-manager and one batch-worker against a real broker (ActiveMQ
# by default, Kafka optionally) using the existing smoke compose files, triggers
# LOAN_CLOSE_OF_BUSINESS on the manager, and asserts that the partitions were
# distributed to and completed by the worker:
#   * the job_run_history row for the COB job reaches "success", and
#   * Spring Batch recorded COMPLETED partition step executions (the worker steps).
#
# moto cannot emulate a JMS/Kafka broker, so this scenario deliberately uses the
# compose brokers rather than moto. See deployment/test/README.md.
#
#   MESSAGING=activemq ./verify-cob-broker-e2e.sh        # default
#   MESSAGING=kafka    ./verify-cob-broker-e2e.sh
#   ./verify-cob-broker-e2e.sh down                      # tear down

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly messaging="${MESSAGING:-activemq}"
readonly manager_url="${FINERACT_MANAGER_URL:-https://localhost:8443/fineract-provider/api/v1}"
readonly auth="${FINERACT_BASIC_AUTH:-mifos:password}"
readonly cob_job_name="${COB_JOB_NAME:-Loan COB}"

case "${messaging}" in
  activemq) compose_file="${repo_root}/docker-compose-postgresql-activemq.yml" ;;
  kafka) compose_file="${repo_root}/docker-compose-postgresql-kafka.yml" ;;
  *) echo "unknown MESSAGING '${messaging}', use activemq or kafka" >&2; exit 1 ;;
esac

export IMAGE_NAME="${IMAGE_NAME:-fineract:local}"

cd "${repo_root}"

if [[ "${1:-up}" == "down" ]]; then
  docker compose -f "${compose_file}" down -v
  exit 0
fi

api() {
  local method="$1" url="$2"
  shift 2
  curl -sS -k -u "${auth}" -H "Fineract-Platform-TenantId: default" -X "${method}" "${url}" "$@"
}

psql_tenant() {
  docker compose -f "${compose_file}" exec -T db \
    psql -qtAX -U root -d fineract_default -c "$1"
}

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo ">> building ${IMAGE_NAME} with jib"
  ./gradlew --no-daemon --console=plain :fineract-provider:jibDockerBuild \
    "-Djib.to.image=${IMAGE_NAME}" -x test -x cucumber
fi

echo ">> starting the ${messaging} manager + worker stack"
docker compose -f "${compose_file}" up --scale fineract-worker=1 -d

echo ">> waiting for manager and worker health"
curl -f -k --retry 60 --retry-all-errors --connect-timeout 30 --retry-delay 10 \
  https://localhost:8443/fineract-provider/actuator/health >/dev/null
curl -f -k --retry 60 --retry-all-errors --connect-timeout 30 --retry-delay 10 \
  https://localhost:8444/fineract-provider/actuator/health >/dev/null
echo "   manager and worker are UP"

echo ">> triggering ${cob_job_name} (LOAN_CLOSE_OF_BUSINESS) on the manager"
job_id="$(api GET "${manager_url}/jobs" | python3 -c \
  'import json,sys; jobs=json.load(sys.stdin); print(next(j["jobId"] for j in jobs if j["displayName"]=="'"${cob_job_name}"'"))')"
echo "   job id: ${job_id}"
api POST "${manager_url}/jobs/${job_id}?command=executeJob" >/dev/null

echo ">> waiting for the COB job_run_history to complete"
status=""
for _ in $(seq 1 60); do
  status="$(psql_tenant \
    "select status from job_run_history jrh join job j on j.id=jrh.job_id \
     where j.display_name='${cob_job_name}' order by jrh.id desc limit 1;")"
  [[ "${status}" == "success" ]] && break
  [[ "${status}" == "error" ]] && { echo "COB job failed" >&2; break; }
  sleep 5
done
echo "   last job_run_history status: ${status:-<none>}"
[[ "${status}" == "success" ]] || { echo "COB did not complete successfully" >&2; exit 1; }

echo ">> asserting Spring Batch partition steps completed (worker executed partitions)"
partition_steps="$(psql_tenant \
  "select count(*) from batch_step_execution \
   where step_name like '%:partition%' and status='COMPLETED';")"
echo "   completed partition step executions: ${partition_steps:-0}"
[[ "${partition_steps:-0}" -ge 1 ]] || { echo "no completed partition steps - worker did not run any" >&2; exit 1; }

echo ">> all checks passed: COB distributed across manager+worker on ${messaging}"
