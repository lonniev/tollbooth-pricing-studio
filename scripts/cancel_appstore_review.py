#!/usr/bin/env python3
"""Pull the app's in-flight App Store version out of review via the ASC API.

Finds the app's open reviewSubmission (the one holding a version in Apple's
queue) and cancels it, returning that version to PREPARE_FOR_SUBMISSION so its
metadata, build, and screenshots can be edited and it can be resubmitted.

Use this to convert an iPad-only submission into a universal one before it is
reviewed, rather than launching iPad-first and updating immediately after.
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, first_error_detail, make_token, resolve_app

# reviewSubmission states that can still be pulled back.
CANCELABLE = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} → id {app_id}")

    subs = api("GET", "/v1/reviewSubmissions", token, query={
        "filter[app]": app_id,
        "fields[reviewSubmissions]": "state,platform",
        "limit": "50",
    })[1]

    open_subs = [s for s in subs.get("data", [])
                 if s["attributes"].get("state") in CANCELABLE]

    if not open_subs:
        print("ℹ️ No in-flight review submission to cancel — nothing in the queue.")
        return

    for sub in open_subs:
        sid = sub["id"]
        state = sub["attributes"].get("state")
        print(f"Canceling review submission {sid} (was {state})…")
        s, r = api("PATCH", f"/v1/reviewSubmissions/{sid}", token, body={
            "data": {"type": "reviewSubmissions", "id": sid,
                     "attributes": {"canceled": True}}})
        if s in (200, 201):
            print(f"✅ Canceled {sid}. Its version returns to PREPARE_FOR_SUBMISSION.")
        else:
            fail(f"Could not cancel {sid} (HTTP {s}): {first_error_detail(r)}", r)

    # Report where the iOS versions landed.
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    print("\nVersions now:")
    for v in vers.get("data", []):
        a = v["attributes"]
        print(f"  • {a.get('versionString')} [{a.get('platform')}] — {a.get('appStoreState')}")


if __name__ == "__main__":
    main()
