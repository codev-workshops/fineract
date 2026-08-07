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
"""Unit tests for the scheduler-invoker Lambda.

The Fineract endpoint is a local ``http.server`` stub returning 202 / 405 / 500,
recording every request it receives. Secrets Manager is mocked with moto.
"""
import base64
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import handler as invoker  # noqa: E402

REGION = "us-east-1"


class _StubState:
    def __init__(self):
        self.status_by_path = {}
        self.default_status = 202
        self.requests = []


class _StubHandler(BaseHTTPRequestHandler):
    state = None  # set per-server

    def do_POST(self):  # noqa: N802
        path = self.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        self.server.state.requests.append({
            "path": path,
            "method": "POST",
            "tenant": self.headers.get("Fineract-Platform-TenantId"),
            "authorization": self.headers.get("Authorization"),
            "content_type": self.headers.get("Content-Type"),
            "body": body,
        })
        status = self.server.state.status_by_path.get(path, self.server.state.default_status)
        self.send_response(status)
        self.end_headers()

    def log_message(self, *args):  # silence test server logging
        pass


@pytest.fixture
def stub_server():
    state = _StubState()
    server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = state
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    base_url = f"http://{host}:{port}/fineract-provider/api"
    try:
        yield base_url, state
    finally:
        server.shutdown()
        server.server_close()


@pytest.fixture(autouse=True)
def _aws_env(monkeypatch):
    # This environment points boto3 at a moto/localstack server via AWS_ENDPOINT_URL;
    # clear it so the in-process mock_aws intercepts calls, and use dummy creds.
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    monkeypatch.delenv("AWS_ENDPOINT_URL_SECRETSMANAGER", raising=False)
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")


@pytest.fixture
def secret(stub_server, _aws_env):
    base_url, state = stub_server
    with mock_aws():
        client = boto3.client("secretsmanager", region_name=REGION)
        secret_value = {
            "base_url": base_url,
            "username": "mifos",
            "password": "password",
            "verify_tls": False,
        }
        arn = client.create_secret(
            Name="fineract/scheduler-invoker",
            SecretString=json.dumps(secret_value),
        )["ARN"]
        yield arn, client, base_url, state


def test_single_tenant_success(secret):
    arn, client, base_url, state = secret
    result = invoker.handler({"jobId": 5, "tenantIds": ["default"], "secretId": arn},
                             secrets_client=client)

    assert result["failed"] == 0
    assert result["results"][0]["accepted"] is True
    assert len(state.requests) == 1
    req = state.requests[0]
    assert req["path"] == "/fineract-provider/api/v1/jobs/5?command=executeJob"
    assert req["method"] == "POST"
    assert req["tenant"] == "default"
    # Basic auth header carries the credentials from Secrets Manager.
    expected = "Basic " + base64.b64encode(b"mifos:password").decode()
    assert req["authorization"] == expected


def test_one_call_per_tenant(secret):
    arn, client, base_url, state = secret
    result = invoker.handler({"jobId": 7, "tenantIds": ["default", "tenantB", "tenantC"], "secretId": arn},
                             secrets_client=client)

    assert result["failed"] == 0
    assert len(state.requests) == 3
    tenants = [r["tenant"] for r in state.requests]
    assert tenants == ["default", "tenantB", "tenantC"]
    for r in state.requests:
        assert r["path"] == "/fineract-provider/api/v1/jobs/7?command=executeJob"


def test_non_202_raises_for_dlq(secret):
    arn, client, base_url, state = secret
    state.default_status = 500
    with pytest.raises(invoker.InvocationError):
        invoker.handler({"jobId": 5, "tenantIds": ["default"], "secretId": arn},
                        secrets_client=client)


def test_405_treated_as_failure(secret):
    arn, client, base_url, state = secret
    state.default_status = 405
    with pytest.raises(invoker.InvocationError) as excinfo:
        invoker.handler({"jobId": 5, "tenantIds": ["default"], "secretId": arn},
                        secrets_client=client)
    summary = json.loads(str(excinfo.value))
    assert summary["results"][0]["status"] == 405
    assert "not a batch manager" in summary["results"][0]["message"]


def test_all_tenants_attempted_even_when_failing(secret):
    arn, client, base_url, state = secret
    # Every call to job 9 fails; all three tenants should still be attempted
    # (one call per tenant) before the invocation raises for the DLQ.
    state.status_by_path["/fineract-provider/api/v1/jobs/9?command=executeJob"] = 500
    with pytest.raises(invoker.InvocationError):
        invoker.handler({"jobId": 9, "tenantIds": ["a", "b", "c"], "secretId": arn},
                        secrets_client=client)
    assert len(state.requests) == 3


def test_tenant_id_singular(secret):
    arn, client, base_url, state = secret
    result = invoker.handler({"jobId": 5, "tenantId": "default", "secretId": arn},
                             secrets_client=client)
    assert result["failed"] == 0
    assert len(state.requests) == 1


def test_missing_job_id_raises(secret):
    arn, client, base_url, state = secret
    with pytest.raises(invoker.InvocationError):
        invoker.handler({"tenantIds": ["default"], "secretId": arn}, secrets_client=client)


def test_missing_tenants_raises(secret):
    arn, client, base_url, state = secret
    with pytest.raises(invoker.InvocationError):
        invoker.handler({"jobId": 5, "secretId": arn}, secrets_client=client)


def test_secret_id_from_env(secret, monkeypatch):
    arn, client, base_url, state = secret
    monkeypatch.setenv("FINERACT_API_SECRET_ID", arn)
    result = invoker.handler({"jobId": 5, "tenantIds": ["default"]}, secrets_client=client)
    assert result["failed"] == 0
    assert len(state.requests) == 1
