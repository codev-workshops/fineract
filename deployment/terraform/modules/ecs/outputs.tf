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

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "service_names" {
  description = "Name of the ECS service of each instance mode."
  value       = { for k, v in aws_ecs_service.this : k => v.name }
}

output "task_definition_arns" {
  description = "Task definition ARN of each instance mode."
  value       = { for k, v in aws_ecs_task_definition.this : k => v.arn }
}

output "log_group_names" {
  description = "CloudWatch log group of each instance mode."
  value       = { for k, v in aws_cloudwatch_log_group.this : k => v.name }
}

output "ecr_repository_url" {
  description = "URL of the ECR repository, or null when the repository is managed elsewhere."
  value       = var.create_ecr_repository ? aws_ecr_repository.this[0].repository_url : null
}
