#!/usr/bin/env python3
"""Fill the App Store listing metadata via the App Store Connect API.

Sets the mechanical, tedious-in-UI parts of the listing:
  - primary category
  - App Info localization: subtitle + privacy policy URL
  - version string + attaches the latest processed build
  - version localization: description, keywords, promo text, support/
    marketing URLs, "What's New"

Does NOT touch: pricing (set Free in the UI — the pricing API is fiddly and
it's one click), screenshots, App Privacy label, or the age-rating
questionnaire. Store copy lives here so it's reviewable in version control.
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, first_error_detail, make_token, resolve_app

SUBTITLE = "Dynamic pricing over Lightning"

KEYWORDS = ("lightning,bitcoin,nostr,mcp,operator,dynamic pricing,satoshi,"
            "payments,dpyc,api,micropayments")

PROMOTIONAL = ("Design dynamic pricing for the services you operate, own your "
               "Nostr identity, and top up satoshi balances over Bitcoin "
               "Lightning — no accounts, no funds held.")

DESCRIPTION = """Pricing Studio is the companion app for the DPYC network — design and manage dynamic pricing for the online services you operate, and keep your identity, credentials, and satoshi balances in your own hands.

Model your prices
• Build and visualize dynamic pricing models for the MCP services you run
• Explore constraints, discounts, and surge scenarios before you publish
• Get AI-assisted suggestions from the assistant you choose

Own your identity
• Your identity is a Nostr keypair you create — no email, no password
• Your secret key stays in your device Keychain and never leaves it
• Share credentials only over end-to-end encrypted channels

Top up over Lightning
• Fund satoshi balances by paying a Bitcoin Lightning invoice with your own wallet
• The app never custodies your funds
• Review statements and reconcile balances at a glance

Pricing Studio is built for the DPYC ("Don't Pester Your Customer") ecosystem, where services are paid for with pre-funded Lightning micropayments instead of intrusive per-request payment prompts."""

WHATS_NEW = "Initial public release."

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}


def latest_valid_build_id(token, app_id):
    status, data = api("GET", "/v1/builds", token, query={
        "filter[app]": app_id, "sort": "-uploadedDate", "limit": "10",
        "fields[builds]": "version,processingState",
    })
    if status != 200:
        fail(f"Could not list builds (HTTP {status}).", data)
    for b in data.get("data", []):
        if b["attributes"].get("processingState") == "VALID":
            return b["id"], b["attributes"].get("version")
    fail("No processed (VALID) build to attach yet — wait for processing.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--category", default="BUSINESS")
    ap.add_argument("--version-string", default="1.10.0")
    ap.add_argument("--privacy-url", required=True)
    ap.add_argument("--support-url", required=True)
    ap.add_argument("--marketing-url", default="")
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} ({args.bundle_id}) → id {app_id}\n")

    # ---- App Info: category + subtitle + privacy policy URL ----
    info = api("GET", f"/v1/apps/{app_id}/appInfos", token)[1]
    app_info = info["data"][0]
    app_info_id = app_info["id"]

    status, data = api("PATCH", f"/v1/appInfos/{app_info_id}", token, body={
        "data": {
            "type": "appInfos", "id": app_info_id,
            "relationships": {
                "primaryCategory": {"data": {"type": "appCategories", "id": args.category}},
            },
        }
    })
    print(f"{'✅' if status in (200,201) else '❌'} Primary category → {args.category}"
          + ("" if status in (200, 201) else f"  ({first_error_detail(data)})"))

    locs = api("GET", f"/v1/appInfos/{app_info_id}/appInfoLocalizations", token)[1]
    for l in locs.get("data", []):
        lid = l["id"]
        status, data = api("PATCH", f"/v1/appInfoLocalizations/{lid}", token, body={
            "data": {"type": "appInfoLocalizations", "id": lid,
                     "attributes": {"subtitle": SUBTITLE, "privacyPolicyUrl": args.privacy_url}},
        })
        print(f"{'✅' if status in (200,201) else '❌'} [{l['attributes'].get('locale')}] "
              f"subtitle + privacy URL"
              + ("" if status in (200, 201) else f"  ({first_error_detail(data)})"))

    # ---- App Store version: version string + build ----
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    version = next((v for v in vers.get("data", [])
                    if v["attributes"].get("platform") == "IOS"
                    and v["attributes"].get("appStoreState") in EDITABLE_STATES), None)
    if version is None:
        fail("No editable iOS version. Create one (state PREPARE_FOR_SUBMISSION) first.")
    vid = version["id"]

    status, data = api("PATCH", f"/v1/appStoreVersions/{vid}", token, body={
        "data": {"type": "appStoreVersions", "id": vid,
                 "attributes": {"versionString": args.version_string}},
    })
    print(f"{'✅' if status in (200,201) else '❌'} Version string → {args.version_string}"
          + ("" if status in (200, 201) else f"  ({first_error_detail(data)})"))

    build_id, build_num = latest_valid_build_id(token, app_id)
    status, data = api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", token,
                       body={"data": {"type": "builds", "id": build_id}})
    print(f"{'✅' if status in (200,201,204) else '❌'} Attached build {build_num}"
          + ("" if status in (200, 201, 204) else f"  ({first_error_detail(data)})"))

    # ---- Version localization: description, keywords, URLs, promo, whatsNew ----
    vlocs = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", token)[1]
    for l in vlocs.get("data", []):
        lid = l["id"]
        attrs = {
            "description": DESCRIPTION,
            "keywords": KEYWORDS,
            "promotionalText": PROMOTIONAL,
            "supportUrl": args.support_url,
            "whatsNew": WHATS_NEW,
        }
        if args.marketing_url:
            attrs["marketingUrl"] = args.marketing_url
        status, data = api("PATCH", f"/v1/appStoreVersionLocalizations/{lid}", token, body={
            "data": {"type": "appStoreVersionLocalizations", "id": lid, "attributes": attrs},
        })
        print(f"{'✅' if status in (200,201) else '❌'} [{l['attributes'].get('locale')}] "
              f"description + keywords + URLs"
              + ("" if status in (200, 201) else f"  ({first_error_detail(data)})"))

    print("\nStill to do (not set here):")
    print("  • Pricing → set Free (one click in the UI; pricing API is fiddly)")
    print("  • Screenshots → iPad 13\" (this is an iPad-only app)")
    print("  • App Privacy label + Age Rating questionnaire (UI)")


if __name__ == "__main__":
    main()
