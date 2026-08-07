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

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  content_bucket_name = coalesce(var.content_bucket_name, "${local.name_prefix}-content")

  # Read traffic is only routed once a read-only datasource has been configured
  # against the Aurora reader endpoint.
  read_enabled = var.enable_read_service
}

# The database has to be created with its master password, so the value is
# generated here and handed to both the cluster and Secrets Manager.
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%*-_=+"
}

module "network" {
  source = "../../modules/network"

  name_prefix                = local.name_prefix
  region                     = var.region
  vpc_cidr                   = var.vpc_cidr
  availability_zones         = var.availability_zones
  public_subnet_cidrs        = var.public_subnet_cidrs
  app_subnet_cidrs           = var.app_subnet_cidrs
  data_subnet_cidrs          = var.data_subnet_cidrs
  single_nat_gateway         = var.single_nat_gateway
  enable_interface_endpoints = var.enable_interface_endpoints

  tags = local.tags
}

module "security" {
  source = "../../modules/security"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  app_port          = var.app_port
  broker_ports      = var.broker_type == "msk" ? [9098] : [5671, 61617]
  alb_ingress_cidrs = var.alb_ingress_cidrs

  tags = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix             = local.name_prefix
  db_password             = random_password.db.result
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_in_days

  parameters = {
    "db/jdbc-url"         = module.data.jdbc_url
    "db/host"             = module.data.cluster_endpoint
    "db/reader-host"      = module.data.cluster_reader_endpoint
    "db/port"             = tostring(module.data.cluster_port)
    "db/tenants-database" = module.data.tenants_database_name
    "db/username"         = module.data.db_username
    "db/tenant-username"  = var.tenant_db_username
    "content/s3-bucket"   = module.data.content_bucket_name
    "content/s3-region"   = var.region
    "broker/type"         = var.broker_type
    "broker/bootstrap"    = coalesce(module.data.msk_bootstrap_brokers, "n/a")
  }

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix                = local.name_prefix
  data_subnet_ids            = module.network.data_subnet_ids
  availability_zones         = var.availability_zones
  database_security_group_id = module.security.database_security_group_id
  broker_security_group_id   = module.security.broker_security_group_id
  kms_key_id                 = var.kms_key_arn

  create_database              = var.create_database
  external_database_host       = var.external_database_host
  db_username                  = var.db_username
  db_password                  = random_password.db.result
  db_engine_version            = var.db_engine_version
  db_parameter_group_family    = var.db_parameter_group_family
  db_instance_class            = var.db_instance_class
  db_instance_count            = var.db_instance_count
  tenants_database_name        = var.tenants_database_name
  deletion_protection          = var.db_deletion_protection
  skip_final_snapshot          = var.db_skip_final_snapshot
  performance_insights_enabled = var.db_performance_insights_enabled

  content_bucket_name          = local.content_bucket_name
  content_bucket_force_destroy = var.content_bucket_force_destroy

