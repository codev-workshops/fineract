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
# Variable values used only for the moto validation run. `validate.sh` copies
# this file into environments/dev alongside providers_override.tf.

project     = "fineract"
environment = "moto"
region      = "us-east-1"

availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
app_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
data_subnet_cidrs   = ["10.20.20.0/24", "10.20.21.0/24", "10.20.22.0/24"]

# The image is never pulled: moto records the ECS task definition but does not
# run Fargate tasks.
image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/fineract:moto"

# Overwritten by validate.sh with the ARN of a certificate it requests from the
# moto ACM implementation.
certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

enable_read_service = true

# moto accepts CreateCluster but leaves MSK clusters in CREATING for ever, so
# an apply would block until the provider's timeout. The plan still covers the
# MSK resources; `validate.sh plan` forces broker_type=msk for that reason.
broker_type = "none"

# application-autoscaling:ListTagsForResource is not implemented in moto, and
# the provider retries it after every create. The targets and policies are still
# planned; `validate.sh plan` turns them back on.
enable_autoscaling = false

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
