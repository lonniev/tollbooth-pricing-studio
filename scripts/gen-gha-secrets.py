#!/usr/bin/env python3
"""
Generate the GitHub Actions secrets table for the pricing-studio release workflow.

Usage:
    python3 scripts/gen-gha-secrets.py \
        --p12 ~/path/to/Certificates.p12 \
        --profile ~/path/to/PricingStudio_AppStore.mobileprovision \
        --p8 ~/path/to/AuthKey_XXXXXXXXXX.p8 \
        --p12-password "your passphrase" \
        --team-id JHPQNMW73Z \
        --key-id XXXXXXXXXX \
        --issuer-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

Outputs a table of secret names and values ready to paste into GitHub Settings,
plus a `gh secret set` script you can pipe to bash.
"""

import argparse
import base64
import sys
from pathlib import Path


def b64_file(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def main():
    parser = argparse.ArgumentParser(description="Generate GHA secrets from Apple signing assets")
    parser.add_argument("--p12", required=True, type=Path, help="Path to .p12 distribution certificate")
    parser.add_argument("--profile", required=True, type=Path, help="Path to .mobileprovision file")
    parser.add_argument("--p8", required=True, type=Path, help="Path to App Store Connect .p8 API key")
    parser.add_argument("--p12-password", required=True, help="Passphrase for the .p12 file")
    parser.add_argument("--team-id", default="JHPQNMW73Z", help="Apple Developer Team ID")
    parser.add_argument("--key-id", required=True, help="App Store Connect API Key ID (10 chars)")
    parser.add_argument("--issuer-id", required=True, help="App Store Connect Issuer ID (UUID)")
    parser.add_argument("--repo", default="lonniev/tollbooth-pricing-studio", help="GitHub repo for gh commands")
    args = parser.parse_args()

    for path, label in [(args.p12, ".p12"), (args.profile, ".mobileprovision"), (args.p8, ".p8")]:
        if not path.exists():
            print(f"ERROR: {label} file not found: {path}", file=sys.stderr)
            sys.exit(1)

    secrets = {
        "DISTRIBUTION_CERT_P12_BASE64": b64_file(args.p12),
        "DISTRIBUTION_CERT_PASSWORD": args.p12_password,
        "PROVISIONING_PROFILE_BASE64": b64_file(args.profile),
        "APPLE_TEAM_ID": args.team_id,
        "ASC_KEY_ID": args.key_id,
        "ASC_ISSUER_ID": args.issuer_id,
        "ASC_PRIVATE_KEY_BASE64": b64_file(args.p8),
    }

    # Table output
    print("=" * 72)
    print("GitHub Actions Secrets — paste into repo Settings > Secrets > Actions")
    print("=" * 72)
    for name, value in secrets.items():
        preview = value if len(value) < 60 else value[:40] + "..." + f" ({len(value)} chars)"
        print(f"\n  {name}")
        print(f"  {preview}")
    print("\n" + "=" * 72)

    # gh CLI script
    print("\n# -- Or run this to set all secrets via gh CLI: --\n")
    for name, value in secrets.items():
        safe = value.replace("'", "'\\''")
        print(f"echo '{safe}' | gh secret set {name} --repo {args.repo}")

    print(f"\n# Verify:")
    print(f"gh secret list --repo {args.repo}")


if __name__ == "__main__":
    main()
