#!/usr/bin/env python3
"""Upload App Store screenshots via the App Store Connect API.

For each PNG in --dir (sorted by name), performs the ASC upload dance:
  1. ensure an appScreenshotSet for the display type (deletes any existing
     set of that type first, so re-runs replace rather than duplicate)
  2. reserve an appScreenshot (returns chunked uploadOperations)
  3. PUT the file bytes to each operation
  4. commit with uploaded=true + the file's MD5 checksum
Finally, orders the set to match filename order.

Default display type APP_IPAD_PRO_3GEN_129 covers the 12.9"/13" iPad Pro
slot, which accepts 2732×2048 or 2752×2064 landscape.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import os
import urllib.error
import urllib.request

from asc_common import api, fail, first_error_detail, make_token, resolve_app

EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}


def put_bytes(op, chunk: bytes) -> None:
    req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
    for h in op.get("requestHeaders", []):
        req.add_header(h["name"], h["value"])
    with urllib.request.urlopen(req) as resp:
        if resp.status not in (200, 201, 204):
            raise RuntimeError(f"upload chunk HTTP {resp.status}")


def upload_one(token, set_id, path):
    name = os.path.basename(path)
    data = open(path, "rb").read()
    # 1) reserve
    status, res = api("POST", "/v1/appScreenshots", token, body={
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileName": name, "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
        }
    })
    if status not in (200, 201):
        fail(f"reserve {name} failed (HTTP {status}): {first_error_detail(res)}", res)
    shot = res["data"]
    shot_id = shot["id"]
    # 2) upload chunks
    for op in shot["attributes"]["uploadOperations"]:
        off, length = op["offset"], op["length"]
        put_bytes(op, data[off:off + length])
    # 3) commit
    checksum = hashlib.md5(data).hexdigest()
    status, res = api("PATCH", f"/v1/appScreenshots/{shot_id}", token, body={
        "data": {"type": "appScreenshots", "id": shot_id,
                 "attributes": {"uploaded": True, "sourceFileChecksum": checksum}},
    })
    if status not in (200, 201):
        fail(f"commit {name} failed (HTTP {status}): {first_error_detail(res)}", res)
    print(f"  ✅ {name}")
    return shot_id


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--display-type", default="APP_IPAD_PRO_3GEN_129")
    ap.add_argument("--locale", default="en-US")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "*.png")))
    if not files:
        fail(f"No PNGs in {args.dir}")
    print(f"{len(files)} screenshot(s): " + ", ".join(os.path.basename(f) for f in files))

    token = make_token()
    app_id, app_name = resolve_app(token, args.bundle_id)
    print(f"App: {app_name} → id {app_id}")

    # editable version → its localization for the locale
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions", token, query={
        "limit": "10", "fields[appStoreVersions]": "versionString,appStoreState,platform"})[1]
    version = next((v for v in vers.get("data", [])
                    if v["attributes"].get("platform") == "IOS"
                    and v["attributes"].get("appStoreState") in EDITABLE_STATES), None)
    if version is None:
        fail("No editable iOS version.")
    vid = version["id"]
    vlocs = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", token,
                query={"fields[appStoreVersionLocalizations]": "locale"})[1]
    loc = next((l for l in vlocs.get("data", [])
                if l["attributes"].get("locale") == args.locale), None) \
        or (vlocs.get("data") or [None])[0]
    if loc is None:
        fail("No appStoreVersionLocalization found.")
    loc_id = loc["id"]
    print(f"Localization: {loc['attributes'].get('locale')} → id {loc_id}")

    # delete any existing set for this display type (replace on re-run)
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets", token,
               query={"fields[appScreenshotSets]": "screenshotDisplayType"})[1]
    for s in sets.get("data", []):
        if s["attributes"].get("screenshotDisplayType") == args.display_type:
            api("DELETE", f"/v1/appScreenshotSets/{s['id']}", token)
            print(f"Removed existing {args.display_type} set.")

    # create the set
    status, res = api("POST", "/v1/appScreenshotSets", token, body={
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": args.display_type},
            "relationships": {"appStoreVersionLocalization":
                              {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}},
        }
    })
    if status not in (200, 201):
        fail(f"create set failed (HTTP {status}): {first_error_detail(res)}", res)
    set_id = res["data"]["id"]
    print(f"Set {args.display_type} → id {set_id}\nUploading:")

    ordered = [upload_one(token, set_id, f) for f in files]

    # order the set to match filename order
    api("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots", token,
        body={"data": [{"type": "appScreenshots", "id": i} for i in ordered]})
    print(f"\n✅ Uploaded {len(ordered)} screenshot(s) in order.")


if __name__ == "__main__":
    main()
