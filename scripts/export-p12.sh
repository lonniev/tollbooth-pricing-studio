#!/bin/bash
# Export an Apple Distribution .p12 from a .cer file + the private key already in your Keychain.
#
# Usage: ./scripts/export-p12.sh /path/to/distribution.cer
#
# What this does:
#   1. Imports the .cer into your login keychain
#   2. Finds the matching signing identity (cert + private key)
#   3. Exports the pair as a .p12 file

set -euo pipefail

CER="${1:?Usage: $0 /path/to/distribution.cer}"
P12_OUT="${CER%.cer}.p12"

if [ ! -f "$CER" ]; then
    echo "ERROR: File not found: $CER"
    exit 1
fi

echo "==> Importing $CER into login keychain..."
security import "$CER" -k ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo ""
echo "==> Distribution signing identities in your keychain:"
echo ""
security find-identity -v -p codesigning | grep -i "apple distribution\|iPhone Distribution" || {
    echo "No Apple Distribution identity found."
    echo "The .cer may not match a private key in this keychain."
    echo "Did you generate the CSR on this Mac?"
    exit 1
}

echo ""
echo "==> Now exporting .p12 via Keychain Access (GUI required)..."
echo ""
echo "   Keychain Access will open. Do this:"
echo ""
echo "   1. In the sidebar, click 'login' keychain, then 'My Certificates' category"
echo "   2. Find 'Apple Distribution: lonniev@gmail.com' (it should show a disclosure"
echo "      triangle with your private key underneath)"
echo "   3. Right-click the CERTIFICATE (not the key) → 'Export...'"
echo "   4. Format: Personal Information Exchange (.p12)"
echo "   5. Save to: $P12_OUT"
echo "   6. Set a passphrase (you'll need it for the GHA secret)"
echo ""

open -a "Keychain Access"

echo "Waiting for you to save $P12_OUT ..."
echo "(Press Ctrl-C if you want to do this later)"
echo ""

while [ ! -f "$P12_OUT" ]; do
    sleep 2
done

echo "==> Found $P12_OUT ($(wc -c < "$P12_OUT" | tr -d ' ') bytes)"
echo ""
echo "Now run:"
echo ""
echo "  python3 scripts/gen-gha-secrets.py \\"
echo "    --p12 $P12_OUT \\"
echo "    --profile /path/to/PricingStudio_AppStore.mobileprovision \\"
echo "    --p8 /path/to/AuthKey_XXXXXXXXXX.p8 \\"
echo "    --p12-password 'your passphrase' \\"
echo "    --key-id XXXXXXXXXX \\"
echo "    --issuer-id 'your-issuer-uuid'"
