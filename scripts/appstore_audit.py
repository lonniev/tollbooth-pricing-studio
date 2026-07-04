#!/usr/bin/env python3
"""Read-only audit of the App Store listing readiness for a public release.

Reports what's already filled vs missing across: app info (name/subtitle/
categories/privacy policy), the editable version's metadata (description,
keywords, URLs, screenshots, attached build), pricing, and age rating.

Some review requirements (App Privacy "nutrition label", the age-rating
questionnaire answers) aren't fully exposed by the API — those are flagged
as "verify in the App Store Connect UI". Nothing here writes anything.
"""

from __future__ import annotations

import argparse

from asc_common import api, fail, make_token, resolve_app

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REMOVED_FROM_SALE",
}


def mark(ok):  # noqa: ANN001
    return "✅" if ok else "❌"


def get(token, path, query=None):
    status, data = api("GET", path, token, query=query)
    return (data if status == 200 else None)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} ({args.bundle_id}) → id {app_id}\n")

    # ---- App-level info (name/subtitle/privacy policy/categories) ----
    print("== App information ==")
    info = get(token, f"/v1/apps/{app_id}/appInfos",
               {"include": "primaryCategory,secondaryCategory"})
    if info and info.get("data"):
        app_info = info["data"][0]
        rels = app_info.get("relationships", {})
        prim = rels.get("primaryCategory", {}).get("data")
        sec = rels.get("secondaryCategory", {}).get("data")
        cats = {c["id"]: c for c in info.get("included", [])}
        print(f"  {mark(prim)} Primary category: {prim['id'] if prim else '— MISSING'}")
        print(f"  {'ℹ️ ' if sec else '  '} Secondary category: {sec['id'] if sec else '(none, optional)'}")
        loc = get(token, f"/v1/appInfos/{app_info['id']}/appInfoLocalizations",
                  {"fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl"})
        for l in (loc.get("data", []) if loc else []):
            a = l["attributes"]
            print(f"  [{a.get('locale')}]")
            print(f"    {mark(a.get('name'))} Name: {a.get('name') or '— MISSING'}")
            print(f"    {'ℹ️ ' if a.get('subtitle') else '  '} Subtitle: {a.get('subtitle') or '(none, optional but recommended)'}")
            print(f"    {mark(a.get('privacyPolicyUrl'))} Privacy Policy URL: {a.get('privacyPolicyUrl') or '— MISSING (required)'}")
    else:
        print("  ⚠️  Could not read appInfos — check in the UI.")

    # ---- Editable App Store version + metadata ----
    print("\n== App Store version ==")
    vers = get(token, f"/v1/apps/{app_id}/appStoreVersions",
               {"limit": "10",
                "fields[appStoreVersions]": "versionString,appStoreState,platform,createdDate"})
    version = None
    for v in (vers.get("data", []) if vers else []):
        st = v["attributes"].get("appStoreState")
        plat = v["attributes"].get("platform")
        print(f"  • {v['attributes'].get('versionString')} [{plat}] — {st}")
        if version is None and plat == "IOS" and st in EDITABLE_STATES:
            version = v
    if version is None:
        print("  ❌ No editable iOS version (state PREPARE_FOR_SUBMISSION). "
              "Create a version in the UI (or I can add it via API) before submitting.")
        print("\n(See App Privacy + Age Rating notes below regardless.)")
        _print_ui_only()
        return

    vid = version["id"]
    vstr = version["attributes"].get("versionString")
    print(f"\n  Editable version: {vstr} → id {vid}")

    # metadata localizations
    locs = get(token, f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations",
               {"fields[appStoreVersionLocalizations]":
                "locale,description,keywords,supportUrl,marketingUrl,promotionalText,whatsNew"})
    for l in (locs.get("data", []) if locs else []):
        a = l["attributes"]
        print(f"  [{a.get('locale')}] metadata")
        print(f"    {mark(a.get('description'))} Description: {'set' if a.get('description') else '— MISSING (required)'}")
        print(f"    {mark(a.get('keywords'))} Keywords: {'set' if a.get('keywords') else '— MISSING'}")
        print(f"    {mark(a.get('supportUrl'))} Support URL: {a.get('supportUrl') or '— MISSING (required)'}")
        print(f"    {'ℹ️ ' if a.get('marketingUrl') else '  '} Marketing URL: {a.get('marketingUrl') or '(none, optional)'}")
        # screenshots
        sets = get(token, f"/v1/appStoreVersionLocalizations/{l['id']}/appScreenshotSets",
                   {"fields[appScreenshotSets]": "screenshotDisplayType"})
        n = len(sets.get("data", [])) if sets else 0
        print(f"    {mark(n)} Screenshot sets: {n if n else '— MISSING (at least one iPhone size required)'}")

    # attached build
    b = get(token, f"/v1/appStoreVersions/{vid}/build",
            {"fields[builds]": "version,processingState"})
    bd = b.get("data") if b else None
    print(f"  {mark(bd)} Build attached: "
          f"{bd['attributes'].get('version') if bd else '— MISSING (attach a processed build)'}")

    # ---- Age rating (API-visible) ----
    print("\n== Age rating ==")
    ard = get(token, f"/v1/appStoreVersions/{vid}/ageRatingDeclaration")
    if ard and ard.get("data"):
        print("  ✅ Age rating declaration exists.")
    else:
        print("  ❌ No age rating declaration — complete Age Rating in the UI and Save.")

    # ---- Pricing ----
    print("\n== Pricing ==")
    sched = get(token, f"/v1/apps/{app_id}/appPriceSchedule",
                {"include": "manualPrices,baseTerritory"})
    if sched and sched.get("data"):
        print("  ✅ A price schedule exists. Verify it's the FREE tier (0) in the UI.")
    else:
        print("  ❌ No price schedule found — set the app to Free (Price Schedule → free tier).")

    _print_ui_only()


def _print_ui_only() -> None:
    print("\n== Verify in the App Store Connect UI (not fully API-exposed) ==")
    print("  ⚠️  App Privacy — the data-collection 'nutrition label' questionnaire (REQUIRED)")
    print("  ⚠️  Age Rating — the content questionnaire (REQUIRED)")
    print("  ⚠️  1024×1024 App Store icon (usually from the asset catalog in the build)")
    print("  ⚠️  Agreements/Tax/Banking — for a FREE app only the free agreement must be active")


if __name__ == "__main__":
    main()
