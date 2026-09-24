"""Enable the App ID capabilities the app's entitlements need, then regenerate
the App Store profile.

One-shot companion to the release pipeline, run when an entitlement change
(e.g. adding aps-environment or associated domains) invalidates the existing
distribution profile. The capabilities come from the entitlements file itself,
so a new entitlement only needs a line in CAPABILITY_FOR_ENTITLEMENT.
Reuses the release pipeline's App Store Connect API-key secrets via
asc_common. Idempotent: an already-enabled capability and an already-fresh
profile are both treated as success.

Steps:
  1. Find the bundle ID resource for --bundle-id.
  2. Enable each capability the entitlements file declares (409/conflict =
     already on).
  3. Find the newest valid Apple Distribution certificate.
  4. Delete any existing profile named --profile-name (profiles are immutable;
     a capability change makes the old one stale).
  5. Create a fresh IOS_APP_STORE profile with the SAME name, so
     ExportOptions-appstore.plist keeps working unchanged.
"""

from __future__ import annotations

import argparse
import plistlib
from datetime import datetime, timezone
from pathlib import Path

from asc_common import api, fail, first_error_detail, make_token

#: Entitlement key → App Store Connect capability type. iCloud is left out on
#: purpose: it needs container settings the API sets separately, and it is
#: already enabled on the App ID.
CAPABILITY_FOR_ENTITLEMENT = {
    "aps-environment": "PUSH_NOTIFICATIONS",
    "com.apple.developer.associated-domains": "ASSOCIATED_DOMAINS",
}


def capabilities_for(entitlements: Path) -> list[str]:
    """The capability types the entitlements file needs, in a stable order."""
    declared = plistlib.loads(entitlements.read_bytes())
    return [cap for key, cap in CAPABILITY_FOR_ENTITLEMENT.items() if key in declared]


def find_bundle_id(token: str, identifier: str) -> str:
    status, data = api("GET", "/v1/bundleIds", token,
                       query={"filter[identifier]": identifier})
    if status != 200:
        fail(f"Could not list bundle IDs (HTTP {status}).", data)
    matches = [b for b in data.get("data", [])
               if b["attributes"].get("identifier") == identifier]
    if not matches:
        fail(f"No bundle ID resource found for '{identifier}'.")
    return matches[0]["id"]


def enable_capability(token: str, bundle_resource_id: str, capability: str) -> None:
    status, data = api("POST", "/v1/bundleIdCapabilities", token, body={
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": capability},
            "relationships": {
                "bundleId": {
                    "data": {"type": "bundleIds", "id": bundle_resource_id}
                }
            },
        }
    })
    if status == 201:
        print(f"{capability} ENABLED on the App ID.")
        return
    detail = first_error_detail(data)
    if status in (400, 409) and ("already" in detail.lower() or "duplicate" in detail.lower()):
        print(f"{capability} already enabled — OK.")
        return
    fail(f"Could not enable {capability} (HTTP {status}): {detail}", data)


def find_distribution_cert(token: str) -> str:
    status, data = api("GET", "/v1/certificates", token, query={
        "filter[certificateType]": "DISTRIBUTION",
        "limit": "20",
    })
    if status != 200:
        fail(f"Could not list certificates (HTTP {status}).", data)
    now = datetime.now(timezone.utc)
    certs = sorted(data.get("data", []),
                   key=lambda c: c["attributes"].get("expirationDate", ""),
                   reverse=True)
    for cert in certs:
        expires = cert["attributes"].get("expirationDate", "")
        try:
            if datetime.fromisoformat(expires.replace("Z", "+00:00")) > now:
                print(f"Using distribution certificate {cert['id']} "
                      f"(expires {expires}).")
                return cert["id"]
        except ValueError:
            continue
    fail("No valid Apple Distribution certificate found.")


def delete_stale_profiles(token: str, name: str) -> None:
    status, data = api("GET", "/v1/profiles", token,
                       query={"filter[name]": name})
    if status != 200:
        fail(f"Could not list profiles (HTTP {status}).", data)
    for profile in data.get("data", []):
        pid = profile["id"]
        status, resp = api("DELETE", f"/v1/profiles/{pid}", token)
        if status not in (204, 404):
            fail(f"Could not delete stale profile {pid} (HTTP {status}).", resp)
        print(f"Deleted stale profile {pid} ('{name}').")


def create_profile(token: str, name: str, bundle_resource_id: str, cert_id: str) -> None:
    status, data = api("POST", "/v1/profiles", token, body={
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {
                    "data": {"type": "bundleIds", "id": bundle_resource_id}
                },
                "certificates": {
                    "data": [{"type": "certificates", "id": cert_id}]
                },
            },
        }
    })
    if status != 201:
        fail(f"Could not create profile (HTTP {status}): "
             f"{first_error_detail(data)}", data)
    attrs = data["data"]["attributes"]
    print(f"Created profile '{attrs['name']}' "
          f"(id {data['data']['id']}, expires {attrs.get('expirationDate')}).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="com.tollbooth.dpyc.PricingStudio")
    parser.add_argument("--profile-name", default="PricingStudio AppStore")
    parser.add_argument("--entitlements", default="PricingStudio/PricingStudio.entitlements",
                        type=Path)
    args = parser.parse_args()

    token = make_token()
    bundle_resource_id = find_bundle_id(token, args.bundle_id)
    for capability in capabilities_for(args.entitlements):
        enable_capability(token, bundle_resource_id, capability)
    cert_id = find_distribution_cert(token)
    delete_stale_profiles(token, args.profile_name)
    create_profile(token, args.profile_name, bundle_resource_id, cert_id)
    print("Done. The next testflight.yml run fetches this profile automatically.")


if __name__ == "__main__":
    main()
