<!--
    Licensed to the Apache Software Foundation (ASF) under one
    or more contributor license agreements. See the NOTICE file
    distributed with this work for additional information
    regarding copyright ownership. The ASF licenses this file
    to you under the Apache License, Version 2.0 (the
    "License"); you may not use this file except in compliance
    with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing,
    software distributed under the License is distributed on an
    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
    KIND, either express or implied. See the License for the
    specific language governing permissions and limitations
    under the License.
-->

# Phase 3 — AWS migration behaviour tests

Automated tests that validate the behaviours the AWS deployment relies on
(`deployment/README.md`): the S3 content store, the ECS task-role credential
chain, the read replica, the batch manager→worker split over a real broker, the
four instance modes, TLS termination at the ALB, and secrets injection.

Nothing in the production application/job/scheduler code is changed. The only
additions are tests, a test-only moto Testcontainers helper, compose helper
scripts, and this document.

## What runs against what

| # | Scenario | Backing service | Where |
|---|----------|-----------------|-------|
| 1 | S3 content-store round trip | **moto** (Testcontainers) | `fineract-provider` test |
| 2 | `DefaultCredentialsProvider` / IAM-role path | **moto** (Testcontainers) | `fineract-provider` test |
| 3 | Read replica (read-only datasource) | two **Postgres** (Testcontainers) | `fineract-provider` test |
| 4 | COB manager→worker remote partitioning | **ActiveMQ / Kafka** (compose) | compose script |
| 5 | Four-mode smoke + single-manager scheduler | **Postgres + moto + Kafka** (compose) | compose script |
| 6 | ALB-terminated TLS / forwarded headers | embedded Tomcat | `fineract-provider` test |
| 7 | Secrets-injection boot (positive + fail-fast) | — | `fineract-provider` test |

moto stands in for S3, Secrets Manager and the STS/metadata credential
endpoints. It **cannot** emulate a stateful engine — there is no RDS, no MSK/
Kafka, no ActiveMQ — so scenarios 3, 4 and 5 use real Postgres/broker containers
instead. See "moto limitations" below.

## moto

The tests launch moto through Testcontainers, so no manual step is needed. To
run a standalone moto server yourself (matching `config/docker/compose/moto.yml`):

```bash
docker run --rm -p 5000:5000 motoserver/moto:latest
# or: pip install 'moto[server]' && moto_server -p 5000
```

Point any AWS SDK v2 client at it with an endpoint override
(`fineract.content.s3.endpoint=http://localhost:5000`, path-style addressing on)
or the SDK-wide `AWS_ENDPOINT_URL=http://localhost:5000`. moto accepts any
non-blank credentials.

## Running the JUnit tests (scenarios 1, 2, 3, 6, 7)

These need a Docker daemon (Testcontainers). No AWS account, no secrets.

```bash
# all of them
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.aws.*" \
  --tests "org.apache.fineract.infrastructure.core.service.database.ReadReplicaDataSourceIntegrationTest"

# individually
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.aws.S3ContentStoreMotoRoundTripTest"
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.aws.S3DefaultCredentialsProviderMotoTest"
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.core.service.database.ReadReplicaDataSourceIntegrationTest"
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.aws.ForwardedHeadersTlsTerminationTest"
./gradlew :fineract-provider:test --tests "org.apache.fineract.infrastructure.aws.SecretsInjectionBootTest"
```

The reusable moto wrapper is
`fineract-provider/src/test/java/org/apache/fineract/infrastructure/aws/testsupport/MotoContainer.java`
(create buckets, build SDK clients pointed at moto).

## Running the COB broker E2E (scenario 4)

Boots one batch-manager and one batch-worker against a real broker, triggers
`LOAN_CLOSE_OF_BUSINESS`, and asserts the `job_run_history` row reaches
`success` and that Spring Batch recorded COMPLETED partition step executions
(i.e. the worker ran the partitions).

```bash
# ActiveMQ (default)
MESSAGING=activemq deployment/test/verify-cob-broker-e2e.sh
# Kafka
MESSAGING=kafka    deployment/test/verify-cob-broker-e2e.sh
# tear down
MESSAGING=activemq deployment/test/verify-cob-broker-e2e.sh down
```

The image is built with `:fineract-provider:jibDockerBuild` into `fineract:local`
on first run (override with `IMAGE_NAME`). Uses `docker-compose-postgresql-activemq.yml`
/ `docker-compose-postgresql-kafka.yml`, the same compose stacks exercised by
`.github/workflows/smoke-messaging.yml`.

## Running the four-mode smoke (scenario 5)

Boots write (Liquibase owner), read, batch-manager (singleton) and batch-worker
from the same image, then checks that:

* every service reports `UP` on `/actuator/health`,
* exactly one batch-manager container is running, and
* the scheduler is active on exactly one node — the batch manager — confirming a
  scheduled job fires on a single node.

```bash
deployment/local/run-multimode.sh          # build (if needed) + bring up
deployment/local/verify-multimode.sh       # run the assertions
deployment/local/run-multimode.sh down      # tear down
```

## moto limitations

moto is an API mock, not an engine:

* **No RDS** — it mocks the RDS control plane, not a SQL engine. The read-replica
  test (scenario 3) uses two real Postgres containers.
* **No MSK / Kafka and no ActiveMQ** — moto has no message broker. The COB E2E
  (scenario 4) and the batch modes in the four-mode smoke (scenario 5) use the
  real ActiveMQ/Kafka compose services.
* **Credentials are not validated** — moto accepts any non-blank key, so the
  IAM-role test (scenario 2) proves the SDK resolves credentials through the
  default chain, not that a real IAM policy allows the call.

## CI

`.github/workflows/aws-migration-tests.yml` runs the JUnit scenarios (moto +
Postgres via Testcontainers) on every push/PR. The broker E2E is covered by the
existing `smoke-messaging.yml` compose matrix.