  broker_type       = var.broker_type
  msk_kafka_version = var.msk_kafka_version
  msk_broker_count  = var.msk_broker_count
  msk_instance_type = var.msk_instance_type

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Instance modes
# ---------------------------------------------------------------------------

locals {
  msk_extra_properties = join("|", [
    "security.protocol=SASL_SSL",
    "sasl.mechanism=AWS_MSK_IAM",
    "sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;",
    "sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler",
  ])

  # Remote partitioning between the batch manager and the workers travels over
  # MSK; IAM auth is pure client configuration, no credentials involved.
  broker_environment = var.broker_type == "msk" ? {
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_SPRING_EVENTS_ENABLED           = "false"
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_JMS_ENABLED                     = "false"
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_ENABLED                   = "true"
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_BOOTSTRAP_SERVERS         = module.data.msk_bootstrap_brokers
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_ADMIN_EXTRA_PROPERTIES    = local.msk_extra_properties
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_PRODUCER_EXTRA_PROPERTIES = local.msk_extra_properties
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_CONSUMER_EXTRA_PROPERTIES = local.msk_extra_properties
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_TOPIC_NAME                = var.job_topic_name
    FINERACT_REMOTE_JOB_MESSAGE_HANDLER_KAFKA_TOPIC_REPLICAS            = tostring(min(var.msk_broker_count, 3))
  } : {}

  common_environment = merge(
    {
      FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME = "org.postgresql.Driver"
      FINERACT_HIKARI_JDBC_URL                 = module.data.jdbc_url
      FINERACT_HIKARI_USERNAME                 = module.data.db_username
      FINERACT_DEFAULT_TENANTDB_HOSTNAME       = module.data.cluster_endpoint
      FINERACT_DEFAULT_TENANTDB_PORT           = tostring(module.data.cluster_port)
      FINERACT_DEFAULT_TENANTDB_UID            = var.tenant_db_username
      FINERACT_DEFAULT_TENANTDB_IDENTIFIER     = var.default_tenant_identifier
      FINERACT_DEFAULT_TENANTDB_NAME           = var.default_tenant_database_name

      # TLS terminates at the ALB; see the README for the end-to-end variant.
      FINERACT_SERVER_SSL_ENABLED = tostring(var.app_tls_enabled)
      FINERACT_SERVER_PORT        = tostring(var.app_port)

      # Content store: no static keys, so the SDK falls back to the task role.
      FINERACT_CONTENT_FILESYSTEM_ENABLED = "false"
      FINERACT_CONTENT_S3_ENABLED         = "true"
      FINERACT_CONTENT_S3_BUCKET_NAME     = module.data.content_bucket_name
      FINERACT_CONTENT_S3_REGION          = var.region
      FINERACT_CONTENT_S3_ACCESS_KEY      = ""
      FINERACT_CONTENT_S3_SECRET_KEY      = ""

      FINERACT_MANAGEMENT_ENDPOINT_WEB_EXPOSURE_INCLUDE = "health,info,prometheus"
      FINERACT_MANAGEMENT_METRICS_TAGS_APPLICATION      = var.project
    },
    # The read-only tenant connection is stored in the tenants table when the
    # write service seeds the tenant, so every mode is given the same values.
    local.read_enabled ? {
      FINERACT_DEFAULT_TENANTDB_RO_HOSTNAME = module.data.cluster_reader_endpoint
      FINERACT_DEFAULT_TENANTDB_RO_PORT     = tostring(module.data.cluster_port)
      FINERACT_DEFAULT_TENANTDB_RO_UID      = var.tenant_db_username
      FINERACT_DEFAULT_TENANTDB_RO_NAME     = var.default_tenant_database_name
    } : {},
    local.broker_environment,
    var.extra_environment,
  )

  # Instance modes and their sizing. Only the write service runs Liquibase;
  # every other mode boots against an already migrated schema. Kept free of
  # references to the other modules so that the IAM roles can be planned
  # without dragging the load balancer in.
  service_modes = merge(
    {
      write = {
        read_enabled          = true
        write_enabled         = true
        batch_manager_enabled = false
        batch_worker_enabled  = false
        liquibase_enabled     = true
        node_id               = 1
        desired_count         = var.write_min_capacity
        cpu                   = var.write_cpu
        memory                = var.write_memory
        autoscaling = {
          min_capacity = var.write_min_capacity
          max_capacity = var.write_max_capacity
          cpu_target   = var.autoscaling_cpu_target
        }
      }
      "batch-manager" = {
        read_enabled          = false
        write_enabled         = false
        batch_manager_enabled = true
        batch_worker_enabled  = false
        liquibase_enabled     = false
        node_id               = 2
        desired_count         = 1
        cpu                   = var.batch_manager_cpu
        memory                = var.batch_manager_memory
        singleton             = true
        autoscaling           = null
        extra_environment = {
          LOAN_COB_CHUNK_SIZE     = tostring(var.loan_cob_chunk_size)
          LOAN_COB_PARTITION_SIZE = tostring(var.loan_cob_partition_size)
        }
      }
      "batch-worker" = {
        read_enabled          = false
        write_enabled         = false
        batch_manager_enabled = false
        batch_worker_enabled  = true
        liquibase_enabled     = false
        node_id               = 3
        desired_count         = var.worker_min_capacity
        cpu                   = var.worker_cpu
        memory                = var.worker_memory
        autoscaling = {
          min_capacity = var.worker_min_capacity
          max_capacity = var.worker_max_capacity
          cpu_target   = var.autoscaling_cpu_target
        }
      }
    },
    local.read_enabled ? {
      read = {
        read_enabled          = true
        write_enabled         = false
        batch_manager_enabled = false
        batch_worker_enabled  = false
        liquibase_enabled     = false
        node_id               = 4
        desired_count         = var.read_min_capacity
        cpu                   = var.read_cpu
        memory                = var.read_memory
        autoscaling = {
          min_capacity = var.read_min_capacity
          max_capacity = var.read_max_capacity
          cpu_target   = var.autoscaling_cpu_target
        }
      }
    } : {},
  )

  # Only these modes sit behind the load balancer; the batch modes serve no
  # external traffic.
  routed_modes = concat(["write"], local.read_enabled ? ["read"] : [])

  services = {
    for name, svc in local.service_modes : name => merge(svc, {
      target_group_arn = contains(local.routed_modes, name) ? module.alb.target_group_arns[name] : null
    })
  }

  # Only the modes that actually talk to the broker or mutate documents get
  # those permissions; the read mode gets neither.
  iam_services = {
    for name, svc in local.service_modes : name => {
      content_write = svc.write_enabled || svc.batch_worker_enabled
      broker_access = svc.batch_manager_enabled || svc.batch_worker_enabled
    }
  }
}

module "iam" {
  source = "../../modules/iam"

