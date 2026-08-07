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
# EventBridge Scheduler -> thin Lambda -> Fineract's existing executeJob API.
# This replaces in-app Quartz triggering; no job logic lives here.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  api_secret_arn = var.create_api_secret ? aws_secretsmanager_secret.api[0].arn : var.existing_api_secret_arn
}

# --- Fineract API credentials --------------------------------------------------
# The password is generated, never committed. base_url and username are not
# secret but live in the same object so the handler reads one secret.

resource "random_password" "api" {
  count = var.create_api_secret ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%*-_=+"
}

resource "aws_secretsmanager_secret" "api" {
  count = var.create_api_secret ? 1 : 0

  name                    = "${var.name_prefix}/scheduler-invoker/api"
  description             = "Fineract base URL and API credentials used by the EventBridge scheduler-invoker Lambda"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.api_secret_recovery_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker-api" })
}

resource "aws_secretsmanager_secret_version" "api" {
  count = var.create_api_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.api[0].id
  secret_string = jsonencode({
    base_url   = var.fineract_base_url
    username   = var.fineract_api_username
    password   = random_password.api[0].result
    verify_tls = var.fineract_api_verify_tls
  })

  lifecycle {
    # Operators set the real password out of band; Terraform must not revert it.
    ignore_changes = [secret_string]
  }
}

# --- Networking ----------------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-scheduler-invoker"
  description = "Fineract EventBridge scheduler-invoker Lambda"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker" })
}

# Outbound to reach the batch-manager, plus Secrets Manager / CloudWatch Logs
# (via VPC endpoints or the NAT gateway).
resource "aws_vpc_security_group_egress_rule" "lambda_all" {
  security_group_id = aws_security_group.lambda.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The rule the design calls for: let the Lambda reach the batch-manager (or the
# internal ALB in front of it) on the app port.
resource "aws_vpc_security_group_ingress_rule" "batch_manager_from_lambda" {
  security_group_id            = var.batch_manager_security_group_id
  description                  = "executeJob from the scheduler-invoker Lambda"
  referenced_security_group_id = aws_security_group.lambda.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# --- Lambda --------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_file = var.lambda_source_file
  output_path = "${path.module}/.build/scheduler-invoker.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-scheduler-invoker-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker-lambda" })
}

# Grants the ENI permissions for VPC attachment and CloudWatch Logs writes.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_secret" {
  name = "read-api-secret"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.api_secret_arn
      }],
      var.kms_key_arn == null ? [] : [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      }],
    )
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-scheduler-invoker"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker" })
}

resource "aws_lambda_function" "invoker" {
  function_name = "${var.name_prefix}-scheduler-invoker"
  description   = "Triggers Fineract batch jobs via POST /v1/jobs/{id}?command=executeJob"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  timeout       = var.lambda_timeout_seconds

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      FINERACT_API_SECRET_ID        = local.api_secret_arn
      FINERACT_HTTP_TIMEOUT_SECONDS = tostring(var.http_timeout_seconds)
      LOG_LEVEL                     = var.log_level
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker" })
}

# --- DLQ -----------------------------------------------------------------------
# Retry is disabled (maxRetryAttempts = 0) so a job never double-fires; anything
# that does not return 202 lands here for inspection.

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-scheduler-invoker-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker-dlq" })
}

# --- EventBridge Scheduler -----------------------------------------------------

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-invoker-eb"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-scheduler-invoker-eb" })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-lambda-and-dlq"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.invoker.arn, "${aws_lambda_function.invoker.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "this" {
  for_each = var.schedules

  name                         = "${var.name_prefix}-${each.key}"
  group_name                   = var.schedule_group_name
  description                  = coalesce(each.value.description, "Fineract job ${each.value.job_id}")
  state                        = each.value.enabled ? "ENABLED" : "DISABLED"
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = each.value.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.invoker.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      jobId     = each.value.job_id
      tenantIds = each.value.tenant_ids
    })

    # No retries: rely on Fineract's currently_running / updates_allowed guards
    # and send the single failed event to the DLQ instead of re-firing.
    retry_policy {
      maximum_retry_attempts = 0
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}
