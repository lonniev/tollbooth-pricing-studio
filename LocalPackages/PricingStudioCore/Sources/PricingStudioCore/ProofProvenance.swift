import Foundation

/// Trust evaluation for the Operator provenance attestation embedded in a
/// Secure-Courier request DM.
///
/// A proof-request DM is *delivered* from a key other than the Operator's own
/// npub in the self-addressed case (relays drop self-addressed DMs), so the
/// human is shown an unfamiliar sender with no inherent tie to the Operator.
/// The Operator therefore signs — with its **registered** identity key — a
/// kind-27235 attestation, embedded in the DM body, binding the delivery key,
/// subject, service, and one-time challenge (see the SDK's
/// `identity_proof.create_provenance_attestation`).
///
/// This module is **pure and host-free**: it parses the attestation and decides
/// the trust state, but delegates the Schnorr signature check to an injected
/// validator (backed by `DPYCAuthKit.verifyEventSignature` in the app, or a
/// stub in tests) so `PricingStudioCore` keeps zero crypto dependencies.
public enum ProofProvenance {

    // MARK: - Wire constants (must match the SDK)

    /// NIP-98 kind repurposed for DPYC identity proofs / attestations.
    public static let attestationKind = 27235
    /// `u`-tag sentinel marking a kind-27235 event as a provenance attestation.
    public static let attestationTool = "npub_proof_request"

    // MARK: - Parsed event

    /// The minimal, decoded shape of an attestation event. The injected
    /// signature validator receives this to verify the Schnorr signature.
    public struct AttestationEvent: Sendable, Equatable, Decodable {
        public let id: String
        public let pubkey: String
        public let created_at: Int
        public let kind: Int
        public let tags: [[String]]
        public let content: String
        public let sig: String

        public init(id: String, pubkey: String, created_at: Int, kind: Int, tags: [[String]], content: String, sig: String) {
            self.id = id
            self.pubkey = pubkey
            self.created_at = created_at
            self.kind = kind
            self.tags = tags
            self.content = content
            self.sig = sig
        }

        /// First value of the first tag named `name`, if any.
        public func tag(_ name: String) -> String? {
            for tag in tags where tag.count >= 2 && tag[0] == name { return tag[1] }
            return nil
        }
    }

