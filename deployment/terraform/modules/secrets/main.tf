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

# Every secret value is generated here and never committed. Rotating a value by
# hand in the console is fine as long as `ignore_changes` below keeps Terraform
# from overwriting it on the next apply.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  # The database password is created by the caller because the database itself
  # has to be provisioned with it; the rest is generated here.
  generated_definitions = {
    tenant_db_password = {
      name_suffix = "tenant-db-password"
      description = "Password Fineract stores for tenant datasource connections (FINERACT_DEFAULT_TENANTDB_PWD)"
    }
    master_password = {
      name_suffix = "master-password"
      description = "Key used to encrypt tenant database passwords (FINERACT_DEFAULT_MASTER_PASSWORD)"
    }
    keystore_password = {
      name_suffix = "keystore-password"
      description = "Password of the TLS keystore used when end-to-end TLS is enabled (FINERACT_SERVER_SSL_KEY_STORE_PASSWORD)"
    }
  }

  secret_definitions = merge(local.generated_definitions, {
    db_password = {
      name_suffix = "db-password"
      description = "Master password of the Fineract PostgreSQL cluster (FINERACT_HIKARI_PASSWORD)"
    }
  })

  secret_values = merge(
    { for k, v in random_password.this : k => v.result },
    { db_password = var.db_password },
  )
}

resource "random_password" "this" {
  for_each = local.generated_definitions

  length  = 32
  special = true
  # Characters that survive JDBC URLs, shell quoting and Spring property files.
  override_special = "!#$%*-_=+"
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_definitions

  name                    = "${var.name_prefix}/${each.value.name_suffix}"
  description             = each.value.description
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value.name_suffix}" })
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.secret_definitions

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = local.secret_values[each.key]

  lifecycle {
    # Allow out-of-band rotation without Terraform reverting the value.
    ignore_changes = [secret_string]
  }
}

# Non-secret configuration lives in SSM Parameter Store so that operators can
# read it without being granted access to Secrets Manager.
resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name        = "/${var.name_prefix}/${each.key}"
  description = "Fineract deployment configuration: ${each.key}"
  type        = "String"
  value       = each.value
  overwrite   = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.key, "/", "-")}" })
}
