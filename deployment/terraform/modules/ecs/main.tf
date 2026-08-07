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

# All four Fineract instance modes run the same image and the same task
# definition family. They differ only in the FINERACT_MODE_* / FINERACT_LIQUIBASE_ENABLED
# environment variables, the task role, and their scaling profile.

resource "aws_ecr_repository" "this" {
  count = var.create_ecr_repository ? 1 : 0

  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, { Name = var.ecr_repository_name })
}

resource "aws_ecr_lifecycle_policy" "this" {
  count = var.create_ecr_repository ? 1 : 0

  repository = aws_ecr_repository.this[0].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the most recent ${var.ecr_image_retention_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_image_retention_count
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.container_insights_enabled ? "enabled" : "disabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster" })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

locals {
  # Secrets are resolved by the ECS agent at task start and injected as
  # environment variables; the literal values never touch Terraform state
  # outside of the secrets module, nor any committed file.
  common_secrets = [
    for name, arn in var.secret_environment : {
      name      = name
      valueFrom = arn
    }
  ]

  service_environment = {
    for name, svc in var.services : name => merge(
      var.common_environment,
      {
        FINERACT_MODE_READ_ENABLED          = tostring(svc.read_enabled)
        FINERACT_MODE_WRITE_ENABLED         = tostring(svc.write_enabled)
        FINERACT_MODE_BATCH_MANAGER_ENABLED = tostring(svc.batch_manager_enabled)
        FINERACT_MODE_BATCH_WORKER_ENABLED  = tostring(svc.batch_worker_enabled)
        FINERACT_LIQUIBASE_ENABLED          = tostring(svc.liquibase_enabled)
        FINERACT_NODE_ID                    = tostring(svc.node_id)
        OTEL_SERVICE_NAME                   = "${var.name_prefix}-${name}"
      },
      svc.extra_environment,
    )
  }
}

resource "aws_ecs_task_definition" "this" {
  for_each = var.services

  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arns[each.key]

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "fineract"
      image     = var.image
      essential = true

      portMappings = [{
        name          = "fineract"
        containerPort = var.app_port
        protocol      = "tcp"
      }]

      environment = [
        for k, v in local.service_environment[each.key] : { name = k, value = v }
      ]

      secrets = local.common_secrets

      # Liquibase runs only on the write service, so its first boot can take a
      # while; the start period keeps ECS from killing it mid-migration.
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O - http://localhost:${var.app_port}${var.health_check_path} | grep -q UP || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 5
        startPeriod = each.value.liquibase_enabled ? 600 : 180
      }

      stopTimeout = var.stop_timeout

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this[each.key].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = each.key
        }
      }
    }
  ])

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_ecs_service" "this" {
  for_each = var.services

  name            = "${var.name_prefix}-${each.key}"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this[each.key].arn
  launch_type     = "FARGATE"
  desired_count   = each.value.desired_count

  # The batch manager must never run as two tasks: pinning both percentages
  # forces ECS to stop the old task before starting the replacement.
  deployment_minimum_healthy_percent = each.value.singleton ? 0 : 100
  deployment_maximum_percent         = each.value.singleton ? 100 : 200

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  health_check_grace_period_seconds = each.value.target_group_arn == null ? null : each.value.health_check_grace_period

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.value.target_group_arn == null ? [] : [each.value.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = "fineract"
      container_port   = var.app_port
    }
  }

  lifecycle {
    # Autoscaling owns desired_count once the service exists.
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

# ---------------------------------------------------------------------------
# Autoscaling. The batch manager is deliberately excluded: it is a singleton.
# ---------------------------------------------------------------------------

locals {
  autoscaled_services = { for k, v in var.services : k => v if v.autoscaling != null }
}

resource "aws_appautoscaling_target" "this" {
  for_each = local.autoscaled_services

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = each.value.autoscaling.min_capacity
  max_capacity       = each.value.autoscaling.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = local.autoscaled_services

  name               = "${var.name_prefix}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = each.value.autoscaling.cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
