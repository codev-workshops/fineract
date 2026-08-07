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

variable "name_prefix" {
  description = "Prefix applied to the name of every resource created by this module."
  type        = string
}

variable "region" {
  description = "AWS region, used by the awslogs log driver."
  type        = string
}

variable "image" {
  description = "Fully qualified container image, for example <account>.dkr.ecr.<region>.amazonaws.com/fineract:<tag>."
  type        = string
}

variable "app_subnet_ids" {
  description = "Private application subnets the tasks run in."
  type        = list(string)
}

variable "app_security_group_id" {
  description = "Security group attached to the tasks."
  type        = string
}

variable "execution_role_arn" {
  description = "ECS task execution role, shared by every service."
  type        = string
}

variable "task_role_arns" {
  description = "Task role ARN of each instance mode, keyed like `services`."
  type        = map(string)
}

variable "services" {
  description = <<-EOT
    One entry per Fineract instance mode. `singleton` marks a service that must
    never run two tasks at once (the batch manager); such a service must keep
    `autoscaling` null and `desired_count` at 1.
  EOT
  type = map(object({
    read_enabled              = bool
    write_enabled             = bool
    batch_manager_enabled     = bool
    batch_worker_enabled      = bool
    liquibase_enabled         = bool
    node_id                   = number
    desired_count             = number
    cpu                       = string
    memory                    = string
    singleton                 = optional(bool, false)
    target_group_arn          = optional(string)
    extra_environment         = optional(map(string), {})
    health_check_grace_period = optional(number, 600)
    autoscaling = optional(object({
      min_capacity = number
      max_capacity = number
      cpu_target   = number
    }))
  }))

  validation {
    condition = alltrue([
      for k, v in var.services :
      v.desired_count == 1 && v.autoscaling == null if try(v.singleton, false)
    ])
    error_message = "A singleton service (batch manager) must have desired_count = 1 and no autoscaling block."
  }

  validation {
    condition = length([
      for k, v in var.services : k if v.liquibase_enabled
    ]) <= 1
    error_message = "Liquibase must be enabled on exactly one service so that only one instance runs migrations."
  }
}

variable "common_environment" {
  description = "Non-secret environment variables shared by every service."
  type        = map(string)
  default     = {}
}

variable "secret_environment" {
  description = "Environment variable name to Secrets Manager ARN, bound through the task definition `secrets` block."
  type        = map(string)
  default     = {}
}

variable "app_port" {
  description = "Port the Fineract container listens on."
  type        = number
  default     = 8443
}

variable "health_check_path" {
  description = "Container health check path, including the servlet context path."
  type        = string
  default     = "/fineract-provider/actuator/health"
}

variable "cpu_architecture" {
  description = "Fargate CPU architecture: X86_64 or ARM64."
  type        = string
  default     = "X86_64"
}

variable "stop_timeout" {
  description = "Seconds ECS waits for the container to exit before killing it; should exceed the graceful shutdown window."
  type        = number
  default     = 60
}

variable "log_retention_in_days" {
  description = "Retention of the per-service log groups."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the log groups and the ECR repository."
  type        = string
  default     = null
}

variable "container_insights_enabled" {
  description = "Whether Container Insights is enabled on the cluster."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "Whether ECS Exec is enabled on the services."
  type        = bool
  default     = false
}

variable "create_ecr_repository" {
  description = "Whether to create the ECR repository holding the Fineract image."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository."
  type        = string
  default     = "fineract"
}

variable "ecr_force_delete" {
  description = "Allow Terraform to delete a repository that still holds images."
  type        = bool
  default     = false
}

variable "ecr_image_retention_count" {
  description = "Number of images kept by the ECR lifecycle policy."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
