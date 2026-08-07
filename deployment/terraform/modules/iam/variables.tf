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
  description = "Prefix applied to the name of every role created by this module."
  type        = string
}

variable "partition" {
  description = "AWS partition, used to build managed policy ARNs."
  type        = string
  default     = "aws"
}

variable "services" {
  description = <<-EOT
    Instance modes that need a task role. `content_write` grants mutating access
    to the content bucket, `broker_access` grants MSK/MQ access. Read-only tasks
    should have both set to false.
  EOT
  type = map(object({
    content_write = bool
    broker_access = bool
  }))
}

variable "content_bucket_arn" {
  description = "ARN of the S3 content store bucket."
  type        = string
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster, or null when Amazon MQ (or no broker) is used."
  type        = string
  default     = null
}

variable "mq_broker_arn" {
  description = "ARN of the Amazon MQ broker, or null when MSK (or no broker) is used."
  type        = string
  default     = null
}

variable "secret_arns" {
  description = "Secrets Manager ARNs the execution role may read."
  type        = list(string)
  default     = []
}

variable "parameter_arns" {
  description = "SSM parameter ARNs the execution role may read."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Customer managed KMS key protecting the secrets, if any."
  type        = string
  default     = null
}

variable "cloudwatch_metrics_enabled" {
  description = "Whether tasks may publish custom CloudWatch metrics."
  type        = bool
  default     = false
}

variable "cloudwatch_metrics_namespaces" {
  description = "Namespaces the tasks may publish metrics into."
  type        = list(string)
  default     = ["fineract"]
}

variable "enable_execute_command" {
  description = "Whether the task roles allow ECS Exec sessions."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
