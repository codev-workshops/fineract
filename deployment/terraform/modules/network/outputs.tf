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

output "vpc_id" {
  description = "Identifier of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet identifiers (ALB only)."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Private application subnet identifiers (ECS tasks)."
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "Private data subnet identifiers (RDS, MSK/MQ)."
  value       = aws_subnet.data[*].id
}
