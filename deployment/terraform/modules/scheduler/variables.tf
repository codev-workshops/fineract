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

variable "vpc_id" {
  description = "VPC the Lambda security group is created in."
  type        = string
}

variable "subnet_ids" {
  description = "Private application subnets the Lambda's ENIs attach to, so it can reach the batch-manager on private networking."
  type        = list(string)
}

variable "batch_manager_security_group_id" {
  description = "Security group of the batch-manager ECS tasks (the app security group). An ingress rule is added allowing the Lambda to reach it on app_port."
  type        = string
}

variable "app_port" {
  description = "Port the Fineract batch-manager listens on (and, if fronted by an internal ALB, the ALB target port)."
  type        = number
  default     = 8443
}

variable "lambda_source_file" {
  description = "Path to the scheduler-invoker handler.py that is zipped into the deployment package."
  type        = string
}

variable "lambda_runtime" {
  description = "Lambda Python runtime."
  type        = string
  default     = "python3.12"
}

variable "lambda_timeout_seconds" {
  description = "Lambda execution timeout."
  type        = number
  default     = 60
}

variable "http_timeout_seconds" {
  description = "Per-request timeout the handler applies to the executeJob call."
  type        = number
  default     = 30
}

variable "log_level" {
  description = "Handler log level."
  type        = string
  default     = "INFO"
}

variable "log_retention_in_days" {
  description = "Retention of the Lambda log group."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the log group, DLQ and API secret. Null uses AWS-managed encryption."
  type        = string
  default     = null
}

# --- Fineract API credentials (Secrets Manager) --------------------------------

variable "create_api_secret" {
  description = "Whether this module creates the Secrets Manager secret holding the Fineract base URL and API credentials. Set false to reuse an existing secret."
  type        = bool
  default     = true
}

variable "existing_api_secret_arn" {
  description = "ARN of a pre-existing API-credentials secret to use when create_api_secret is false."
  type        = string
  default     = null
}

variable "fineract_base_url" {
  description = <<-EOT
    Base URL the Lambda calls, up to and including Fineract's servlet context path
    and JAX-RS application path (for example http://internal-alb/fineract-provider/api).
    The handler appends /v1/jobs/{jobId}?command=executeJob. Not a secret; stored in
    the secret alongside the credentials only so the handler reads one object.
  EOT
  type        = string
}

variable "fineract_api_username" {
  description = "Username the Lambda authenticates with. Not a secret on its own."
  type        = string
  default     = "mifos"
}

variable "fineract_api_verify_tls" {
  description = "Whether the handler verifies TLS on the executeJob call. False suits a private HTTP ALB or a self-signed internal certificate."
  type        = bool
  default     = false
}

variable "api_secret_recovery_window_in_days" {
  description = "Secrets Manager recovery window for the API secret; 0 deletes immediately (used by the moto run)."
  type        = number
  default     = 7
}

# --- Schedules -----------------------------------------------------------------

variable "schedules" {
  description = <<-EOT
    EventBridge Scheduler schedules to create, keyed by a short name. Each fires the
    Lambda with a static input carrying the jobId and tenant list. Generate the
    schedule_expression/timezone with deployment/cron/quartz_to_eventbridge.py.
  EOT
  type = map(object({
    schedule_expression = string
    timezone            = optional(string, "UTC")
    job_id              = number
    tenant_ids          = list(string)
    enabled             = optional(bool, true)
    description         = optional(string)
  }))
  default = {}
}

variable "schedule_group_name" {
  description = "EventBridge Scheduler schedule group the schedules belong to."
  type        = string
  default     = "default"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
