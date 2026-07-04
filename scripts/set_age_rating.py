#!/usr/bin/env python3
"""Set the App Store age rating to the lowest (all None → 4+) via the ASC API.

Prints the current ageRatingDeclaration first (so we can see the account's
schema), then PATCHes it (or POSTs a new one) with every content category
set to NONE / false.
"""

from __future__ import annotations

import argparse
import json

from asc_common import api, fail, first_error_detail, make_token, resolve_app

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}

# Every content category at its lowest level → 4+.
NONE_LEVELS = [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "violenceCartoonOrFantasy", "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
]
FALSE_FLAGS = ["gambling", "unrestrictedWebAccess", "seventeenPlus", "lootBox"]


def build_attrs():
    attrs = {k: "NONE" for k in NONE_LEVELS}
    attrs.update({k: False for k in FALSE_FLAGS})
    return attrs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    args = ap.parse_args()

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    version = next((v for v in vers.get("data", [])
                    if v["attributes"].get("platform") == "IOS"
                    and v["attributes"].get("appStoreState") in EDITABLE_STATES), None)
    if version is None:
        fail("No editable iOS version.")
    vid = version["id"]
    print(f"App: {app_name} → version {version['attributes'].get('versionString')} ({vid})")

    status, data = api("GET", f"/v1/appStoreVersions/{vid}/ageRatingDeclaration", token)
    print(f"\nGET ageRatingDeclaration → HTTP {status}")
    print(json.dumps(data, indent=2)[:1200])

    attrs = build_attrs()
    if status == 200 and data.get("data"):
        rid = data["data"]["id"]
        s, r = api("PATCH", f"/v1/ageRatingDeclarations/{rid}", token, body={
            "data": {"type": "ageRatingDeclarations", "id": rid, "attributes": attrs}})
    else:
        s, r = api("POST", "/v1/ageRatingDeclarations", token, body={
            "data": {"type": "ageRatingDeclarations", "attributes": attrs,
                     "relationships": {"appStoreVersion":
                                       {"data": {"type": "appStoreVersions", "id": vid}}}}})
    if s in (200, 201):
        print("\n✅ Age rating set to 4+ (all categories None).")
    else:
        print(f"\n❌ Set failed (HTTP {s}): {first_error_detail(r)}")
        print(json.dumps(r, indent=2)[:1500])


if __name__ == "__main__":
    main()
