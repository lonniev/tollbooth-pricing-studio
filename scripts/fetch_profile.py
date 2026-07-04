"""Fetch the active provisioning profile from App Store Connect by name.

Used by testflight.yml at build time so the pipeline always signs with the
CURRENT profile — a capability change followed by provision_push.py takes
effect on the next build with no secret rotation. Writes the decoded
.mobileprovision to --out.
"""

from __future__ import annotations

import argparse
import base64
from pathlib import Path

from asc_common import api, fail, make_token


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-name", default="PricingStudio AppStore")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    token = make_token()
    status, data = api("GET", "/v1/profiles", token, query={
        "filter[name]": args.profile_name,
        "fields[profiles]": "name,profileState,profileContent,expirationDate",
    })
    if status != 200:
        fail(f"Could not list profiles (HTTP {status}).", data)

    active = [p for p in data.get("data", [])
              if p["attributes"].get("profileState") == "ACTIVE"]
    if not active:
        fail(f"No ACTIVE profile named '{args.profile_name}'. "
             "Run the provision-push workflow to (re)create it.")

    attrs = active[0]["attributes"]
    args.out.write_bytes(base64.b64decode(attrs["profileContent"]))
    print(f"Fetched profile '{attrs['name']}' "
          f"(expires {attrs.get('expirationDate')}) -> {args.out}")


if __name__ == "__main__":
    main()
