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

output "cluster_endpoint" {
  description = "Writer endpoint of the database."
  value       = local.database_endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint of the database, for the read instance mode."
  value       = local.database_reader_endpoint
}

output "cluster_port" {
  description = "Port the database listens on."
  value       = var.database_port
}

output "tenants_database_name" {
  description = "Name of the Fineract tenants database."
  value       = var.tenants_database_name
}

output "db_username" {
  description = "Master username of the database."
  value       = var.db_username
}

output "jdbc_url" {
  description = "JDBC URL of the tenants database."
  value       = "jdbc:postgresql://${local.database_endpoint}:${var.database_port}/${var.tenants_database_name}"
}

output "read_only_jdbc_url" {
  description = "JDBC URL pointing at the reader endpoint."
  value       = "jdbc:postgresql://${local.database_reader_endpoint}:${var.database_port}/${var.tenants_database_name}"
}

output "content_bucket_name" {
  description = "Name of the S3 content store bucket."
  value       = aws_s3_bucket.content.bucket
}

output "content_bucket_arn" {
  description = "ARN of the S3 content store bucket."
  value       = aws_s3_bucket.content.arn
}

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster, or null when Amazon MQ was selected."
  value       = local.use_msk ? aws_msk_cluster.this[0].arn : null
}

output "msk_bootstrap_brokers" {
  description = "IAM (SASL_SSL) bootstrap broker list of the MSK cluster."
  value       = local.use_msk ? aws_msk_cluster.this[0].bootstrap_brokers_sasl_iam : null
}

output "mq_broker_arn" {
  description = "ARN of the Amazon MQ broker, or null when MSK was selected."
  value       = local.use_mq ? aws_mq_broker.this[0].arn : null
}

output "mq_endpoints" {
  description = "Wire level endpoints of the Amazon MQ broker."
  value       = local.use_mq ? aws_mq_broker.this[0].instances[0].endpoints : null
}
