"""Shared App Store Connect API helpers for the CI scripts.

Reuses the release pipeline's API-key secrets, read from the environment:
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (PEM text of the .p8).

Docs: https://developer.apple.com/documentation/appstoreconnectapi
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT (needs `cryptography` for ES256)

API_ROOT = "https://api.appstoreconnect.apple.com"


def make_token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    private_key = os.environ["ASC_PRIVATE_KEY"]
    now = int(time.time())
    return jwt.encode(
        {
            "iss": issuer_id,
            "iat": now,
            "exp": now + 1200,  # max 20 minutes
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(method: str, path: str, token: str, body=None, query=None):
    url = API_ROOT + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, {"raw": raw.decode(errors="replace")}


def fail(msg: str, payload=None) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    if payload is not None:
        print(json.dumps(payload, indent=2), file=sys.stderr)
    sys.exit(1)


def first_error_detail(payload) -> str:
    if isinstance(payload, dict):
        for err in payload.get("errors", []):
            detail = err.get("detail") or err.get("title")
            if detail:
                return detail
    return json.dumps(payload)


def resolve_app(token: str, bundle_id: str):
    """Return (app_id, app_name) for a bundle id, or fail."""
    status, data = api("GET", "/v1/apps", token,
                       query={"filter[bundleId]": bundle_id, "fields[apps]": "name,bundleId"})
    if status != 200:
        fail(f"Could not list apps (HTTP {status}). The API key may lack access.", data)
    apps = data.get("data", [])
    if not apps:
        fail(f"No app found for bundle id '{bundle_id}'.")
    return apps[0]["id"], apps[0]["attributes"].get("name")