  name_prefix        = local.name_prefix
  services           = local.iam_services
  content_bucket_arn = module.data.content_bucket_arn
  msk_cluster_arn    = module.data.msk_cluster_arn
  mq_broker_arn      = module.data.mq_broker_arn
  kms_key_arn        = var.kms_key_arn

  secret_arns    = values(module.secrets.secret_arns)
  parameter_arns = values(module.secrets.parameter_arns)

  cloudwatch_metrics_enabled = var.cloudwatch_metrics_enabled
  enable_execute_command     = var.enable_execute_command

  tags = local.tags
}

module "alb" {
  source = "../../modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  security_group_id = module.security.alb_security_group_id
  certificate_arn   = var.certificate_arn
  app_port          = var.app_port
  target_protocol   = var.app_tls_enabled ? "HTTPS" : "HTTP"

  target_groups        = { for name in local.routed_modes : name => {} }
  default_target_group = "write"

  # Idempotent reads are cheap to serve from the read replica backed mode.
  listener_rules = local.read_enabled ? {
    read = {
      priority     = 100
      target_group = "read"
      http_methods = ["GET"]
    }
  } : {}

  tags = local.tags
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix           = local.name_prefix
  region                = var.region
  image                 = var.image
  app_subnet_ids        = module.network.app_subnet_ids
  app_security_group_id = module.security.app_security_group_id
  app_port              = var.app_port
  execution_role_arn    = module.iam.execution_role_arn
  task_role_arns        = module.iam.task_role_arns

  services           = local.services
  common_environment = local.common_environment

  secret_environment = {
    FINERACT_HIKARI_PASSWORD                  = module.secrets.secret_arns["db_password"]
    FINERACT_DEFAULT_TENANTDB_PWD             = module.secrets.secret_arns["tenant_db_password"]
    FINERACT_DEFAULT_TENANTDB_RO_PWD          = module.secrets.secret_arns["tenant_db_password"]
    FINERACT_DEFAULT_MASTER_PASSWORD          = module.secrets.secret_arns["master_password"]
    FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD = module.secrets.secret_arns["master_password"]
    FINERACT_SERVER_SSL_KEY_STORE_PASSWORD    = module.secrets.secret_arns["keystore_password"]
  }

  log_retention_in_days  = var.log_retention_in_days
  kms_key_arn            = var.kms_key_arn
  enable_execute_command = var.enable_execute_command
  ecr_repository_name    = var.ecr_repository_name
  create_ecr_repository  = var.create_ecr_repository
  ecr_force_delete       = var.ecr_force_delete

  tags = local.tags
}
