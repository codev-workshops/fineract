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

# ---------------------------------------------------------------------------
# Aurora PostgreSQL. Multi-AZ is expressed as one writer plus at least one
# reader placed in a different AZ; the reader endpoint backs the Fineract
# read instance mode once a read-only datasource is configured.
# ---------------------------------------------------------------------------

locals {
  create_database = var.create_database
}

resource "aws_db_subnet_group" "this" {
  count = local.create_database ? 1 : 0

  name       = "${var.name_prefix}-db"
  subnet_ids = var.data_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })
}

resource "aws_rds_cluster_parameter_group" "this" {
  count = local.create_database ? 1 : 0

  name        = "${var.name_prefix}-aurora-pg"
  family      = var.db_parameter_group_family
  description = "Fineract Aurora PostgreSQL cluster parameters"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = var.tags
}

resource "aws_rds_cluster" "this" {
  count = local.create_database ? 1 : 0

  cluster_identifier = "${var.name_prefix}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = var.db_engine_version
  database_name      = var.tenants_database_name

  master_username = var.db_username
  master_password = var.db_password

  db_subnet_group_name            = aws_db_subnet_group.this[0].name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].name
  vpc_security_group_ids          = [var.database_security_group_id]
  port                            = var.database_port

  storage_encrypted   = true
  kms_key_id          = var.kms_key_id
  deletion_protection = var.deletion_protection

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:03:30-sun:04:30"

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-aurora-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-aurora" })
}

resource "aws_rds_cluster_instance" "this" {
  count = local.create_database ? var.db_instance_count : 0

  identifier          = "${var.name_prefix}-aurora-${count.index}"
  cluster_identifier  = aws_rds_cluster.this[0].id
  instance_class      = var.db_instance_class
  engine              = aws_rds_cluster.this[0].engine
  engine_version      = aws_rds_cluster.this[0].engine_version
  availability_zone   = element(var.availability_zones, count.index)
  publicly_accessible = false

  performance_insights_enabled = var.performance_insights_enabled

  tags = merge(var.tags, { Name = "${var.name_prefix}-aurora-${count.index}" })
}

# ---------------------------------------------------------------------------
# S3 content store. Fineract writes documents here through the ECS task role.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "content" {
  bucket        = var.content_bucket_name
  force_destroy = var.content_bucket_force_destroy

  tags = merge(var.tags, { Name = var.content_bucket_name })
}

resource "aws_s3_bucket_versioning" "content" {
  bucket = aws_s3_bucket.content.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "content" {
  bucket = aws_s3_bucket.content.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_id == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_id
    }
    bucket_key_enabled = var.kms_key_id != null
  }
}

resource "aws_s3_bucket_public_access_block" "content" {
  bucket = aws_s3_bucket.content.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "content" {
  bucket = aws_s3_bucket.content.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ---------------------------------------------------------------------------
# Message broker. MSK with IAM authentication matches the SASL_SSL /
# AWS_MSK_IAM configuration already shipped in config/docker/env/kafka-client-msk.env.
# Amazon MQ (ActiveMQ) is available as an alternative for the JMS handler.
# ---------------------------------------------------------------------------

locals {
  use_msk = var.broker_type == "msk"
  use_mq  = var.broker_type == "activemq"

  database_endpoint        = local.create_database ? aws_rds_cluster.this[0].endpoint : var.external_database_host
  database_reader_endpoint = local.create_database ? aws_rds_cluster.this[0].reader_endpoint : var.external_database_host
}

resource "aws_cloudwatch_log_group" "msk" {
  count = local.use_msk ? 1 : 0

  name              = "/aws/msk/${var.name_prefix}"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

resource "aws_msk_cluster" "this" {
  count = local.use_msk ? 1 : 0

  cluster_name           = "${var.name_prefix}-msk"
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = var.msk_broker_count

  broker_node_group_info {
    instance_type   = var.msk_instance_type
    client_subnets  = slice(var.data_subnet_ids, 0, var.msk_broker_count)
    security_groups = [var.broker_security_group_id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk_volume_size
      }
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
    # IAM auth implies TLS; unauthenticated access stays disabled.
    unauthenticated = false
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_key_id

    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk[0].name
      }
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-msk" })
}

resource "aws_mq_broker" "this" {
  count = local.use_mq ? 1 : 0

  broker_name        = "${var.name_prefix}-mq"
  engine_type        = "ActiveMQ"
  engine_version     = var.mq_engine_version
  host_instance_type = var.mq_instance_type
  deployment_mode    = "ACTIVE_STANDBY_MULTI_AZ"

  subnet_ids          = slice(var.data_subnet_ids, 0, 2)
  security_groups     = [var.broker_security_group_id]
  publicly_accessible = false

  # Amazon MQ requires credentials inline; they come from Secrets Manager via
  # the caller, never from a committed value.
  user {
    username = var.mq_username
    password = var.mq_password
  }

  encryption_options {
    kms_key_id        = var.kms_key_id
    use_aws_owned_key = var.kms_key_id == null
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-mq" })
}
