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

output "alb_security_group_id" {
  description = "Security group of the public ALB."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group of the Fineract ECS tasks."
  value       = aws_security_group.app.id
}

output "database_security_group_id" {
  description = "Security group of the PostgreSQL cluster."
  value       = aws_security_group.database.id
}

output "broker_security_group_id" {
  description = "Security group of the message broker."
  value       = aws_security_group.broker.id
}
