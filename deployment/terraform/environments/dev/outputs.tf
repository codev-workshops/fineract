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

output "alb_dns_name" {
  description = "Public DNS name of the Fineract load balancer."
  value       = module.alb.dns_name
}

output "ecr_repository_url" {
  description = "Repository the Fineract image is pushed to."
  value       = module.ecs.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.ecs.cluster_name
}

output "ecs_service_names" {
  description = "ECS service of each instance mode."
  value       = module.ecs.service_names
}

output "log_group_names" {
  description = "CloudWatch log group of each instance mode."
  value       = module.ecs.log_group_names
}

output "database_endpoint" {
  description = "Writer endpoint of the Aurora cluster."
  value       = module.data.cluster_endpoint
}

output "database_reader_endpoint" {
  description = "Reader endpoint of the Aurora cluster."
  value       = module.data.cluster_reader_endpoint
}

output "content_bucket_name" {
  description = "S3 bucket backing the Fineract content store."
  value       = module.data.content_bucket_name
}

output "msk_bootstrap_brokers" {
  description = "IAM bootstrap brokers of the MSK cluster, when MSK is the selected broker."
  value       = module.data.msk_bootstrap_brokers
}

output "secret_arns" {
  description = "Secrets Manager ARNs bound into the task definitions."
  value       = module.secrets.secret_arns
}

output "task_role_arns" {
  description = "Task role of each instance mode."
  value       = module.iam.task_role_arns
}
