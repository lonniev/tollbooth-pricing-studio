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
import time

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

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}


def latest_valid_build_id(token, app_id, require_build="", wait_minutes=0):
    """Newest VALID build, or specifically build `require_build` if given.

    Naming note: a build's `version` attribute is its CFBundleVersion — the
    build NUMBER (e.g. "265"), not the marketing version.

    Pin the build number when cutting a release. Uploads are processed
    asynchronously, so "newest VALID" right after an upload is usually the
    PREVIOUS build — and that build carries the previous marketing version,
    which would silently attach the wrong binary to the new version record.
    """
    deadline = time.monotonic() + wait_minutes * 60
    while True:
        status, data = api("GET", "/v1/builds", token, query={
            "filter[app]": app_id, "sort": "-uploadedDate", "limit": "10",
            "fields[builds]": "version,processingState",
        })
        if status != 200:
            fail(f"Could not list builds (HTTP {status}).", data)
        builds = data.get("data", [])

        if require_build:
            match = next((b for b in builds
                          if b["attributes"].get("version") == require_build), None)
            if match is None:
                seen = ", ".join(f"{b['attributes'].get('version')}"
                                 f"({b['attributes'].get('processingState')})"
                                 for b in builds) or "none"
                fail(f"Build {require_build} is not among the 10 most recent "
                     f"uploads. Seen: {seen}")
            state = match["attributes"].get("processingState")
            if state == "VALID":
                return match["id"], require_build
            if state in ("INVALID", "FAILED"):
                fail(f"Build {require_build} finished processing as {state}.")
            if time.monotonic() >= deadline:
                fail(f"Build {require_build} is still {state} after "
                     f"{wait_minutes} min. Re-run once it is VALID.")
            print(f"   build {require_build} is {state} — waiting 60s…",
                  flush=True)
            time.sleep(60)
            continue

        for b in builds:
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
    ap.add_argument("--copyright", default="2026 Lonnie VanZandt")
    ap.add_argument("--require-build", default="",
                    help="CFBundleVersion (build number) that MUST be the one "
                         "attached, e.g. 265. Guards against attaching the "
                         "previous build while this one is still processing.")
    ap.add_argument("--wait-minutes", type=int, default=0,
                    help="How long to wait for --require-build to become VALID.")
    ap.add_argument("--whats-new", default="",
                    help="Release notes. REQUIRED on an update, REJECTED on a "
                         "first release — pass empty for the latter.")
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} ({args.bundle_id}) → id {app_id}\n")

    # ---- App Info: category + subtitle + privacy policy URL ----
    # A live app has TWO appInfos: the one backing the released version, which
    # is frozen, and an editable one for the next release. Taking [0] worked
    # only because a never-released app has exactly one. On an update it picks
    # the frozen record about half the time, and every PATCH then comes back
    # "can not be modified in the current state" — which reads like a
    # permissions problem and is really the wrong record.
    info = api("GET", f"/v1/apps/{app_id}/appInfos", token, query={
        "fields[appInfos]": "appStoreState"})[1]
    infos = info.get("data", [])
    if not infos:
        fail("App has no appInfo records.")
    app_info = next((i for i in infos
                     if i["attributes"].get("appStoreState") in EDITABLE_STATES),
                    None)
    if app_info is None:
        states = ", ".join(str(i["attributes"].get("appStoreState")) for i in infos)
        print(f"⚠️  No editable appInfo (states: {states}); using the first. "
              f"Category/subtitle edits will likely be refused.")
        app_info = infos[0]
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
        # The first release had a version record waiting in PREPARE_FOR_SUBMISSION
        # because the UI creates one with the app. On an UPDATE there is no
        # editable version at all — the live one is READY_FOR_SALE and immutable —
        # so create it here instead of sending the operator back to the browser.
        status, data = api("POST", "/v1/appStoreVersions", token, body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": "IOS",
                    "versionString": args.version_string,
                    # copyright is REQUIRED and the UI fills it silently. Omitting
                    # it does not fail here — it surfaces much later as a 409
                    # "cannot be reviewed" on reviewSubmissionItems, with the real
                    # reason buried in meta.associatedErrors.
                    "copyright": args.copyright,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            },
        })
        if status not in (200, 201):
            fail(f"Could not create App Store version {args.version_string}.", data)
        version = data["data"]
        print(f"✅ Created version {args.version_string} "
              f"(no editable version existed — this is an update)")
    vid = version["id"]

    status, data = api("PATCH", f"/v1/appStoreVersions/{vid}", token, body={
        "data": {"type": "appStoreVersions", "id": vid,
                 "attributes": {"versionString": args.version_string,
                                "copyright": args.copyright}},
    })
    print(f"{'✅' if status in (200,201) else '❌'} Version string → {args.version_string}"
          + ("" if status in (200, 201) else f"  ({first_error_detail(data)})"))

    build_id, build_num = latest_valid_build_id(
        token, app_id, args.require_build, args.wait_minutes)
    status, data = api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", token,
                       body={"data": {"type": "builds", "id": build_id}})
    print(f"{'✅' if status in (200,201,204) else '❌'} Attached build {build_num}"
          + ("" if status in (200, 201, 204) else f"  ({first_error_detail(data)})"))

    # ---- Version localization: description, keywords, URLs, promo, whatsNew ----
    vlocs = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", token)[1]
    for l in vlocs.get("data", []):
        lid = l["id"]
        # NB: 'whatsNew' is rejected on a first release (no prior version to
        # describe changes from) and REQUIRED on an update. The caller decides
        # by passing --whats-new or leaving it empty.
        attrs = {
            "description": DESCRIPTION,
            "keywords": KEYWORDS,
            "promotionalText": PROMOTIONAL,
            "supportUrl": args.support_url,
        }
        if args.whats_new:
            attrs["whatsNew"] = args.whats_new
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
    print("  • Screenshots → iPad 13\" + iPhone 6.7\" (the app is universal)")
    print("  • App Privacy label + Age Rating questionnaire (UI)")


if __name__ == "__main__":
    main()
