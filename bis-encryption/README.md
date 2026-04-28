# BIS Encryption Export Compliance

US Bureau of Industry and Security filings for Tollbooth Pricing Studio.

## Filings

### 1. Initial TSU Notification (one-time)

**File:** `01-initial-notification.txt`
**Send to:** `crypt@bis.doc.gov` and `enc@nsa.gov`
**When:** Before first export (App Store publication)
**Basis:** 15 CFR 742.15(b), License Exception TSU for publicly available encryption source code

### 2. Annual Self-Classification Report

**File:** `02-self-classification-report.csv`
**Send to:** `crypt-Supp8@bis.doc.gov` and `enc@nsa.gov`
**When:** By February 1 each year for items exported in the prior calendar year
**Basis:** 15 CFR 742.15(b)(2), Supplement No. 8 to Part 742

## Classification

- **ECCN:** 5D002 (software using or performing cryptographic functions)
- **Authorization Type:** MMKT (mass market)
- **License Exception:** TSU (Technology and Software Unrestricted) for publicly available source code

## Crypto Inventory

| Algorithm | Standard | Purpose |
|-----------|----------|---------|
| AES-256-CBC | NIP-04 | Nostr DM encryption |
| ChaCha20 + HMAC-SHA256 | NIP-44v2 | Nostr gift-wrap encryption |
| Schnorr Signatures | BIP-340 | Nostr event signing |
| ECDH | secp256k1 | Shared secret derivation |
| HKDF-SHA256 | RFC 5869 | Key derivation |
| TLS 1.2/1.3 | Standard | HTTPS transport |
