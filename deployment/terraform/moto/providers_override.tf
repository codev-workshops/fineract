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
# Terraform merges any `*_override.tf` file over the definitions of the
# directory it sits in, so copying this file into environments/dev repoints the
# whole stack at moto without touching the real configuration.
# `validate.sh` does exactly that.

terraform {
  # State stays local; validate.sh points it at deployment/terraform/moto/.state.
  backend "local" {}
}

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  default_tags {
    tags = local.tags
  }

  # moto serves every API from one port, S3 included: it does path-style
  # addressing, so there is no virtual-host name to point at.
  endpoints {
    acm                    = "http://localhost:5000"
    applicationautoscaling = "http://localhost:5000"
    cloudwatch             = "http://localhost:5000"
    cloudwatchlogs         = "http://localhost:5000"
    ec2                    = "http://localhost:5000"
    ecr                    = "http://localhost:5000"
    ecs                    = "http://localhost:5000"
    elbv2                  = "http://localhost:5000"
    iam                    = "http://localhost:5000"
    kafka                  = "http://localhost:5000"
    kms                    = "http://localhost:5000"
    lambda                 = "http://localhost:5000"
    mq                     = "http://localhost:5000"
    rds                    = "http://localhost:5000"
    s3                     = "http://localhost:5000"
    scheduler              = "http://localhost:5000"
    secretsmanager         = "http://localhost:5000"
    sqs                    = "http://localhost:5000"
    ssm                    = "http://localhost:5000"
    sts                    = "http://localhost:5000"
  }
}
