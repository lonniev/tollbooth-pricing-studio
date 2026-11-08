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
# Required boolean questions that start out null on an existing declaration.
DECLARED_NO = ["socialMedia"]


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
    print(f"App: {app_name} → id {app_id}")

    # Age rating moved to app scope; the declaration hangs off the appInfo (or
    # the app). Find whichever path returns it.
    # An update has two appInfos: the live one (READY_FOR_SALE, locked) and the
    # one riding the new version. Only the latter's declaration is editable.
    infos = api("GET", f"/v1/apps/{app_id}/appInfos", token)[1]["data"]
    infos.sort(key=lambda i: i["attributes"].get("appStoreState") == "READY_FOR_SALE")
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "appStoreState,platform"})[1]["data"]
    editable = [v["id"] for v in vers
                if v["attributes"].get("platform") == "IOS"
                and v["attributes"].get("appStoreState") in EDITABLE_STATES]
    paths = [f"/v1/appInfos/{i['id']}/ageRatingDeclaration" for i in infos]
    paths += [f"/v1/appStoreVersions/{vid}/ageRatingDeclaration" for vid in editable]
    paths.append(f"/v1/apps/{app_id}/ageRatingDeclaration")
    decl = None
    for path in paths:
        status, data = api("GET", path, token)
        print(f"GET {path} → HTTP {status}")
        if status == 200 and data.get("data"):
            decl = data["data"]
            break
    if decl is None:
        fail("Could not locate the ageRatingDeclaration to update.")

    print("\nCurrent declaration attributes:")
    print(json.dumps(decl.get("attributes", {}), indent=2)[:1500])

    # Derive a lowest-rating patch from the declaration's own fields: string
    # categories → NONE, booleans → False, leave nulls (e.g. kidsAgeBand) alone.
    # 'ageRatingOverride' is deprecated and conflicts with 'ageRatingOverrideV2'.
    skip = {"ageRatingOverride"}
    attrs = {}
    for k, v in decl.get("attributes", {}).items():
        if k in skip:
            continue
        if isinstance(v, bool):
            attrs[k] = False
        elif isinstance(v, str):
            attrs[k] = "NONE"
    # Questions Apple added after the declaration was first written come back
    # null, and the API then refuses the version until they are answered.
    # Studio is a pricing and payments tool, so each answer is no.
    for k in DECLARED_NO:
        if decl.get("attributes", {}).get(k) is None:
            attrs[k] = False
    rid = decl["id"]
    s, r = api("PATCH", f"/v1/ageRatingDeclarations/{rid}", token, body={
        "data": {"type": "ageRatingDeclarations", "id": rid, "attributes": attrs}})
    if s in (200, 201):
        print("\n✅ Age rating set to 4+ (all categories None).")
    else:
        print(f"\n❌ Set failed (HTTP {s}): {first_error_detail(r)}")
        print(json.dumps(r, indent=2)[:1500])


if __name__ == "__main__":
    main()
