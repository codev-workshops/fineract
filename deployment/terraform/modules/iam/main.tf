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

# Two role families, deliberately kept apart:
#   * execution role  - used by the ECS agent to pull the image, ship logs and
#                       resolve the secrets bound in the task definition.
#   * task role       - assumed by the Fineract JVM itself; this is what the
#                       AWS SDK DefaultCredentialsProvider picks up, so no
#                       static S3 or MSK keys are ever needed.
# Each instance mode gets its own task role so a read-only task cannot publish
# to the broker or mutate the content bucket.

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Task execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_extra" {
  statement {
    sid       = "ReadBoundSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }

  dynamic "statement" {
    for_each = length(var.parameter_arns) > 0 ? [1] : []

    content {
      sid       = "ReadBoundParameters"
      effect    = "Allow"
      actions   = ["ssm:GetParameters", "ssm:GetParameter"]
      resources = var.parameter_arns
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [1]

    content {
      sid       = "DecryptSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "execution_extra" {
  name   = "${var.name_prefix}-ecs-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_extra.json
}

# ---------------------------------------------------------------------------
# Task roles, one per instance mode
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "task" {
  for_each = var.services

  # Read-only tasks still need to serve stored documents.
  statement {
    sid    = "ContentStoreRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [var.content_bucket_arn, "${var.content_bucket_arn}/*"]
  }

  dynamic "statement" {
    for_each = each.value.content_write ? [1] : []

    content {
      sid    = "ContentStoreWrite"
      effect = "Allow"
      actions = [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:AbortMultipartUpload",
      ]
      resources = ["${var.content_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.broker_access && var.msk_cluster_arn != null ? [1] : []

    content {
      sid       = "MskConnect"
      effect    = "Allow"
      actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
      resources = [var.msk_cluster_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.broker_access && var.msk_cluster_arn != null ? [1] : []

    content {
      sid    = "MskTopics"
      effect = "Allow"
      actions = [
        "kafka-cluster:CreateTopic",
        "kafka-cluster:DescribeTopic",
        "kafka-cluster:DescribeTopicDynamicConfiguration",
        "kafka-cluster:AlterTopicDynamicConfiguration",
        "kafka-cluster:ReadData",
        "kafka-cluster:WriteData",
      ]
      resources = [local.msk_topic_arn_wildcard]
    }
  }

  dynamic "statement" {
    for_each = each.value.broker_access && var.msk_cluster_arn != null ? [1] : []

    content {
      sid    = "MskGroups"
      effect = "Allow"
      actions = [
        "kafka-cluster:AlterGroup",
        "kafka-cluster:DescribeGroup",
      ]
      resources = [local.msk_group_arn_wildcard]
    }
  }

  dynamic "statement" {
    for_each = each.value.broker_access && var.mq_broker_arn != null ? [1] : []

    content {
      sid       = "MqDescribe"
      effect    = "Allow"
      actions   = ["mq:DescribeBroker"]
      resources = [var.mq_broker_arn]
    }
  }

  dynamic "statement" {
    for_each = var.cloudwatch_metrics_enabled ? [1] : []

    content {
      sid       = "PublishMetrics"
      effect    = "Allow"
      actions   = ["cloudwatch:PutMetricData"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "cloudwatch:namespace"
        values   = var.cloudwatch_metrics_namespaces
      }
    }
  }

  # ECS Exec, used for troubleshooting a running task without SSH.
  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid    = "EcsExec"
      effect = "Allow"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

locals {
  # MSK topic/group ARNs share the cluster ARN shape with the resource type and
  # the cluster's own uuid suffix swapped in.
  msk_cluster_parts      = var.msk_cluster_arn == null ? [] : split(":", var.msk_cluster_arn)
  msk_cluster_name_part  = var.msk_cluster_arn == null ? "" : element(local.msk_cluster_parts, 5)
  msk_arn_prefix         = var.msk_cluster_arn == null ? "" : join(":", slice(local.msk_cluster_parts, 0, 5))
  msk_cluster_suffix     = var.msk_cluster_arn == null ? "" : trimprefix(local.msk_cluster_name_part, "cluster/")
  msk_topic_arn_wildcard = var.msk_cluster_arn == null ? "" : "${local.msk_arn_prefix}:topic/${local.msk_cluster_suffix}/*"
  msk_group_arn_wildcard = var.msk_cluster_arn == null ? "" : "${local.msk_arn_prefix}:group/${local.msk_cluster_suffix}/*"
}

resource "aws_iam_role" "task" {
  for_each = var.services

  name               = "${var.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-task" })
}

resource "aws_iam_role_policy" "task" {
  for_each = var.services

  name   = "${var.name_prefix}-${each.key}-task"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task[each.key].json
}
