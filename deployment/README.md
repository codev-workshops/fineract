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
selected purely through environment variables, and in-app Quartz scheduling
stays where it is.

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
| `terraform/modules/{network,security,data,secrets,iam,ecs,alb}` | reusable modules |
| `terraform/environments/dev` | the dev environment root |
| `terraform/localstack` | provider override and driver script for local validation |
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

## Validating with LocalStack

```bash
localstack start -d
deployment/terraform/localstack/validate.sh          # init + validate + plan
deployment/terraform/localstack/validate.sh apply    # apply what LocalStack emulates
deployment/terraform/localstack/validate.sh destroy
```

The script copies `providers_override.tf` and `localstack.auto.tfvars` into
`environments/dev`, runs Terraform with state under
`deployment/terraform/localstack/.state`, and removes the copies again on exit,
so the real configuration is never left pointing at the emulator.

`plan` covers the whole topology. `apply` is restricted to the modules LocalStack
serves under the community/freemium licence — VPC and subnets and endpoints,
security groups, the S3 content bucket, Secrets Manager, SSM Parameter Store and
IAM — roughly 60 resources. `rds`, `kafka`, `ecs`, `ecr` and `elbv2` answer
`501 InternalFailure` there, so the tfvars set `create_database = false` and
`broker_type = "none"` and the apply is `-target`ed at the supported modules.
With a licence that covers those services, drop those two overrides and the
targets.

### What LocalStack cannot tell you

It proves the configuration is well formed and that the resources it emulates
can be created. It does **not** validate:

- **ECS Fargate task execution** — nothing pulls the image, assumes the task
  role, resolves the `secrets` bindings or runs a container.
- **RDS/Aurora behaviour** — no engine, no Multi-AZ failover, no parameter group
  semantics, no reader endpoint.
- **MSK at runtime** — no broker, so no IAM handshake and no partition traffic
  between the batch manager and the workers.
- **ALB TLS termination** — no listener, no ACM validation, no target group
  health checking.

All four need a real AWS sandbox account.

## The local four-mode stack

Rehearses the deployment against real PostgreSQL, real Kafka and LocalStack S3:

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
running, and that a document uploaded through the write mode lands in the
LocalStack bucket and comes back byte-identical through the read mode — the
`DocumentTest` flow, over HTTP.

Kafka stands in for MSK for the reason given above. The read mode needs the
read-only tenant datasource (`config/docker/env/fineract-readonly-datasource.env`)
configured on the *write* service too, because that is what seeds the tenant row
the read mode later connects with; locally it points back at the same PostgreSQL,
in AWS at the Aurora reader endpoint.