    /// Decode raw attestation JSON into an `AttestationEvent` (nil if malformed).
    public static func parse(_ json: String) -> AttestationEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttestationEvent.self, from: data)
    }

    // MARK: - Verification

    public struct Verification: Sendable, Equatable {
        public enum Reason: String, Sendable {
            case ok, absent, malformed, badSignature, wrongKind
            case notAttestation, senderMismatch, subjectMismatch, challengeMismatch
        }
        public let valid: Bool
        /// The recovered signer pubkey (hex) whenever the signature verified —
        /// the seam the caller resolves against the registry — even if a bound
        /// field then mismatched. `nil` when the signature itself did not verify.
        public let signerPubkeyHex: String?
        public let reason: Reason

        public init(valid: Bool, signerPubkeyHex: String?, reason: Reason) {
            self.valid = valid
            self.signerPubkeyHex = signerPubkeyHex
            self.reason = reason
        }
    }

    /// Cryptographically verify an attestation against what the recipient saw.
    ///
    /// Mirrors the SDK's `verify_provenance_attestation`: confirms the signature
    /// (via `signatureValidator`), the kind and `u`-tag, and that each bound
    /// fact matches the DM the recipient received — so an attestation cannot be
    /// lifted onto a DM from a different delivery key nor replayed against
    /// another exchange. No freshness gate / no replay consumption (an inbound,
    /// idempotently-readable fact a human may verify long after arrival).
    ///
    /// - Parameter attestationJSON: raw JSON, or `nil` when the DM carried none
    ///   (→ `.absent`, which the assessment renders amber, never green).
    /// - Parameter signatureValidator: returns `true` iff the event's Schnorr
    ///   signature and id integrity verify. Injected to keep Core crypto-free.
    public static func verify(
        attestationJSON: String?,
        expectedSenderPubkeyHex: String,
        expectedSubjectNpub: String,
        expectedChallenge: String,
        signatureValidator: (AttestationEvent) -> Bool
    ) -> Verification {
        guard let json = attestationJSON, !json.isEmpty else {
            return Verification(valid: false, signerPubkeyHex: nil, reason: .absent)
        }
        guard let event = parse(json) else {
            return Verification(valid: false, signerPubkeyHex: nil, reason: .malformed)
        }
        guard signatureValidator(event) else {
            return Verification(valid: false, signerPubkeyHex: nil, reason: .badSignature)
        }
        // Signature valid — the signer is now trustworthy to resolve, even if a
        // bound field mismatches below.
        let signer = event.pubkey
        guard event.kind == attestationKind else {
            return Verification(valid: false, signerPubkeyHex: signer, reason: .wrongKind)
        }
        guard event.tag("u") == attestationTool else {
            return Verification(valid: false, signerPubkeyHex: signer, reason: .notAttestation)
        }
        guard event.tag("sender") == expectedSenderPubkeyHex else {
            return Verification(valid: false, signerPubkeyHex: signer, reason: .senderMismatch)
        }
        guard event.tag("subject") == expectedSubjectNpub else {
            return Verification(valid: false, signerPubkeyHex: signer, reason: .subjectMismatch)
        }
        guard event.tag("challenge") == expectedChallenge else {
            return Verification(valid: false, signerPubkeyHex: signer, reason: .challengeMismatch)
        }
        return Verification(valid: true, signerPubkeyHex: signer, reason: .ok)
    }

    // MARK: - Registry resolution

    /// How the verified signer resolves against known/registered operators.
    /// The community-registry fetch (arbitrary operators, certificate window)
    /// is a follow-up; today `resolveAgainstKnownOperators` covers the
    /// self-proof and known-operator cases, and everything else is `.unresolved`
    /// (fail closed → red).
    public enum RegistryResolution: String, Sendable, Equatable {
        case registeredCertified
        case registeredNovel
        case unresolved
    }

    /// Resolve a verified signer against the set of operator identities this
    /// device already knows (its own actor npubs, plus any adopted operators).
    /// A signer the device holds is a registered, certified operator; anything
    /// else is unresolved until the registry fetch lands.
    public static func resolveAgainstKnownOperators(
        signerPubkeyHex: String?,
        knownOperatorPubkeyHexes: Set<String>
    ) -> RegistryResolution {
        guard let signer = signerPubkeyHex else { return .unresolved }
        return knownOperatorPubkeyHexes.contains(signer) ? .registeredCertified : .unresolved
    }

    // MARK: - Trust assessment

    public enum TrustLevel: String, Sendable, Equatable { case green, amber, red }

    public struct TrustAssessment: Sendable, Equatable {
        public let level: TrustLevel
        /// The resolved, **verified** operator identity to show the human as
        /// trustworthy. **Nil on red** — a red state must never render an
        /// identity as verified, because displaying an unearned name as
        /// trusted is the failure the green/amber/red verdict closes.
        public let resolvedIdentity: String?
        /// A claim the request asserts about itself that the protocol has **not**
        /// endorsed — surfaced only so the human can *see* it and judge, never
        /// rendered as trusted. Populated for the unknown-signer red case (a
        /// validly-signed attestation whose key is not in the registry): hiding
        /// the claim there denies the classifier the one fact that exposes an
        /// impostor claiming a name they recognize (issue #105 / origin
        /// excalibur-mcp#243). Nil whenever there is no cryptographically-bound
        /// claim to show (absent / failed-verification) or the identity is
        /// verified (green/amber, where `resolvedIdentity` carries it).
        public let claimedIdentity: String?
        public let headline: String
        public let detail: String

        public init(level: TrustLevel, resolvedIdentity: String?, claimedIdentity: String? = nil, headline: String, detail: String) {
            self.level = level
            self.resolvedIdentity = resolvedIdentity
            self.claimedIdentity = claimedIdentity
            self.headline = headline
            self.detail = detail
        }
    }

    /// Decide the trust state from a completed verification and registry
    /// resolution. Fail-closed: an invalid-but-present attestation, or a valid
    /// one whose signer does not resolve, is **red** and never renders an
    /// identity as *verified*; an absent attestation is **amber** (legacy,
    /// never green). A validly-signed-but-unknown signer additionally surfaces
    /// its `claimedService` as an explicitly-unverified `claimedIdentity` so the
    /// human can catch an impostor — see `TrustAssessment.claimedIdentity`.
    ///
    /// - Parameter resolvedOperatorName: human-readable name for the *verified*
    ///   signer, shown only in green/amber. Never a requester-supplied value.
    /// - Parameter claimedService: the requester-asserted service string. Phrases
    ///   the amber "unverified" caption, and is surfaced (labelled unverified) as
    ///   the `claimedIdentity` on the unknown-signer red case; never rendered as
    ///   a verified identity.
    public static func assess(
        verification: Verification,
        resolution: RegistryResolution,
        hasPriorHistory: Bool,
        resolvedOperatorName: String?,
        claimedService: String?
    ) -> TrustAssessment {
        // Absent envelope → amber (legacy coexistence during rollout).
        if verification.reason == .absent {
            return TrustAssessment(
                level: .amber,
                resolvedIdentity: nil,
                headline: "Unverified request",
                detail: "This request carries no operator attestation, so its origin can't be confirmed. Approve only if you initiated it."
            )
        }
        // Present but not valid → red, suppress any claimed identity.
        guard verification.valid else {
            return TrustAssessment(
                level: .red,
                resolvedIdentity: nil,
                headline: "Do not trust this request",
                detail: "The attestation failed verification (\(verification.reason.rawValue)). Its claimed identity is suppressed. Do not approve."
            )
        }
        switch resolution {
        case .unresolved:
            // Validly signed, but by a key that is not a known operator. The
            // signature *did* verify, so `claimedService` is cryptographically
            // bound to this specific key — show it, plainly labelled unverified,
            // rather than hiding it. This is exactly the case where the human
            // classifier needs the claim: seeing an impostor assert a name they
            // recognise, from a key they don't, is what exposes impersonation
            // (issue #105 / origin excalibur-mcp#243). Still red, still
            // do-not-approve, and `resolvedIdentity` stays nil so nothing is
            // rendered as verified.
            return TrustAssessment(
                level: .red,
                resolvedIdentity: nil,
                claimedIdentity: claimedService,
                headline: "Unknown requester",
                detail: "This request is validly signed, but the signer is not a known operator in your registry. Its claimed identity is shown below unverified — do not approve unless you can independently confirm it."
            )
        case .registeredNovel:
            return TrustAssessment(
                level: .amber,
                resolvedIdentity: resolvedOperatorName,
                headline: "First contact",
                detail: "Verified as \(resolvedOperatorName ?? "a registered operator"), but this is the first request from this key. Confirm you expected it."
            )
        case .registeredCertified:
            if hasPriorHistory {
                return TrustAssessment(
                    level: .green,
                    resolvedIdentity: resolvedOperatorName,
                    headline: "Verified operator",
                    detail: "Verified as \(resolvedOperatorName ?? "your registered operator"), with prior session history."
                )
            }
            return TrustAssessment(
                level: .amber,
                resolvedIdentity: resolvedOperatorName,
                headline: "First contact",
                detail: "Verified as \(resolvedOperatorName ?? "a registered operator"), but this is the first request from this key. Confirm you expected it."
            )
        }
    }

    /// End-to-end convenience: verify, resolve against known operators, and
    /// assess — the path the approval UI uses. `hasPriorHistory` is inferred
    /// from whether the verified signer is among `priorContactPubkeyHexes`.
    public static func assess(
        attestationJSON: String?,
        expectedSenderPubkeyHex: String,
        expectedSubjectNpub: String,
        expectedChallenge: String,
        knownOperatorPubkeyHexes: Set<String>,
        priorContactPubkeyHexes: Set<String>,
        resolvedOperatorName: String?,
        claimedService: String?,
        signatureValidator: (AttestationEvent) -> Bool
    ) -> TrustAssessment {
        let verification = verify(
            attestationJSON: attestationJSON,
            expectedSenderPubkeyHex: expectedSenderPubkeyHex,
            expectedSubjectNpub: expectedSubjectNpub,
            expectedChallenge: expectedChallenge,
            signatureValidator: signatureValidator
        )
        let resolution = resolveAgainstKnownOperators(
            signerPubkeyHex: verification.signerPubkeyHex,
            knownOperatorPubkeyHexes: knownOperatorPubkeyHexes
        )
        let hasPrior = verification.signerPubkeyHex.map(priorContactPubkeyHexes.contains) ?? false
        return assess(
            verification: verification,
            resolution: resolution,
            hasPriorHistory: hasPrior,
            resolvedOperatorName: resolvedOperatorName,
            claimedService: claimedService
        )
    }
}
