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

    /// green = verified & known; amber = verified but first-contact / no
    /// attestation; **ephemeral** = validly signed by a one-time key that isn't
    /// a registered operator (the expected self-DM login case — trust rests on
    /// the Device-Grant code match, not registry membership, so it's a *caution*
    /// (purple), not a rejection); red = the signature itself failed → do not
    /// trust.
    public enum TrustLevel: String, Sendable, Equatable { case green, amber, ephemeral, red }

    /// The raw, signature-bound facts the verdict was computed from — the
    /// "show your work" disclosure. Present on every *validly-signed*
    /// attestation so the human can audit *how* the code decided, not just
    /// what it decided. Nil on absent/failed verification (nothing bound to
    /// disclose). None of these are endorsements; they are the inputs.
    public struct DecisionFacts: Sendable, Equatable {
        /// The key that signed the attestation (the operator's registered
        /// identity when it verifies).
        public let signerPubkeyHex: String?
        /// The key that actually *delivered* the DM — a one-time delivery key
        /// in the self-addressed case, equal to the signer otherwise.
        public let deliverySenderPubkeyHex: String
        /// True when delivery key ≠ signer (the DM was relayed via a throwaway
        /// key the operator vouches for).
        public let viaDeliveryKey: Bool
        /// The subject whose proof the request seeks (the recipient's npub).
        public let subjectNpub: String
        /// The one-time challenge / dpop code bound into the signature.
        public let challenge: String
        /// The verification outcome (`ok`, `senderMismatch`, `absent`, …).
        public let verificationReason: String

        public init(signerPubkeyHex: String?, deliverySenderPubkeyHex: String, viaDeliveryKey: Bool, subjectNpub: String, challenge: String, verificationReason: String) {
            self.signerPubkeyHex = signerPubkeyHex
            self.deliverySenderPubkeyHex = deliverySenderPubkeyHex
            self.viaDeliveryKey = viaDeliveryKey
            self.subjectNpub = subjectNpub
            self.challenge = challenge
            self.verificationReason = verificationReason
        }
    }

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
        /// The Operator's stated, **signature-bound** purpose for the request
        /// (the `reason` tag on the attestation) — "I'm working on your request
        /// XYZ and need the Operator to do ABC for you." Present only on a
        /// *validly-signed* attestation that carried one, so it is safe to show
        /// as *what the signer said* (never as an endorsement). It is the fact
        /// that makes a stranger's ask judgeable: the unknown-signer case shows
        /// a claimed identity **and** why it's reaching out. Nil when the
        /// attestation is absent/invalid or carried no reason.
        public let reason: String?
        /// The operator-**observed** provenance of the client that triggered the
        /// request — a compact "geo · coarse-ip · client" string signed into the
        /// attestation's `origin` tag (server-side transport data, never client
        /// self-report). Lets the human judge an *unsolicited* request by where
        /// it came from, not only who signed it. Nil when absent/unverified or
        /// the transport exposed nothing (best-effort).
        public let origin: String?
        /// The place the requesting agent stated it *already showed this code*
        /// to the human — the OAuth 2.0 Device Authorization Grant
        /// `verification_uri` (RFC 8628), carried in the attestation's
        /// `verify_at` tag. It is the human's cross-check anchor: approve only
        /// if the code in this DM matches the code shown at this venue. It is
        /// **self-reported, not a trust root** — its power is that an impostor
        /// cannot make the human's *own* legitimate surface display the
        /// attacker's code, so an unfamiliar or unreachable venue fails safe
        /// (can't find the code → don't approve). Free-form: often a URL, but
        /// may name a conversation or app. Nil when absent/unverified.
        public let verifyAt: String?
        /// The signature-bound inputs the verdict was derived from — the
        /// auditable "how it was decided" disclosure. Nil on absent/failed
        /// verification.
        public let decisionFacts: DecisionFacts?
        public let headline: String
        public let detail: String

        public init(level: TrustLevel, resolvedIdentity: String?, claimedIdentity: String? = nil, reason: String? = nil, origin: String? = nil, verifyAt: String? = nil, decisionFacts: DecisionFacts? = nil, headline: String, detail: String) {
            self.level = level
            self.resolvedIdentity = resolvedIdentity
            self.claimedIdentity = claimedIdentity
            self.reason = reason
            self.origin = origin
            self.verifyAt = verifyAt
            self.decisionFacts = decisionFacts
            self.headline = headline
            self.detail = detail
        }

        /// Return a copy carrying the given decision facts — used by the
        /// convenience `assess` to attach the audit inputs after the verdict
        /// branches have run, without threading them through every branch.
        public func with(decisionFacts: DecisionFacts?) -> TrustAssessment {
            TrustAssessment(
                level: level, resolvedIdentity: resolvedIdentity, claimedIdentity: claimedIdentity,
                reason: reason, origin: origin, verifyAt: verifyAt, decisionFacts: decisionFacts,
                headline: headline, detail: detail
            )
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
    /// - Parameter viaDeliveryKey: true when the DM was *delivered* from a
    ///   one-time key distinct from the attestation signer (the self-addressed
    ///   case — relays drop self-DMs, so the operator delivers from a throwaway
    ///   key and vouches for it with the attestation). The verdict must then say
    ///   the operator *attested* the request, never that the operator *is* the
    ///   sender — the visible sender npub is the temporary key, not the operator.
    public static func assess(
        verification: Verification,
        resolution: RegistryResolution,
        hasPriorHistory: Bool,
        resolvedOperatorName: String?,
        claimedService: String?,
        reason: String? = nil,
        origin: String? = nil,
        verifyAt: String? = nil,
        viaDeliveryKey: Bool = false
    ) -> TrustAssessment {
        // The reason, origin, and verify_at are only trustworthy once the
        // signature verifies; a failed/absent attestation carries no bound
        // tags to show.
        let signedReason = verification.valid ? reason : nil
        let signedOrigin = verification.valid ? origin : nil
        let signedVerifyAt = verification.valid ? verifyAt : nil
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
            // Validly signed by a one-time key that is not a registered
            // operator. This is the *expected* shape of a self-DM login (the
            // browser has no operator key, so it delivers from an ephemeral
            // one) — not an alarm. Trust does not come from registry membership
            // here; it comes from the Device-Grant code match (verifyAt). So
            // this is a caution (purple), not a rejection (red): the human
            // confirms the code matches where they started, and if they can't,
            // they don't approve. We do NOT surface `claimedService` as a
            // "claimed identity" — for a proof request it is only the request
            // type ("npub_ownership"), and dressing it as an impersonated name
            // is the confusing noise; the signed `reason` carries the real why.
            return TrustAssessment(
                level: .ephemeral,
                resolvedIdentity: nil,
                reason: signedReason,
                origin: signedOrigin,
                verifyAt: signedVerifyAt,
                headline: "Ephemeral Identity",
                detail: "A one-time key signed this — expected when you start a login from a browser, which has no standing identity. Confirm the code matches where you began; if you can't find it, don't approve."
            )
        case .registeredNovel:
            let op = resolvedOperatorName ?? "a registered operator"
            return TrustAssessment(
                level: .amber,
                resolvedIdentity: resolvedOperatorName,
                reason: signedReason,
                origin: signedOrigin,
                verifyAt: signedVerifyAt,
                headline: "First contact",
                detail: viaDeliveryKey
                    ? "The operator vouched for this request with its registered signature, but sent it from a one-time delivery key, not its own npub. First request from this key — confirm you expected it."
                    : "Verified as \(op), but this is the first request from this key. Confirm you expected it."
            )
        case .registeredCertified:
            let op = resolvedOperatorName ?? "your registered operator"
            if hasPriorHistory {
                return TrustAssessment(
                    level: .green,
                    resolvedIdentity: resolvedOperatorName,
                    reason: signedReason,
                    origin: signedOrigin,
                    verifyAt: signedVerifyAt,
                    headline: viaDeliveryKey ? "Operator-attested" : "Verified operator",
                    detail: viaDeliveryKey
                        ? "The operator vouched for this request with its registered signature, but did not send it from its own npub — the visible sender is a one-time delivery key. Trust the signature, not the sender."
                        : "Verified as \(op), with prior session history."
                )
            }
            return TrustAssessment(
                level: .amber,
                resolvedIdentity: resolvedOperatorName,
                reason: signedReason,
                origin: signedOrigin,
                verifyAt: signedVerifyAt,
                headline: "First contact",
                detail: viaDeliveryKey
                    ? "The operator vouched for this request with its registered signature, but sent it from a one-time delivery key, not its own npub. First request from this key — confirm you expected it."
                    : "Verified as \(op), but this is the first request from this key. Confirm you expected it."
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
        // The signed purpose rides in the attestation's `reason` tag; read it
        // from the parsed event so it is taken from the signature-bound source,
        // not the (relay-mutable) plaintext DM body.
        let parsed = attestationJSON.flatMap(parse)
        let signedReason = parsed?.tag("reason")
        let signedOrigin = parsed?.tag("origin")
        // The Device-Grant verification venue — where the agent says it already
        // showed the human this code (RFC 8628). Read from the signature-bound
        // tag, not the relay-mutable DM body.
        let signedVerifyAt = parsed?.tag("verify_at")
        // A one-time delivery key was used when the verified signer (the
        // operator) is NOT the key that actually delivered the DM. In that case
        // the sender the human sees is a throwaway, not the operator, and the
        // verdict must say "attested by", never "sent by / is the operator".
        let viaDeliveryKey = verification.valid
            && verification.signerPubkeyHex != nil
            && verification.signerPubkeyHex?.lowercased() != expectedSenderPubkeyHex.lowercased()
        let assessment = assess(
            verification: verification,
            resolution: resolution,
            hasPriorHistory: hasPrior,
            resolvedOperatorName: resolvedOperatorName,
            claimedService: claimedService,
            reason: signedReason,
            origin: signedOrigin,
            verifyAt: signedVerifyAt,
            viaDeliveryKey: viaDeliveryKey
        )
        // Attach the auditable inputs on any validly-signed attestation so the
        // human can inspect *how* the verdict was reached. Absent/failed
        // verification binds nothing, so there is nothing honest to disclose.
        guard verification.valid else { return assessment }
        return assessment.with(decisionFacts: DecisionFacts(
            signerPubkeyHex: verification.signerPubkeyHex,
            deliverySenderPubkeyHex: expectedSenderPubkeyHex,
            viaDeliveryKey: viaDeliveryKey,
            subjectNpub: expectedSubjectNpub,
            challenge: expectedChallenge,
            verificationReason: verification.reason.rawValue
        ))
    }
}
