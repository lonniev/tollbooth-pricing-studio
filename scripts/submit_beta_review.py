#!/usr/bin/env python3
"""Submit the latest processed build for external TestFlight Beta App Review.

Steps (all idempotent / tolerant of the "already done" state):
  1. Resolve the app and its latest VALID (processed) build.
  2. Set the app's Beta App Review contact details (no demo account needed).
  3. Ensure the build has a "What to Test" note.
  4. Assign the build to the external beta group.
  5. Create a Beta App Review submission for the build.

If the newest build is still processing, exits non-zero with a clear
"not ready — re-run shortly" message rather than a hard error.

Docs: https://developer.apple.com/documentation/appstoreconnectapi
"""

from __future__ import annotations

import argparse
import sys

from asc_common import api, fail, first_error_detail, make_token, resolve_app


def latest_valid_build(token: str, app_id: str):
    """Newest build by upload date; returns (build_or_None, newest_state)."""
    status, data = api("GET", "/v1/builds", token, query={
        "filter[app]": app_id,
        "sort": "-uploadedDate",
        "limit": "10",
        "fields[builds]": "version,processingState,uploadedDate",
    })
    if status != 200:
        fail(f"Could not list builds (HTTP {status}).", data)
    builds = data.get("data", [])
    if not builds:
        fail("No builds found for this app — upload one first (push to main).")
    for b in builds:
        if b["attributes"].get("processingState") == "VALID":
            return b, b["attributes"].get("processingState")
    return None, builds[0]["attributes"].get("processingState")


def resolve_external_group(token: str, app_id: str, name: str):
    status, data = api("GET", "/v1/betaGroups", token, query={
        "filter[app]": app_id, "limit": "200",
        "fields[betaGroups]": "name,isInternalGroup",
    })
    if status != 200:
        fail(f"Could not list beta groups (HTTP {status}).", data)
    ext = [g for g in data.get("data", []) if not g["attributes"].get("isInternalGroup")]
    match = [g for g in ext if g["attributes"]["name"].lower() == name.lower()]
    if not match:
        names = ", ".join(g["attributes"]["name"] for g in ext) or "(none)"
        fail(f"No external group named '{name}'. Available: {names}")
    return match[0]["id"]


def set_review_contact(token: str, app_id: str, args) -> None:
    status, data = api("GET", f"/v1/apps/{app_id}/betaAppReviewDetail", token)
    if status != 200 or not data.get("data"):
        fail(f"Could not read Beta App Review detail (HTTP {status}).", data)
    detail_id = data["data"]["id"]
    status, data = api("PATCH", f"/v1/betaAppReviewDetails/{detail_id}", token, body={
        "data": {
            "type": "betaAppReviewDetails",
            "id": detail_id,
            "attributes": {
                "contactFirstName": args.contact_first,
                "contactLastName": args.contact_last,
                "contactEmail": args.contact_email,
                "contactPhone": args.contact_phone,
                "demoAccountRequired": False,
                "demoAccountName": "",
                "demoAccountPassword": "",
                "notes": args.notes,
            },
        }
    })
    if status not in (200, 201):
        fail(f"Could not set review contact (HTTP {status}): {first_error_detail(data)}", data)
    print("✓ Beta App Review contact set.")


def ensure_whats_new(token: str, build_id: str, whats_new: str) -> None:
    status, data = api("GET", f"/v1/builds/{build_id}/betaBuildLocalizations", token,
                       query={"fields[betaBuildLocalizations]": "locale,whatsNew"})
    locs = data.get("data", []) if status == 200 else []
    if locs:
        loc_id = locs[0]["id"]
        api("PATCH", f"/v1/betaBuildLocalizations/{loc_id}", token, body={
            "data": {"type": "betaBuildLocalizations", "id": loc_id,
                     "attributes": {"whatsNew": whats_new}},
        })
    else:
        api("POST", "/v1/betaBuildLocalizations", token, body={
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": "en-US", "whatsNew": whats_new},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        })
    print("✓ 'What to Test' note set.")


def assign_build_to_group(token: str, group_id: str, build_id: str) -> None:
    status, data = api("POST", f"/v1/betaGroups/{group_id}/relationships/builds", token,
                       body={"data": [{"type": "builds", "id": build_id}]})
    if status in (200, 201, 204):
        print("✓ Build assigned to external group.")
    else:
        # Non-fatal: it may already be assigned, or assignment may wait on review.
        print(f"⚠ Could not assign build to group (HTTP {status}): "
              f"{first_error_detail(data)} — continuing.")


def submit_for_review(token: str, build_id: str) -> None:
    status, data = api("POST", "/v1/betaAppReviewSubmissions", token, body={
        "data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }
    })
    if status in (200, 201):
        print("✅ Build submitted for Beta App Review.")
        return
    if status == 409:
        print("✅ Build was already submitted for Beta App Review.")
        return
    fail(f"Could not submit for review (HTTP {status}): {first_error_detail(data)}", data)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--group", default="External Testers")
    ap.add_argument("--contact-first", required=True)
    ap.add_argument("--contact-last", required=True)
    ap.add_argument("--contact-email", required=True)
    ap.add_argument("--contact-phone", required=True)
    ap.add_argument("--notes", default="No login required — testers generate their own Nostr keypair in-app.")
    ap.add_argument("--whats-new", default="Initial external TestFlight build.")
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} ({args.bundle_id}) → id {app_id}")

    build, state = latest_valid_build(token, app_id)
    if build is None:
        print(f"::warning::Newest build is '{state}', not VALID yet. "
              f"Not an error — re-run this workflow once processing finishes.")
        sys.exit(1)
    build_id = build["id"]
    print(f"Build: {build['attributes'].get('version')} (VALID) → id {build_id}")

    group_id = resolve_external_group(token, app_id, args.group)
    print(f"Group: {args.group} → id {group_id}")

    set_review_contact(token, app_id, args)
    ensure_whats_new(token, build_id, args.whats_new)
    assign_build_to_group(token, group_id, build_id)
    submit_for_review(token, build_id)
    print("\nDone. Apple will email the review outcome; once approved, external "
          "testers in the group can install the build.")


if __name__ == "__main__":
    main()
