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
# Variable values used only for the LocalStack validation run. `validate.sh`
# copies this file into environments/dev alongside providers_override.tf.

project     = "fineract"
environment = "ls"
region      = "us-east-1"

availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
app_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
data_subnet_cidrs   = ["10.20.20.0/24", "10.20.21.0/24", "10.20.22.0/24"]

# The image is never pulled: LocalStack records the ECS task definition but does
# not run Fargate tasks.
image = "000000000000.dkr.ecr.us-east-1.amazonaws.com/fineract:localstack"

# Overwritten by validate.sh with the ARN of a certificate it requests from the
# LocalStack ACM emulation.
certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000"

enable_read_service = true

# RDS and MSK are not part of the LocalStack community/freemium licence, so the
# apply run below covers the VPC, the content bucket, the secrets, the SSM
# parameters and the IAM roles, and treats the database as externally managed.
# Drop these two overrides on a licence that includes rds and kafka.
create_database        = false
external_database_host = "fineract-db.localstack.test"
broker_type            = "none"

db_instance_class = "db.t4g.medium"
db_instance_count = 2
msk_instance_type = "kafka.t3.small"

# Nothing here is worth protecting; keep re-runs cheap.
db_deletion_protection          = false
db_skip_final_snapshot          = true
content_bucket_force_destroy    = true
ecr_force_delete                = true
secret_recovery_window_in_days  = 0
db_performance_insights_enabled = false
enable_interface_endpoints      = false
