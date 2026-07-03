#!/usr/bin/env python3
"""Invite a TestFlight beta tester via the App Store Connect API.

Reuses the same API-key credentials the release CI already holds:
  ASC_KEY_ID           — the key's Key ID (kid)
  ASC_ISSUER_ID        — the team's Issuer ID (iss)
  ASC_PRIVATE_KEY      — the .p8 private key, PEM text (BEGIN PRIVATE KEY …)

Resolves the app by bundle id, picks the target beta group (by name, or the
sole group of the requested kind), then creates the tester and attaches them
to that group — which is what triggers the invitation for external testers.

Docs: https://developer.apple.com/documentation/appstoreconnectapi
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, first_error_detail, make_token, resolve_app


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", required=True)
    ap.add_argument("--first-name", default="Beta")
    ap.add_argument("--last-name", default="Tester")
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--group", default="", help="Beta group name; blank = the app's sole group of the chosen kind")
    ap.add_argument("--type", choices=["external", "internal"], default="external")
    ap.add_argument("--create-group", action="store_true",
                    help="Create the external group if it doesn't exist (external only)")
    args = ap.parse_args()

    token = make_token()

    # 1) Resolve the app by bundle id.
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} ({args.bundle_id}) → id {app_id}")

    # 2) Resolve the target beta group.
    status, data = api("GET", "/v1/betaGroups", token,
                       query={"filter[app]": app_id, "limit": "200",
                              "fields[betaGroups]": "name,isInternalGroup"})
    if status != 200:
        fail(f"Could not list beta groups (HTTP {status}).", data)
    want_internal = args.type == "internal"
    groups = [g for g in data.get("data", [])
              if bool(g["attributes"].get("isInternalGroup")) == want_internal]

    group = None
    if args.group:
        match = [g for g in groups if g["attributes"]["name"].lower() == args.group.lower()]
        if match:
            group = match[0]
    elif len(groups) == 1:
        group = groups[0]
    elif len(groups) > 1:
        names = ", ".join(g["attributes"]["name"] for g in groups)
        fail(f"Multiple {args.type} groups exist — pass --group. Available: {names}")

    if group is None:
        kind = "internal" if want_internal else "external"
        if want_internal:
            fail("No internal beta group exists. Internal groups can't be created "
                 "via the API — create one in App Store Connect → TestFlight.")
        if not args.create_group:
            names = ", ".join(g["attributes"]["name"] for g in groups) or "(none)"
            fail(f"No matching {kind} group. Existing: {names}. "
                 f"Re-run with --create-group to make it.")
        new_name = args.group or "External Testers"
        print(f"Creating external group '{new_name}'…")
        status, data = api("POST", "/v1/betaGroups", token, body={
            "data": {
                "type": "betaGroups",
                "attributes": {"name": new_name, "publicLinkEnabled": False},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        })
        if status not in (200, 201):
            fail(f"Could not create external group (HTTP {status}): "
                 f"{first_error_detail(data)}", data)
        group = data["data"]
    group_id = group["id"]
    print(f"Group: {group['attributes']['name']} → id {group_id}")

    # 3) Create the tester attached to the group (this sends the invite).
    body = {
        "data": {
            "type": "betaTesters",
            "attributes": {
                "email": args.email,
                "firstName": args.first_name,
                "lastName": args.last_name,
            },
            "relationships": {
                "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]},
            },
        }
    }
    status, data = api("POST", "/v1/betaTesters", token, body=body)
    if status in (200, 201):
        print(f"✅ Invited {args.email} to '{group['attributes']['name']}'.")
        return
    if status == 409:
        # Tester already exists — just add them to the group.
        print(f"{args.email} already exists as a tester; adding to the group…")
        status, data = api("GET", "/v1/betaTesters", token,
                           query={"filter[email]": args.email, "limit": "1"})
        if status != 200 or not data.get("data"):
            fail("Tester exists but could not be looked up by email.", data)
        tester_id = data["data"][0]["id"]
        status, data = api("POST", f"/v1/betaGroups/{group_id}/relationships/betaTesters",
                           token, body={"data": [{"type": "betaTesters", "id": tester_id}]})
        if status in (200, 201, 204):
            print(f"✅ Added existing tester {args.email} to '{group['attributes']['name']}'.")
            return
        fail(f"Failed to add existing tester to the group (HTTP {status}): "
             f"{first_error_detail(data)}", data)
    fail(f"Failed to invite tester (HTTP {status}): {first_error_detail(data)}", data)


if __name__ == "__main__":
    main()
