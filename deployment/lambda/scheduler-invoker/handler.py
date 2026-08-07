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
"""Thin EventBridge Scheduler -> Lambda invoker for Fineract batch jobs.

This function does **no** job logic. It translates an EventBridge Scheduler
firing into a call to Fineract's existing

    POST {base_url}/v1/jobs/{jobId}?command=executeJob

with the ``Fineract-Platform-TenantId`` header set, one call per tenant, and
expects HTTP 202. All Spring Batch state, COB remote partitioning and
``job_run_history`` recording stay inside the Fineract batch-manager.

Event payload (delivered as the EventBridge target static input)::

    {
      "jobId": 5,                      # required; Fineract job id (int)
      "tenantIds": ["default"],        # required; or "tenantId": "default"
      "secretId": "arn:aws:secrets..." # optional; overrides FINERACT_API_SECRET_ID
    }

Secrets Manager secret (JSON string)::

    {
      "base_url": "http://internal-alb/fineract-provider/api",
      "username": "mifos",
      "password": "...",
      "verify_tls": false              # optional, default true
    }

The base URL must include Fineract's servlet context path and JAX-RS
application path (``/fineract-provider/api``); the handler appends
``/v1/jobs/{jobId}?command=executeJob``.

Failure handling: any tenant that does not return 202 makes the whole
invocation raise, so - with the EventBridge retry policy set to 0 attempts -
the event lands on the DLQ instead of being retried and double-firing a job.
405 (Method Not Allowed) means the target is not a batch manager and is treated
as a failure.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import ssl
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

DEFAULT_TIMEOUT_SECONDS = 30
EXECUTE_JOB_PATH = "/v1/jobs/{job_id}?command=executeJob"


class InvocationError(RuntimeError):
    """Raised when one or more tenant invocations did not return HTTP 202."""


def _secrets_client():
    import boto3

    return boto3.client("secretsmanager")


def _load_credentials(secret_id: str, client=None) -> dict:
    client = client or _secrets_client()
    resp = client.get_secret_value(SecretId=secret_id)
    raw = resp.get("SecretString")
    if raw is None:
        raw = base64.b64decode(resp["SecretBinary"]).decode("utf-8")
    secret = json.loads(raw)
    if "base_url" not in secret:
        raise InvocationError("secret is missing required key 'base_url'")
    return secret


def _basic_auth_header(username: str, password: str) -> str:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def _execute_job(base_url: str, job_id, tenant_id: str, *, username=None, password=None,
                 verify_tls: bool = True, timeout: int = DEFAULT_TIMEOUT_SECONDS) -> int:
    """POST executeJob for one tenant. Returns the HTTP status code."""
    url = base_url.rstrip("/") + EXECUTE_JOB_PATH.format(job_id=job_id)
    request = urllib.request.Request(url, data=b"", method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json")
    request.add_header("Fineract-Platform-TenantId", tenant_id)
    if username is not None:
        request.add_header("Authorization", _basic_auth_header(username, password or ""))

    context = None
    if url.lower().startswith("https") and not verify_tls:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as resp:
            return resp.getcode()
    except urllib.error.HTTPError as exc:
        # Fineract returns 202 on success; any HTTPError is a non-2xx status.
        return exc.code


def _resolve_tenants(event: dict):
    tenants = event.get("tenantIds")
    if tenants is None and event.get("tenantId") is not None:
        tenants = [event["tenantId"]]
    if not tenants:
        raise InvocationError("event must provide a non-empty 'tenantIds' list or 'tenantId'")
    if isinstance(tenants, str):
        tenants = [tenants]
    return list(tenants)


def handler(event, context=None, *, secrets_client=None):
    event = event or {}
    job_id = event.get("jobId")
    if job_id is None:
        raise InvocationError("event must provide 'jobId'")

    tenants = _resolve_tenants(event)

    secret_id = event.get("secretId") or os.environ.get("FINERACT_API_SECRET_ID")
    if not secret_id:
        raise InvocationError("no secret id: set event.secretId or FINERACT_API_SECRET_ID")

    timeout = int(os.environ.get("FINERACT_HTTP_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS))

    creds = _load_credentials(secret_id, client=secrets_client)
    base_url = creds["base_url"]
    verify_tls = bool(creds.get("verify_tls", True))

    results = []
    failures = []
    for tenant_id in tenants:
        status = _execute_job(
            base_url, job_id, tenant_id,
            username=creds.get("username"), password=creds.get("password"),
            verify_tls=verify_tls, timeout=timeout)
        accepted = status == 202
        detail = {"tenantId": tenant_id, "status": status, "accepted": accepted}
        if status == 405:
            detail["message"] = "405 Method Not Allowed - target is not a batch manager"
        results.append(detail)
        if accepted:
            logger.info("executeJob accepted: jobId=%s tenant=%s status=%s", job_id, tenant_id, status)
        else:
            logger.error("executeJob failed: jobId=%s tenant=%s status=%s", job_id, tenant_id, status)
            failures.append(detail)

    summary = {"jobId": job_id, "results": results, "failed": len(failures)}
    if failures:
        # Raise so EventBridge (maxRetryAttempts=0) routes the event to the DLQ.
        raise InvocationError(json.dumps(summary))
    return summary
