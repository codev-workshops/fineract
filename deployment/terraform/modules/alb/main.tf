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

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = var.internal
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  idle_timeout               = var.idle_timeout
  drop_invalid_header_fields = true
  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# One target group per routed instance mode. Fineract serves /actuator/health
# with liveness and readiness probes enabled, so it doubles as the ALB check.
resource "aws_lb_target_group" "this" {
  for_each = var.target_groups

  name        = "${var.name_prefix}-${each.key}"
  port        = var.app_port
  protocol    = var.target_protocol
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Long enough for in-flight requests to finish under the app's graceful
  # shutdown window (spring.lifecycle.timeout-per-shutdown-phase).
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    protocol            = var.target_protocol
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[var.default_target_group].arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = var.enable_http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Optional path/method based split, typically sending read-only traffic (GET)
# to the read instance mode.
resource "aws_lb_listener_rule" "this" {
  for_each = var.listener_rules

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.value.target_group].arn
  }

  dynamic "condition" {
    for_each = length(each.value.path_patterns) > 0 ? [1] : []

    content {
      path_pattern {
        values = each.value.path_patterns
      }
    }
  }

  dynamic "condition" {
    for_each = length(each.value.http_methods) > 0 ? [1] : []

    content {
      http_request_method {
        values = each.value.http_methods
      }
    }
  }
}
