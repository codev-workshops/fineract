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

variable "project" {
  description = "Project name, used as the first part of every resource name."
  type        = string
  default     = "fineract"
}

variable "environment" {
  description = "Environment name, used as the second part of every resource name."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region everything is deployed into."
  type        = string
  default     = "eu-central-1"
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

# --- networking -------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread the subnets across."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets (ALB only)."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks of the private application subnets (ECS tasks)."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks of the private data subnets (Aurora, MSK/MQ)."
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24", "10.20.22.0/24"]
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints for Secrets Manager, SSM, ECR, Logs and STS."
  type        = bool
  default     = true
}

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the ALB on 443. Narrow this down outside of a sandbox."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- application ------------------------------------------------------------

variable "image" {
  description = "Fully qualified Fineract image, for example <account>.dkr.ecr.<region>.amazonaws.com/fineract:1.13.0."
  type        = string
}

variable "app_port" {
  description = "Port the Fineract container listens on."
  type        = number
  default     = 8443
}

variable "app_tls_enabled" {
  description = <<-EOT
    Whether the container terminates TLS itself. Left false so TLS terminates at
    the ALB; set to true for end-to-end TLS, which also needs a keystore mounted
    from Secrets Manager (see the README).
  EOT
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate presented by the ALB HTTPS listener."
  type        = string
}

variable "extra_environment" {
  description = "Additional non-secret environment variables applied to every service."
  type        = map(string)
  default     = {}
}

variable "enable_read_service" {
  description = "Whether to run the read instance mode. Requires the read-only tenant datasource configuration."
  type        = bool
  default     = false
}

variable "enable_execute_command" {
  description = "Whether ECS Exec is enabled on the services."
  type        = bool
  default     = false
}

variable "cloudwatch_metrics_enabled" {
  description = "Whether tasks may publish custom CloudWatch metrics."
  type        = bool
  default     = false
}

variable "log_retention_in_days" {
  description = "Retention of the per-service CloudWatch log groups."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Customer managed KMS key used across secrets, storage and logs."
  type        = string
  default     = null
}

# --- sizing -----------------------------------------------------------------

variable "write_cpu" {
  description = "Fargate CPU units of the write service."
  type        = string
  default     = "2048"
}

variable "write_memory" {
  description = "Fargate memory (MiB) of the write service."
  type        = string
  default     = "4096"
}

variable "write_min_capacity" {
  description = "Minimum number of write tasks. Two or more keeps the service spread across AZs."
  type        = number
  default     = 2
}

variable "write_max_capacity" {
  description = "Maximum number of write tasks."
  type        = number
  default     = 6
}

variable "read_cpu" {
  description = "Fargate CPU units of the read service."
  type        = string
  default     = "2048"
}

variable "read_memory" {
  description = "Fargate memory (MiB) of the read service."
  type        = string
  default     = "4096"
}

variable "read_min_capacity" {
  description = "Minimum number of read tasks."
  type        = number
  default     = 2
}

variable "read_max_capacity" {
  description = "Maximum number of read tasks."
  type        = number
  default     = 6
}

variable "batch_manager_cpu" {
  description = "Fargate CPU units of the batch manager. It always runs as a single task."
  type        = string
  default     = "1024"
}

variable "batch_manager_memory" {
  description = "Fargate memory (MiB) of the batch manager."
  type        = string
  default     = "2048"
}

variable "worker_cpu" {
  description = "Fargate CPU units of a batch worker."
  type        = string
  default     = "2048"
}

variable "worker_memory" {
  description = "Fargate memory (MiB) of a batch worker."
  type        = string
  default     = "4096"
}

variable "worker_min_capacity" {
  description = "Minimum number of batch worker tasks."
  type        = number
  default     = 2
}

variable "worker_max_capacity" {
  description = "Maximum number of batch worker tasks."
  type        = number
  default     = 10
}

