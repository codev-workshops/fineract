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

output "lambda_function_arn" {
  description = "ARN of the scheduler-invoker Lambda."
  value       = aws_lambda_function.invoker.arn
}

output "lambda_function_name" {
  description = "Name of the scheduler-invoker Lambda."
  value       = aws_lambda_function.invoker.function_name
}

output "lambda_security_group_id" {
  description = "Security group attached to the Lambda's ENIs."
  value       = aws_security_group.lambda.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue for failed schedule firings."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.id
}

output "api_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Fineract base URL and API credentials."
  value       = local.api_secret_arn
}

output "scheduler_role_arn" {
  description = "IAM role EventBridge Scheduler assumes to invoke the Lambda."
  value       = aws_iam_role.scheduler.arn
}

output "schedule_arns" {
  description = "ARNs of the created EventBridge Scheduler schedules, keyed like var.schedules."
  value       = { for k, s in aws_scheduler_schedule.this : k => s.arn }
}
