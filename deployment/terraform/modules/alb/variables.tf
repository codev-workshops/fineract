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

variable "name_prefix" {
  description = "Prefix applied to the name of every resource created by this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the target groups."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets the load balancer is attached to."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group of the load balancer."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate presented by the HTTPS listener."
  type        = string
}

variable "target_groups" {
  description = "Set of routed instance modes; the map keys become target group name suffixes."
  type        = map(object({}))
}

variable "default_target_group" {
  description = "Target group receiving traffic that matches no listener rule."
  type        = string
}

variable "listener_rules" {
  description = "Additional HTTPS listener rules, for example routing GET traffic to the read instance mode."
  type = map(object({
    priority      = number
    target_group  = string
    path_patterns = optional(list(string), [])
    http_methods  = optional(list(string), [])
  }))
  default = {}
}

variable "app_port" {
  description = "Port the Fineract container listens on."
  type        = number
  default     = 8443
}

variable "target_protocol" {
  description = "Protocol between the ALB and the tasks. HTTP when TLS terminates at the ALB, HTTPS for end-to-end TLS."
  type        = string
  default     = "HTTP"
}

variable "health_check_path" {
  description = "Health check path of the target groups, including the servlet context path."
  type        = string
  default     = "/fineract-provider/actuator/health"
}

variable "ssl_policy" {
  description = "TLS policy of the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "internal" {
  description = "Whether the load balancer is internal only."
  type        = bool
  default     = false
}

variable "enable_http_redirect" {
  description = "Whether to add a port 80 listener redirecting to HTTPS."
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Whether the load balancer is protected from deletion."
  type        = bool
  default     = false
}

variable "idle_timeout" {
  description = "Idle timeout of the load balancer, in seconds."
  type        = number
  default     = 120
}

variable "deregistration_delay" {
  description = "Seconds the ALB keeps draining a removed target; should exceed the app's graceful shutdown window."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
