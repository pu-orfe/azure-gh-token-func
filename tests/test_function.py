"""Unit tests for the GetGitHubToken Azure Function.

The GitHub API is mocked; RSA keys are generated at runtime so no key
material is ever committed. Run via tests/Dockerfile.python or pytest
from the repo root.
"""
import importlib
import json
import logging

import azure.functions as func
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

APP_ID = "123456"
INSTALLATION_ID = "78901234"


@pytest.fixture(scope="module")
def rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="module")
def private_key_pem(rsa_key):
    """PKCS#1 PEM, the format GitHub Apps actually issue."""
    return rsa_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


@pytest.fixture
def module():
    import GetGitHubToken

    return importlib.reload(GetGitHubToken)


@pytest.fixture
def request_obj():
    return func.HttpRequest(method="POST", url="/api/GetGitHubToken", body=b"", headers={})


@pytest.fixture
def configured_env(monkeypatch, private_key_pem):
    monkeypatch.setenv("GITHUB_APP_ID", APP_ID)
    monkeypatch.setenv("GITHUB_INSTALLATION_ID", INSTALLATION_ID)
    monkeypatch.setenv("GITHUB_PRIVATE_KEY", private_key_pem)


class FakeResponse:
    """Stand-in for requests.Response."""

    def __init__(self, payload=None, error=None, text=""):
        self._payload = payload if payload is not None else {}
        self._error = error
        self.text = text or json.dumps(self._payload)

    def raise_for_status(self):
        if self._error:
            raise self._error

    def json(self):
        return self._payload


def body(response):
    return response.get_body().decode()


# --- environment validation -------------------------------------------------

@pytest.mark.parametrize(
    "missing,expected",
    [
        ("GITHUB_APP_ID", "Missing GITHUB_APP_ID"),
        ("GITHUB_INSTALLATION_ID", "Missing GITHUB_INSTALLATION_ID"),
        ("GITHUB_PRIVATE_KEY", "Missing GITHUB_PRIVATE_KEY"),
    ],
)
def test_missing_env_var_returns_500(
    module, configured_env, request_obj, monkeypatch, missing, expected
):
    monkeypatch.delenv(missing, raising=False)
    response = module.main(request_obj)
    assert response.status_code == 500
    assert body(response) == expected


def test_invalid_private_key_returns_500(module, configured_env, request_obj, monkeypatch):
    monkeypatch.setenv("GITHUB_PRIVATE_KEY", "-----BEGIN RSA PRIVATE KEY-----\nnope\n")
    response = module.main(request_obj)
    assert response.status_code == 500
    assert body(response) == "Invalid private key format"


# --- happy path -------------------------------------------------------------

def test_returns_token_and_signs_valid_jwt(
    module, configured_env, request_obj, monkeypatch, rsa_key
):
    captured = {}

    def fake_post(url, headers=None, **kwargs):
        captured["url"] = url
        captured["headers"] = headers
        captured["kwargs"] = kwargs
        return FakeResponse({"token": "ghs_exampletoken"})

    monkeypatch.setattr(module.requests, "post", fake_post)
    response = module.main(request_obj)

    assert response.status_code == 200
    assert body(response) == "ghs_exampletoken"
    assert captured["url"] == (
        f"https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens"
    )
    assert captured["headers"]["Accept"] == "application/vnd.github+json"

    # The bearer credential must be a valid RS256 App JWT.
    scheme, _, token = captured["headers"]["Authorization"].partition(" ")
    assert scheme == "Bearer"
    assert jwt.get_unverified_header(token)["alg"] == "RS256"
    claims = jwt.decode(token, rsa_key.public_key(), algorithms=["RS256"])
    assert claims["iss"] == APP_ID
    assert claims["exp"] > claims["iat"]
    # GitHub rejects App JWTs whose lifetime exceeds 10 minutes.
    assert claims["exp"] - claims["iat"] <= 600


# --- GitHub API failure modes ----------------------------------------------

def test_api_error_returns_500(module, configured_env, request_obj, monkeypatch):
    monkeypatch.setattr(
        module.requests,
        "post",
        lambda *a, **k: FakeResponse(error=RuntimeError("401 Unauthorized")),
    )
    response = module.main(request_obj)
    assert response.status_code == 500
    assert body(response) == "GitHub API error"


def test_missing_token_in_response_returns_500(
    module, configured_env, request_obj, monkeypatch
):
    monkeypatch.setattr(module.requests, "post", lambda *a, **k: FakeResponse({}))
    response = module.main(request_obj)
    assert response.status_code == 500
    assert body(response) == "No token in response"


# --- regression tests for security / reliability fixes ---------------------

def test_private_key_material_is_never_logged(
    module, configured_env, request_obj, monkeypatch, caplog, private_key_pem
):
    """Logs must not leak bytes of the signing key into Application Insights."""
    monkeypatch.setattr(
        module.requests, "post", lambda *a, **k: FakeResponse({"token": "ghs_x"})
    )
    with caplog.at_level(logging.DEBUG):
        assert module.main(request_obj).status_code == 200

    logged = "\n".join(record.getMessage() for record in caplog.records)
    key_lines = [
        line.strip()
        for line in private_key_pem.splitlines()
        if line.strip() and not line.startswith("-----")
    ]
    assert key_lines, "fixture produced no key body to assert against"
    for line in key_lines:
        assert line not in logged
        # Also catch a truncated prefix of the first key line being logged.
        assert line[:8] not in logged


def test_github_request_has_timeout(module, configured_env, request_obj, monkeypatch):
    """An unbounded POST would pin the worker until the platform timeout."""
    captured = {}

    def fake_post(url, headers=None, **kwargs):
        captured.update(kwargs)
        return FakeResponse({"token": "ghs_x"})

    monkeypatch.setattr(module.requests, "post", fake_post)
    assert module.main(request_obj).status_code == 200
    assert "timeout" in captured, "requests.post called without a timeout"
    assert captured["timeout"] > 0