variable "autoscaling_cpu_target" {
  description = "Average CPU utilisation the autoscaling policies aim for."
  type        = number
  default     = 60
}

variable "loan_cob_chunk_size" {
  description = "LOAN_COB_CHUNK_SIZE of the batch manager."
  type        = number
  default     = 100
}

variable "loan_cob_partition_size" {
  description = "LOAN_COB_PARTITION_SIZE of the batch manager."
  type        = number
  default     = 100
}

# --- data stores ------------------------------------------------------------

variable "create_database" {
  description = <<-EOT
    Whether this stack provisions the Aurora cluster. Set to false to reuse a
    database managed elsewhere; external_database_host then supplies the host.
  EOT
  type        = bool
  default     = true
}

variable "external_database_host" {
  description = "Host name of an externally managed database. Only used when create_database is false."
  type        = string
  default     = null
}

variable "db_username" {
  description = "Master username of the Aurora cluster, used for the tenants metadata datasource."
  type        = string
  default     = "fineract"
}

variable "tenant_db_username" {
  description = <<-EOT
    PostgreSQL role Fineract stores in the tenants table for tenant connections.
    Create it once with the tenant-db-password secret (see the README bootstrap
    section); set it to the master username only if you also point the
    tenant-db-password secret at the master password.
  EOT
  type        = string
  default     = "fineract_tenant"
}

variable "tenants_database_name" {
  description = "Name of the Fineract tenants metadata database."
  type        = string
  default     = "fineract_tenants"
}

variable "default_tenant_identifier" {
  description = "Identifier of the tenant seeded on first boot."
  type        = string
  default     = "default"
}

variable "default_tenant_database_name" {
  description = "Database name of the tenant seeded on first boot."
  type        = string
  default     = "fineract_default"
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
  description = "Number of Aurora instances; two or more gives a writer plus a reader in another AZ."
  type        = number
  default     = 2
}

variable "db_deletion_protection" {
  description = "Whether the Aurora cluster is protected from deletion."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Only sensible for throwaway environments."
  type        = bool
  default     = false
}

variable "db_performance_insights_enabled" {
  description = "Whether Performance Insights is enabled on the Aurora instances."
  type        = bool
  default     = true
}

variable "content_bucket_name" {
  description = "Name of the S3 content bucket. Defaults to <project>-<environment>-content."
  type        = string
  default     = null
}

variable "content_bucket_force_destroy" {
  description = "Allow Terraform to delete a non-empty content bucket."
  type        = bool
  default     = false
}

variable "secret_recovery_window_in_days" {
  description = "Secrets Manager recovery window. Use 0 in throwaway environments so names can be reused immediately."
  type        = number
  default     = 7
}

variable "broker_type" {
  description = <<-EOT
    Message broker to provision: msk (Kafka with IAM auth), activemq (Amazon MQ)
    or none. A broker is mandatory here: Fineract refuses to start a batch
    manager that is not also a batch worker unless a remote message handler is
    configured, and this stack runs them as separate services. "none" exists for
    validating the rest of the stack where MSK is unavailable.
  EOT
  type        = string
  default     = "msk"
}

variable "msk_kafka_version" {
  description = "Kafka version of the MSK cluster."
  type        = string
  default     = "3.6.0"
}

variable "msk_broker_count" {
  description = "Number of MSK broker nodes."
  type        = number
  default     = 3
}

variable "msk_instance_type" {
  description = "Instance type of the MSK brokers."
  type        = string
  default     = "kafka.m5.large"
}

variable "job_topic_name" {
  description = "Kafka topic carrying remote partitioning messages between the batch manager and the workers."
  type        = string
  default     = "job-topic"
}

# --- container registry -----------------------------------------------------

variable "create_ecr_repository" {
  description = "Whether this root module owns the ECR repository."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository holding the Fineract image."
  type        = string
  default     = "fineract"
}

variable "ecr_force_delete" {
  description = "Allow Terraform to delete an ECR repository that still holds images."
  type        = bool
  default     = false
}
