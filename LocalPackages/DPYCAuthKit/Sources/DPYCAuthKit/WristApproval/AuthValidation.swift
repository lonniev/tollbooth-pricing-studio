import Foundation

// MARK: - Errors

public enum AuthError: Error, Equatable {
    case kindMismatch(expected: Int, got: Int)
    case typeMismatch(String)
    case unsupportedVersion(Int)
    case expired
    case unknownChoice(String)
    case requestIdMismatch
    case dpopTokenMismatch
    case nonceMismatch
    case malformedContent
}

// MARK: - Request-Side Validation

public extension AuthRequest {

    /// Hard wall-clock expiry: a stale notification tapped later must not grant.
    func isExpired(now: Date = Date()) -> Bool {
        Int(now.timeIntervalSince1970) >= expiresAt
    }

    /// Look up an authored offer by id.
    func offer(id: String) -> AuthOffer? {
        offers.first { $0.id == id }
    }

    /// A valid choice names an authored offer or is the explicit reject.
    func isValidChoice(_ choice: String) -> Bool {
        choice == AuthResponse.rejectChoice || offer(id: choice) != nil
    }

    /// Validate a response against this request (Operator side).
    ///
    /// Checks the request-id, dpop_token, and nonce echoes, the hard expiry,
    /// and that the choice names an authored offer — a response cannot grant
    /// anything that was not offered. Returns the granted offer, or nil for
    /// an explicit reject. Nonce single-use bookkeeping is the caller's:
    /// this validates the echo, not whether the nonce was already consumed.
    func validate(_ response: AuthResponse, now: Date = Date()) throws -> AuthOffer? {
        guard response.requestId == requestId else {
            throw AuthError.requestIdMismatch
        }
        guard response.dpopToken == dpopToken else {
            throw AuthError.dpopTokenMismatch
        }
        guard response.nonce == nonce else {
            throw AuthError.nonceMismatch
        }
        guard !isExpired(now: now) else {
            throw AuthError.expired
        }
        if response.isRejection {
            return nil
        }
        guard let granted = offer(id: response.choice) else {
            throw AuthError.unknownChoice(response.choice)
        }
        return granted
    }
}
