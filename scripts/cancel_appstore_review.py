#!/usr/bin/env python3
"""Pull the app's in-flight App Store version out of review via the ASC API.

Returns the version to PREPARE_FOR_SUBMISSION so its metadata, build, and
screenshots can be edited and it can be resubmitted — used to convert an
iPad-only submission into a universal one before it is reviewed.

Apple exposes two submission mechanisms and the right lever depends on state:
  • a modern `reviewSubmission` — cancel it (WAITING/IN_REVIEW/UNRESOLVED) or
    delete it while it is still READY_FOR_REVIEW (staged, not yet in Apple's
    hands);
  • a legacy per-version `appStoreVersionSubmission` — delete it.
This tries whichever applies and prints full diagnostics either way.
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, first_error_detail, make_token, resolve_app

CANCELABLE = {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}


def diagnostics(token, app_id):
    print("== iOS versions ==")
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    ios = []
    for v in vers.get("data", []):
        a = v["attributes"]
        print(f"  • {a.get('versionString')} [{a.get('platform')}] — {a.get('appStoreState')} (id {v['id']})")
        if a.get("platform") == "IOS":
            ios.append(v)

    print("== review submissions ==")
    subs = api("GET", "/v1/reviewSubmissions", token, query={
        "filter[app]": app_id, "fields[reviewSubmissions]": "state,platform", "limit": "50"})[1]
    for s in subs.get("data", []):
        print(f"  • {s['id']} — {s['attributes'].get('state')} [{s['attributes'].get('platform')}]")
    return ios, subs.get("data", [])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} → id {app_id}\n")

    ios, subs = diagnostics(token, app_id)
    print()

    acted = False

    # 1) reviewSubmissions: cancel if truly in review, delete if merely staged.
    for s in subs:
        sid, state = s["id"], s["attributes"].get("state")
        if state in CANCELABLE:
            print(f"Canceling review submission {sid} ({state})…")
            st, r = api("PATCH", f"/v1/reviewSubmissions/{sid}", token, body={
                "data": {"type": "reviewSubmissions", "id": sid, "attributes": {"canceled": True}}})
            print(f"  {'✅ canceled' if st in (200, 201) else '⚠️ ' + first_error_detail(r)}")
            acted = acted or st in (200, 201)
        elif state == "READY_FOR_REVIEW":
            print(f"Deleting staged review submission {sid} ({state})…")
            st, r = api("DELETE", f"/v1/reviewSubmissions/{sid}", token)
            print(f"  {'✅ deleted' if st in (200, 204) else '⚠️ ' + first_error_detail(r)}")
            acted = acted or st in (200, 204)

    # 2) legacy per-version submissions on any in-review iOS version.
    for v in ios:
        if v["attributes"].get("appStoreState") not in (
            "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PROCESSING_FOR_APP_STORE"
        ):
            continue
        vid = v["id"]
        sub = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionSubmission", token)[1]
        sd = sub.get("data")
        if sd:
            print(f"Deleting legacy version submission {sd['id']} for {v['attributes'].get('versionString')}…")
            st, r = api("DELETE", f"/v1/appStoreVersionSubmissions/{sd['id']}", token)
            print(f"  {'✅ deleted' if st in (200, 204) else '⚠️ ' + first_error_detail(r)}")
            acted = acted or st in (200, 204)

    if not acted:
        fail("Nothing was pulled from review — see states above; no lever applied.")

    print("\n== versions after ==")
    diagnostics(token, app_id)


if __name__ == "__main__":
    main()
