#!/usr/bin/env python3
"""Submit the editable App Store version for App Review via the ASC API.

Steps:
  1. Declare no third-party content on the app.
  2. Set App Review contact + notes (notes pre-empt the crypto/IAP review
     questions); no demo account (users self-generate a Nostr keypair).
  3. Set the version to auto-release after approval.
  4. Create a review submission, add the version as an item, and submit.

The submit call validates the whole listing; if anything required is
missing (age rating, privacy, pricing, icon…) ASC returns a descriptive
error, which we surface verbatim.
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, first_error_detail, make_token, resolve_app

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}

REVIEW_NOTES = (
    "Pricing Studio is a companion/admin tool for the DPYC network "
    "(a protocol for paying online services with Bitcoin Lightning "
    "micropayments).\n\n"
    "No login is required to review the app: tap \"Generate Nostr Keypair\" "
    "to create an on-device identity, then browse Network Topology, "
    "Operators, and the Pricing views.\n\n"
    "On payments (re: Guidelines 3.1.1 / 3.1.3 / 3.1.5b): the app does not "
    "sell digital content consumed within the app. The satoshi balances a "
    "user tops up are spent at EXTERNAL third-party MCP services (real "
    "services used outside this app), not on in-app features. Payments are "
    "Bitcoin Lightning invoices the user pays with their OWN external "
    "wallet; the app never holds, transmits, or exchanges the user's funds, "
    "so it is not a custodial cryptocurrency wallet or exchange. There is no "
    "unlockable in-app digital content, so In-App Purchase does not apply."
)


def get_or_create_review_detail(token, vid, args):
    status, data = api("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail", token)
    attrs = {
        "contactFirstName": args.contact_first,
        "contactLastName": args.contact_last,
        "contactPhone": args.contact_phone,
        "contactEmail": args.contact_email,
        "demoAccountRequired": False,
        "demoAccountName": "",
        "demoAccountPassword": "",
        "notes": REVIEW_NOTES,
    }
    if status == 200 and data.get("data"):
        rid = data["data"]["id"]
        s, r = api("PATCH", f"/v1/appStoreReviewDetails/{rid}", token,
                   body={"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": attrs}})
    else:
        s, r = api("POST", "/v1/appStoreReviewDetails", token, body={
            "data": {"type": "appStoreReviewDetails", "attributes": attrs,
                     "relationships": {"appStoreVersion":
                                       {"data": {"type": "appStoreVersions", "id": vid}}}},
        })
    if s not in (200, 201):
        fail(f"Could not set App Review detail (HTTP {s}): {first_error_detail(r)}", r)
    print("✅ App Review contact + notes set.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--contact-first", default="Lonnie")
    ap.add_argument("--contact-last", default="VanZandt")
    ap.add_argument("--contact-email", default="lonniev@gmail.com")
    ap.add_argument("--contact-phone", default="720-201-1349")
    ap.add_argument("--copyright", default="2026 Lonnie VanZandt")
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} → id {app_id}")

    # 1) no third-party content
    s, r = api("PATCH", f"/v1/apps/{app_id}", token, body={
        "data": {"type": "apps", "id": app_id,
                 "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print(f"{'✅' if s in (200,201) else '⚠️'} Content-rights declaration"
          + ("" if s in (200, 201) else f" ({first_error_detail(r)})"))

    # editable version
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    version = next((v for v in vers.get("data", [])
                    if v["attributes"].get("platform") == "IOS"
                    and v["attributes"].get("appStoreState") in EDITABLE_STATES), None)
    if version is None:
        fail("No editable iOS version to submit.")
    vid = version["id"]
    print(f"Version: {version['attributes'].get('versionString')} → id {vid}")

    # 2) review contact + notes
    get_or_create_review_detail(token, vid, args)

    # 3) auto-release after approval + required copyright
    s, r = api("PATCH", f"/v1/appStoreVersions/{vid}", token, body={
        "data": {"type": "appStoreVersions", "id": vid,
                 "attributes": {"releaseType": "AFTER_APPROVAL",
                                "copyright": args.copyright}}})
    print(f"{'✅' if s in (200,201) else '⚠️'} Release type + copyright ('{args.copyright}')"
          + ("" if s in (200, 201) else f" ({first_error_detail(r)})"))

    # 4) review submission → add version → submit
    s, r = api("POST", "/v1/reviewSubmissions", token, body={
        "data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                 "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    if s in (200, 201):
        sub_id = r["data"]["id"]
    else:
        # reuse an open submission if one already exists
        existing = api("GET", "/v1/reviewSubmissions", token, query={
            "filter[app]": app_id, "filter[state]": "READY_FOR_REVIEW", "limit": "1"})[1]
        if existing.get("data"):
            sub_id = existing["data"][0]["id"]
            print("Reusing an open review submission.")
        else:
            fail(f"Could not create review submission (HTTP {s}): {first_error_detail(r)}", r)
    print(f"Review submission → id {sub_id}")

    s, r = api("POST", "/v1/reviewSubmissionItems", token, body={
        "data": {"type": "reviewSubmissionItems",
                 "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                                   "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    if s not in (200, 201) and "already" not in first_error_detail(r).lower():
        print(f"⚠️ add item failed (HTTP {s}). Full errors:")
        import json as _json
        print(_json.dumps(r.get("errors", r), indent=2)[:2500])
        # Surface the version's own blocking issues if exposed.
        vs, vr = api("GET", f"/v1/appStoreVersions/{vid}", token,
                     query={"fields[appStoreVersions]": "appStoreState,appVersionState"})
        print("version state:", _json.dumps(vr.get("data", {}).get("attributes", {})))
    else:
        print("✅ Version added to the submission.")

    s, r = api("PATCH", f"/v1/reviewSubmissions/{sub_id}", token, body={
        "data": {"type": "reviewSubmissions", "id": sub_id, "attributes": {"submitted": True}}})
    if s in (200, 201):
        print("\n🚀 Submitted for App Review. Apple will email the outcome; on "
              "approval it auto-releases to the App Store (free).")
    else:
        fail(f"Submit failed (HTTP {s}): {first_error_detail(r)}\n"
             f"This usually lists exactly what's still missing (age rating, "
             f"privacy, icon, pricing…). Fix it and re-run.", r)


if __name__ == "__main__":
    main()
