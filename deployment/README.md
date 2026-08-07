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

# Deploying Fineract on AWS

Terraform for an ECS Fargate deployment of the unmodified Fineract image, plus a
local stack that rehearses the same topology on a laptop.

The application is not changed by any of this: the four instance modes are
selected purely through environment variables. The one source change that does
exist is a feature flag (`FINERACT_IN_APP_SCHEDULING_ENABLED`, default `true`)
that lets the batch manager keep serving the `executeJob` API while an external
scheduler owns *when* jobs run — see
[Phase 4: EventBridge Scheduler trigger cutover](#phase-4-eventbridge-scheduler-trigger-cutover).
Job execution, Spring Batch state and COB remote partitioning stay inside
Fineract.

```
                    ┌──────────── ALB (HTTPS, ACM) ────────────┐
                    │   GET → read TG        * → write TG      │
                    └───────┬──────────────────────┬───────────┘
                            │                      │
  private app subnets   ┌───▼────┐  ┌──────┐  ┌────▼────┐  ┌────────┐
                        │ write  │  │ read │  │ batch   │  │ batch  │
                        │(liqui- │  │      │  │ manager │  │ worker │
                        │ base)  │  │      │  │ (1 task)│  │ (n)    │
                        └───┬────┘  └──┬───┘  └────┬────┘  └───┬────┘
                            │          │           │           │
  private data subnets  ┌───▼──────────▼───┐   ┌───▼───────────▼───┐   ┌────┐
                        │ Aurora PostgreSQL│   │ MSK (IAM auth)    │   │ S3 │
                        │ writer + reader  │   └───────────────────┘   └────┘
                        └──────────────────┘
```

| path | what it is |
| --- | --- |
| `terraform/modules/{network,security,data,secrets,iam,ecs,alb,scheduler}` | reusable modules |
| `lambda/scheduler-invoker` | the thin Lambda that calls `executeJob`, plus its moto tests |
| `cron/quartz_to_eventbridge.py`, `cron/seeded-jobs-mapping.md` | Quartz→EventBridge cron translator and its output |
| `terraform/environments/dev` | the dev environment root |
| `terraform/moto` | provider override and driver script for local validation |
| `local/run-multimode.sh`, `local/verify-multimode.sh` | the local four-mode stack |
| `../docker-compose-postgresql-multimode.yml` | its compose file |

## Building and pushing the image

There is no Dockerfile; the image comes from jib.

```bash
# local image, used by the compose stack
./gradlew :fineract-provider:jibDockerBuild -Djib.to.image=fineract:local -x test -x cucumber

# push to the ECR repository created by Terraform
repo="$(terraform -chdir=deployment/terraform/environments/dev output -raw ecr_repository_url)"
aws ecr get-login-password --region "${AWS_REGION}" |
  docker login --username AWS --password-stdin "${repo%%/*}"
./gradlew :fineract-provider:jib -Djib.to.image="${repo}:$(git rev-parse --short HEAD)" -x test -x cucumber
```

Then set `image_uri` in the tfvars to the tag you pushed.

## Applying against a real account

```bash
cd deployment/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill in region, AZs, certificate_arn, image_uri
terraform init
terraform plan
terraform apply
```

The root creates, in order: the VPC and its endpoints, the security groups,
Aurora and the content bucket and MSK, the secrets and SSM parameters, the IAM
roles, the ALB, and finally the ECS cluster with one service per instance mode.

Two things need doing once, out of band, before the tasks come up healthy:

- **the tenant role.** Aurora only creates the master user. If
  `tenant_db_username` is left at its default, create that role with the value
  of the `tenant-db-password` secret and grant it the tenant databases. Point
  `tenant_db_username` at the master username instead if you would rather not.
- **DNS.** Point the record covered by `certificate_arn` at the
  `alb_dns_name` output.

### Rollback

`terraform destroy` removes everything this stack created. Set
`db_deletion_protection = false` and `db_skip_final_snapshot = true` first, or
Aurora will refuse. To roll back a deployment rather than the infrastructure,
re-apply with the previous `image_uri`: ECS keeps the older task definition
revisions, and no application code changed, so reverting the branch restores the
pre-Phase-2 state exactly.

## How the pieces fit

**Instance modes.** All four services share one image and one task definition
family. They differ only in `FINERACT_MODE_*`. Liquibase runs on the write
service alone (`FINERACT_LIQUIBASE_ENABLED=true`, 10 minute health check grace
period); everywhere else it is off. The batch manager has `desired_count = 1`
and deployment percentages of 0/100, so ECS drains the old task before starting
the new one and two managers never overlap. Its Terraform entry has no
autoscaling block.

**The broker is not optional.** Fineract refuses to start a batch manager that
is not also a batch worker unless a remote message handler is configured
(`FineractRemoteJobMessageHandlerCondition`). Splitting manager and workers into
separate services therefore requires MSK (or Amazon MQ). MSK IAM auth is pure
client configuration — `SASL_SSL` + `AWS_MSK_IAM` passed through the
`*_EXTRA_PROPERTIES` variables — with no credentials anywhere; the task role
carries `kafka-cluster:Connect` and the topic/group permissions instead.

**Secrets.** The DB password, tenant DB password, master password and keystore
password live in Secrets Manager and are bound through the task definition
`secrets` block, so they reach the container as environment variables without
ever appearing in the task definition, in Terraform variables, or in a committed
env file. Values are generated by `random_password`; `ignore_changes` on the
secret version means rotating one by hand is not undone by the next apply.
Non-secret endpoints (JDBC URL, bucket name, region, bootstrap brokers) go to
SSM Parameter Store.

**S3.** `FINERACT_CONTENT_S3_ACCESS_KEY` and `..._SECRET_KEY` are deliberately
empty: `ContentS3Config` then falls back to `DefaultCredentialsProvider`, which
picks up the ECS task role. Only the write and batch-worker roles get
`s3:PutObject`/`DeleteObject`; the read role is limited to `GetObject`/`ListBucket`
and gets no broker permissions at all.

**TLS.** The ALB terminates TLS with an ACM certificate, redirects port 80, and
talks HTTP to the tasks (`FINERACT_SERVER_SSL_ENABLED=false`); the app has
`server.forward-headers-strategy=framework`, so it still sees the original
scheme. For end-to-end TLS instead, set `app_tls_enabled = true` — the target
groups switch to HTTPS — and give the tasks a keystore: add the keystore file to
the image or mount it, set `FINERACT_SERVER_SSL_KEY_STORE`, and keep the
existing `FINERACT_SERVER_SSL_KEY_STORE_PASSWORD` secret binding.

**Health checks.** Both the ALB target groups and the container health checks
use `/fineract-provider/actuator/health` — note the servlet context path, which
is easy to leave out.

## Validating with moto

```bash
pip install 'moto[server]'
MOTO_IAM_LOAD_MANAGED_POLICIES=true moto_server -p 5000
# or: docker run -d -p 5000:5000 -e MOTO_IAM_LOAD_MANAGED_POLICIES=true motoserver/moto

deployment/terraform/moto/validate.sh          # init + validate + plan
deployment/terraform/moto/validate.sh apply    # apply what moto implements
deployment/terraform/moto/validate.sh destroy
```

moto serves every API from that one port, S3 included, in path-style. The
managed-policy flag is not optional: the ECS execution role attaches
`AmazonECSTaskExecutionRolePolicy`, and without it moto answers `NoSuchEntity`.
The script checks for both before doing anything.

It copies `providers_override.tf` and `moto.auto.tfvars` into
`environments/dev`, runs Terraform with state under
`deployment/terraform/moto/.state`, and removes the copies again on exit, so the
real configuration is never left pointing at the emulator.

`plan` covers the whole topology — 139 resources. `apply` creates 132 of them:
the VPC with its endpoints, the security groups, the Aurora cluster and its
instances, the content bucket, Secrets Manager, SSM Parameter Store, IAM, ECR,
the ECS cluster with all four services and their task definitions, the ALB
with its listeners and target groups, and the Phase 4 trigger stack (the
scheduler-invoker Lambda and its role, log group and API secret, the SQS DLQ,
the EventBridge Scheduler role and schedules). `destroy` removes all 132.

The scheduler stack applies cleanly against moto: `aws_scheduler_schedule`,
`aws_lambda_function` (recorded, never invoked), `aws_sqs_queue`,
`aws_secretsmanager_secret`, and the IAM roles/policies are all implemented. See
the Phase 4 section for what the moto apply proves and what it cannot.

Two pieces are planned but not applied, and the tfvars say so:

- **MSK** (`broker_type = "none"`): moto accepts `CreateCluster` but leaves the
  cluster in `CREATING` for ever, so the provider would block until its timeout.
- **Application Auto Scaling** (`enable_autoscaling = false`):
  `ListTagsForResource` is unimplemented, and the provider calls it after every
  create.

### What moto cannot tell you

It proves the configuration is well formed and that the resources it implements
can be created, read back and destroyed. It records API calls; it runs nothing.
It does **not** validate:

- **ECS Fargate task execution** — the services and task definitions exist as
  records; nothing pulls the image, assumes the task role, resolves the
  `secrets` bindings or runs a container.
- **RDS/Aurora behaviour** — the cluster and instances exist, but there is no
  engine, no Multi-AZ failover, no parameter group semantics and the reader
  endpoint resolves nowhere.
- **MSK at runtime** — no broker, so no IAM handshake and no partition traffic
  between the batch manager and the workers.
- **ALB TLS termination** — the listeners exist, but nothing terminates TLS,
  validates the ACM certificate or health-checks a target.

All four need a real AWS sandbox account.

## Phase 4: EventBridge Scheduler trigger cutover

Phase 4 moves *only the trigger* out of the application. Instead of the batch
manager firing its own in-app Quartz cron triggers, **Amazon EventBridge
Scheduler → a thin Lambda → the existing `POST /v1/jobs/{jobId}?command=executeJob`
API** decides when jobs run. Everything downstream of that API call is unchanged:
Spring Batch, `job_run_history` recording via `SchedulerJobListener`, and COB
remote partitioning across the manager and workers all stay inside Fineract.

```
  EventBridge Scheduler                 Lambda (VPC, app subnets)         Fineract batch manager
  ┌─────────────────────┐  invoke   ┌───────────────────────────┐  HTTPS  ┌──────────────────────┐
  │ cron(...) per job,   ├──────────►│ read base_url + creds from ├────────►│ POST /v1/jobs/{id}     │
  │ tenant tz, static    │  role     │ Secrets Manager; one call  │ 202     │   ?command=executeJob  │
  │ input {jobId,tenants}│           │ per tenant with            │         │ (batch-manager mode,   │
  │ retries=0 → SQS DLQ  │           │ Fineract-Platform-TenantId │         │  in-app scheduling off)│
  └─────────────────────┘           └───────────────────────────┘         └──────────────────────┘
```

### The trigger-only design

- **Execution never leaves Fineract.** The Lambda is a caller; it holds no job
  logic and no Spring Batch state. A non-202 response is a failure it surfaces,
  not something it works around.
- The batch manager keeps `FINERACT_MODE_BATCH_MANAGER_ENABLED=true`, so
  `SchedulerJobApiResource.executeJob` still accepts the call and returns `202`.
  The new flag `FINERACT_IN_APP_SCHEDULING_ENABLED=false` makes
  `JobSchedulerServiceImpl.onApplicationEvent` log that in-app scheduling is
  disabled and return **before** registering any Quartz trigger.
- **Node scoping.** `executeJobWithParameters` rejects a job whose stored
  `nodeId` does not match this instance's `FINERACT_NODE_ID` (or `0`) with
  `JobNodeIdMismatchingException`. The seeded jobs default to `nodeId = 1`, so
  the batch manager runs with `FINERACT_NODE_ID = 1`
  (`var.batch_manager_node_id`) and the Lambda targets that instance. Point a
  schedule at a job on another node only if a batch manager on that node exists.
- **No double-firing.** Each schedule sets `maximum_retry_attempts = 0` and a
  DLQ, so a failed invocation lands in SQS instead of re-firing. Fineract's own
  `currently_running` / `updates_allowed` guards remain the backstop.

### Translating the Quartz crons

Quartz cron is 6–7 fields with a leading **seconds** field and an optional
trailing **year**; EventBridge Scheduler cron is 6 fields, no seconds,
`cron(minutes hours day-of-month month day-of-week year)`. Day-of-week numbering
matches (`1–7 = SUN–SAT`), and exactly one of day-of-month / day-of-week must be
`?`. The translator handles the seconds/year drop, the `?`/`*` rules and rejects
anything that cannot be represented (e.g. a sub-minute schedule, or seconds other
than `0`) rather than silently changing behaviour.

```bash
# one expression
python3 deployment/cron/quartz_to_eventbridge.py --expr "0 0 22 1/1 * ? *" --timezone Asia/Kolkata

# every seeded job, as the mapping doc that is checked in
python3 deployment/cron/quartz_to_eventbridge.py \
  --liquibase fineract-provider/src/main/resources/db/changelog/tenant/parts/0002_initial_data.xml \
  --timezone Asia/Kolkata --format markdown > deployment/cron/seeded-jobs-mapping.md

# or JSON, straight into a job_schedules tfvars entry
python3 deployment/cron/quartz_to_eventbridge.py --liquibase <path> --timezone Asia/Kolkata --format json
```

`deployment/cron/seeded-jobs-mapping.md` is that output for all 32 seeded jobs
against `Asia/Kolkata`; every one translates 1:1. Any job that did not would be
listed there as non-translatable with the reason.

### Running the Lambda unit tests (moto)

The handler is tested against a **local HTTP stub** (returning 202 / 405 / 500)
and a moto-mocked Secrets Manager — no real AWS and no running Fineract:

```bash
python3 -m venv deployment/.venv-phase4 && . deployment/.venv-phase4/bin/activate
pip install -r deployment/lambda/scheduler-invoker/requirements-dev.txt
pytest deployment/lambda/scheduler-invoker/tests deployment/cron/tests -q
```

The tests assert the URL/path/query (`command=executeJob`), the
`Fineract-Platform-TenantId` header per tenant, one call per tenant, that every
tenant is attempted, and that 202 succeeds while any non-202 (405, 500) fails so
EventBridge routes the event to the DLQ. If your environment exports
`AWS_ENDPOINT_URL` (this repo's blueprint points it at moto), the tests clear it
so the in-process `mock_aws` intercepts the Secrets Manager calls.

### Terraform against moto

`deployment/terraform/moto/validate.sh apply` creates the scheduler stack along
with the rest and reads it back; `providers_override.tf` adds `lambda`,
`scheduler` and `sqs` endpoints. This proves the IaC is well formed and that the
resources are created/destroyed cleanly. **moto records the Lambda; it never
runs it, and it cannot execute the Spring Batch job** — that needs the compose
stack below or a real account.

### End-to-end validation (compose, not moto)

moto cannot run the job, so exercise the real path against the Phase 2 compose
stack (real PostgreSQL, and the broker for COB):

1. Boot a batch manager against real Postgres with
   `FINERACT_IN_APP_SCHEDULING_ENABLED=false`,
   `FINERACT_MODE_BATCH_MANAGER_ENABLED=true`, `FINERACT_NODE_ID=1`
   (`deployment/local/run-multimode.sh` brings up the four-mode stack; set the
   flag on the batch-manager service). Confirm in its logs:
   `In-app job scheduling is disabled (external/EventBridge-driven); not registering any Quartz triggers`
   and that **no** Quartz trigger fires.
2. Run the handler locally against that manager. Put the manager's URL and
   credentials in a Secrets Manager secret (against moto or a real account) and
   point the handler at it, then invoke it exactly as EventBridge would:

   ```bash
   cd deployment/lambda/scheduler-invoker
   export FINERACT_API_SECRET_ID=<secret-arn>   # {base_url, username, password, verify_tls}
   python3 -c 'import handler; print(handler.handler({"jobId": 1, "tenantIds": ["default"]}, None))'
   ```

   `base_url` is up to and including the context + application path (e.g.
   `https://localhost:8445/fineract-provider/api`); the handler appends
   `/v1/jobs/{id}?command=executeJob`.
3. Assert the run is recorded: a new row in `job_run_history` for that job
   (written by `SchedulerJobListener`), the API returned `202`, and no duplicate
   or in-app execution occurred. If COB is exercised, it still completes across
   the manager and worker over the compose broker — Phase 4 changed none of that.

**moto cannot execute the Spring Batch job itself.** The moto tests prove the
Lambda calls the right endpoint and handles responses; only a running Fineract
(compose or a real account) proves the job actually runs and lands in
`job_run_history`.

### Rollback

- **Immediate:** set `FINERACT_IN_APP_SCHEDULING_ENABLED=true` on the batch
  manager (or drop it — the default is `true`;
  `var.batch_manager_in_app_scheduling_enabled = true`). In-app Quartz scheduling
  resumes on the next boot; nothing about job execution has to be redeployed
  because it never left Fineract.
- **Stop external triggering:** disable the schedules (set their `enabled` to
  `false`) or `terraform destroy` the Phase 4 resources
  (`-target=module.scheduler`, or `enable_scheduler = false`).
- **Full revert:** reverting the Phase 4 branch restores the prior behaviour
  exactly.

## The local four-mode stack

Rehearses the deployment against real PostgreSQL, real Kafka and moto S3:

```bash
deployment/local/run-multimode.sh      # builds fineract:local if needed, waits for health
deployment/local/verify-multimode.sh   # health, single manager, S3 round trip
deployment/local/run-multimode.sh down # docker compose down -v
```

`run-multimode.sh` generates `FINERACT_DB_PASSWORD`, `FINERACT_MASTER_PASSWORD`
and `FINERACT_KEYSTORE_PASSWORD` per run; the compose file refuses to start
without them. Export your own to keep a stack across invocations.

Ports: write `8443`, read `8444`, batch manager `8445`, batch worker `8446`.

`verify-multimode.sh` checks that the write and read modes report `UP` on
`/fineract-provider/actuator/health`, that exactly one batch manager container is
running, and that a document uploaded through the write mode lands in the moto
bucket and comes back byte-identical through the read mode — the
`DocumentTest` flow, over HTTP.

Kafka stands in for MSK for the reason given above. The read mode needs the
read-only tenant datasource (`config/docker/env/fineract-readonly-datasource.env`)
configured on the *write* service too, because that is what seeds the tenant row
the read mode later connects with; locally it points back at the same PostgreSQL,
in AWS at the Aurora reader endpoint.
