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

variable "data_subnet_ids" {
  description = "Private data subnets hosting the database and the broker."
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones the database instances are spread across."
  type        = list(string)
}

variable "database_security_group_id" {
  description = "Security group attached to the database cluster."
  type        = string
}

variable "broker_security_group_id" {
  description = "Security group attached to the message broker."
  type        = string
}

variable "kms_key_id" {
  description = "Customer managed KMS key used for storage encryption. Defaults to AWS managed keys when null."
  type        = string
  default     = null
}

variable "create_database" {
  description = <<-EOT
    Whether this module provisions the Aurora cluster. Set to false to point the
    stack at a database managed elsewhere, in which case external_database_host
    supplies the endpoint.
  EOT
  type        = bool
  default     = true
}

variable "external_database_host" {
  description = "Host name of an externally managed database. Only used when create_database is false."
  type        = string
  default     = null
}

variable "database_port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "db_username" {
  description = "Master username of the Aurora cluster."
  type        = string
  default     = "fineract"
}

variable "db_password" {
  description = "Master password of the Aurora cluster. Supplied by the secrets module, never hard coded."
  type        = string
  sensitive   = true
}

variable "tenants_database_name" {
  description = "Name of the Fineract tenants database created on the cluster."
  type        = string
  default     = "fineract_tenants"
}

variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "db_parameter_group_family" {
  description = "Cluster parameter group family matching the engine version."
  type        = string
  default     = "aurora-postgresql16"
}

variable "db_instance_class" {
  description = "Instance class of each Aurora instance."
  type        = string
  default     = "db.r6g.large"
}

variable "db_instance_count" {
  description = "Number of Aurora instances. Two or more gives a writer plus a reader in another AZ (Multi-AZ)."
  type        = number
  default     = 2

  validation {
    condition     = var.db_instance_count >= 2
    error_message = "At least two instances are required for a Multi-AZ Aurora cluster."
  }
}

variable "backup_retention_period" {
  description = "Number of days automated backups are retained."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Whether the cluster is protected from deletion."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Only sensible for throwaway environments."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Whether Performance Insights is enabled on the Aurora instances."
  type        = bool
  default     = true
}

variable "content_bucket_name" {
  description = "Name of the S3 bucket backing the Fineract content store."
  type        = string
}

variable "content_bucket_force_destroy" {
  description = "Allow Terraform to delete a non-empty content bucket. Only sensible for throwaway environments."
  type        = bool
  default     = false
}

variable "broker_type" {
  description = "Message broker to provision: msk (Kafka with IAM auth), activemq (Amazon MQ), or none."
  type        = string
  default     = "msk"

  validation {
    condition     = contains(["msk", "activemq", "none"], var.broker_type)
    error_message = "broker_type must be one of \"msk\", \"activemq\" or \"none\"."
  }
}

variable "msk_kafka_version" {
  description = "Kafka version of the MSK cluster."
  type        = string
  default     = "3.6.0"
}

variable "msk_broker_count" {
  description = "Number of MSK broker nodes; must be a multiple of the number of client subnets."
  type        = number
  default     = 3
}

variable "msk_instance_type" {
  description = "Instance type of the MSK brokers."
  type        = string
  default     = "kafka.m5.large"
}

variable "msk_volume_size" {
  description = "EBS volume size per MSK broker, in GiB."
  type        = number
  default     = 100
}

variable "mq_engine_version" {
  description = "Amazon MQ ActiveMQ engine version."
  type        = string
  default     = "5.18"
}

variable "mq_instance_type" {
  description = "Amazon MQ host instance type."
  type        = string
  default     = "mq.m5.large"
}

variable "mq_username" {
  description = "Amazon MQ user name. Only used when broker_type is activemq."
  type        = string
  default     = "fineract"
}

variable "mq_password" {
  description = "Amazon MQ password. Supplied by the secrets module when broker_type is activemq."
  type        = string
  sensitive   = true
  default     = null
}

variable "log_retention_in_days" {
  description = "Retention of the broker log group."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
