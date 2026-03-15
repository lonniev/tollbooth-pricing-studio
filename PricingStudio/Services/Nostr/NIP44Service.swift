import CryptoKit
import Foundation
import P256K

/// NIP-44v2 encryption: ECDH + HKDF + ChaCha20 stream cipher + HMAC-SHA256.
///
/// Payload format: `version(1) + nonce(32) + ciphertext(N) + hmac(32)`
/// Conversation key: `HMAC-SHA256(salt: "nip44-v2", key: ecdh_x)`
///
/// Reference: https://github.com/nostr-protocol/nips/blob/master/44.md
enum NIP44Service {

    // MARK: - Constants

    private static let version: UInt8 = 2
    private static let minPlaintextSize = 1
    private static let maxPlaintextSize = 65535

    // MARK: - Errors

    enum NIP44Error: LocalizedError {
        case invalidKey
        case ecdhFailed
        case encryptionFailed
        case decryptionFailed(String)
        case payloadTooShort
        case unsupportedVersion(UInt8)
        case hmacVerificationFailed
        case invalidPadding
        case plaintextTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Invalid key data"
            case .ecdhFailed: return "ECDH key agreement failed"
            case .encryptionFailed: return "ChaCha20 encryption failed"
            case .decryptionFailed(let msg): return "NIP-44 decryption failed: \(msg)"
            case .payloadTooShort: return "NIP-44 payload too short (min 99 bytes)"
            case .unsupportedVersion(let v): return "Unsupported NIP-44 version: \(v)"
            case .hmacVerificationFailed: return "NIP-44 HMAC verification failed"
            case .invalidPadding: return "NIP-44 padding invalid"
            case .plaintextTooLarge: return "Plaintext exceeds NIP-44 maximum (65535 bytes)"
            }
        }
    }

    // MARK: - Padding

    /// Calculate NIP-44v2 padded length using power-of-two bucket scheme.
    static func calcPaddedLen(_ unpaddedLen: Int) -> Int {
        if unpaddedLen <= 32 { return 32 }
        var nextPower = 1
        while nextPower < unpaddedLen { nextPower *= 2 }
        if nextPower <= 256 { return nextPower }
        let chunk = nextPower / 8
        return chunk * ((unpaddedLen + chunk - 1) / chunk)
    }

    /// Pad plaintext: 2-byte big-endian length prefix + zero-padding.
    static func pad(_ plaintext: Data) throws -> Data {
        let len = plaintext.count
        guard len >= minPlaintextSize, len <= maxPlaintextSize else {
            throw NIP44Error.plaintextTooLarge
        }
        let paddedLen = calcPaddedLen(len)
        var result = Data(capacity: 2 + paddedLen)
        result.append(UInt8(len >> 8))       // big-endian length prefix
        result.append(UInt8(len & 0xFF))
        result.append(plaintext)
        result.append(Data(count: paddedLen - len))  // zero padding
        return result
    }

    /// Remove NIP-44v2 padding: read 2-byte length, verify zeros.
    static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else { throw NIP44Error.invalidPadding }
        let len = Int(padded[0]) << 8 | Int(padded[1])
        guard len >= minPlaintextSize, len <= maxPlaintextSize else {
            throw NIP44Error.invalidPadding
        }
        guard 2 + len <= padded.count else { throw NIP44Error.invalidPadding }
        // Verify padding is all zeros
        let tail = padded[(2 + len)...]
        guard tail.allSatisfy({ $0 == 0 }) else { throw NIP44Error.invalidPadding }
        return padded[2..<(2 + len)]
    }

    // MARK: - Key Derivation

    /// Derive NIP-44v2 conversation key: HKDF-extract(salt="nip44-v2", IKM=shared_x).
    static func conversationKey(
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> SymmetricKey {
        // ECDH to get shared x-coordinate
        let sharedX = try NIP04Service.sharedSecret(
            privateKeyHex: privateKeyHex,
            publicKeyHex: publicKeyHex
        )
        // HKDF-extract is HMAC-SHA256(salt, IKM)
        let salt = Data("nip44-v2".utf8)
        let key = HMAC<CryptoKit.SHA256>.authenticationCode(for: sharedX, using: SymmetricKey(data: salt))
        return SymmetricKey(data: key)
    }

    /// Derive per-message keys via HKDF-expand.
    /// Returns (chachaKey: 32, chachaNonce: 12, hmacKey: 32).
    static func messageKeys(
        conversationKey: SymmetricKey,
        nonce: Data
    ) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let expanded = hkdfExpand(prk: conversationKey, info: nonce, outputLength: 76)
        let chachaKey = expanded[0..<32]
        let chachaNonce = expanded[32..<44]
        let hmacKey = expanded[44..<76]
        return (Data(chachaKey), Data(chachaNonce), Data(hmacKey))
    }

    /// HKDF-Expand (RFC 5869 Section 2.3) with SHA-256.
    private static func hkdfExpand(prk: SymmetricKey, info: Data, outputLength: Int) -> Data {
        var result = Data()
        var t = Data()
        var counter: UInt8 = 1
        while result.count < outputLength {
            var input = t
            input.append(info)
            input.append(counter)
            let hmac = HMAC<CryptoKit.SHA256>.authenticationCode(for: input, using: prk)
            t = Data(hmac)
            result.append(t)
            counter += 1
        }
        return result.prefix(outputLength)
    }

    // MARK: - Encrypt

    /// Encrypt plaintext per NIP-44v2.
    ///
    /// Returns base64-encoded payload: `version(1) + nonce(32) + ciphertext + hmac(32)`.
    static func encrypt(
        _ plaintext: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        let plaintextData = Data(plaintext.utf8)
        let padded = try pad(plaintextData)

        let convKey = try conversationKey(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)

        // Random 32-byte nonce
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey: convKey, nonce: nonce)

        // ChaCha20 stream cipher with 16-byte nonce: 4 zero bytes + 12-byte chacha_nonce
        let nonce16 = Data(count: 4) + chachaNonce
        let ciphertext = try chacha20(data: padded, key: chachaKey, nonce: nonce16)

        // HMAC-SHA256(nonce || ciphertext)
        var hmacInput = nonce
        hmacInput.append(ciphertext)
        let mac = HMAC<CryptoKit.SHA256>.authenticationCode(
            for: hmacInput,
            using: SymmetricKey(data: hmacKey)
        )

        // Assemble payload
        var payload = Data([version])
        payload.append(nonce)
        payload.append(ciphertext)
        payload.append(Data(mac))
        return payload.base64EncodedString()
    }

    // MARK: - Decrypt

    /// Decrypt a NIP-44v2 base64 payload.
    static func decrypt(
        _ payloadBase64: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        // Normalize base64 padding
        var b64 = payloadBase64
        while b64.count % 4 != 0 { b64 += "=" }

        guard let payload = Data(base64Encoded: b64) else {
            throw NIP44Error.decryptionFailed("base64 decode failed")
        }
        // Minimum: 1 version + 32 nonce + 34 min ciphertext + 32 mac = 99
        guard payload.count >= 99 else { throw NIP44Error.payloadTooShort }

        let ver = payload[0]
        guard ver == version else { throw NIP44Error.unsupportedVersion(ver) }

        let nonce = payload[1..<33]
        let ciphertext = payload[33..<(payload.count - 32)]
        let mac = payload[(payload.count - 32)...]

        let convKey = try conversationKey(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        let (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey: convKey, nonce: Data(nonce))

        // Verify HMAC-SHA256
        var hmacInput = Data(nonce)
        hmacInput.append(contentsOf: ciphertext)
        let expectedMac = HMAC<CryptoKit.SHA256>.authenticationCode(
            for: hmacInput,
            using: SymmetricKey(data: hmacKey)
        )
        guard Data(mac) == Data(expectedMac) else {
            throw NIP44Error.hmacVerificationFailed
        }

        // ChaCha20 decrypt
        let nonce16 = Data(count: 4) + chachaNonce
        let padded = try chacha20(data: Data(ciphertext), key: chachaKey, nonce: nonce16)

        let plaintext = try unpad(padded)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw NIP44Error.decryptionFailed("UTF-8 decode failed")
        }
        return result
    }

    // MARK: - ChaCha20 via CryptoKit

    /// ChaCha20 stream cipher (symmetric — same for encrypt and decrypt).
    ///
    /// NIP-44 uses raw ChaCha20 (no Poly1305 auth tag). CryptoKit only exposes
    /// ChaChaPoly (AEAD), so we encrypt zeros to extract the keystream and XOR
    /// it with the data. The 16-byte nonce is split: first 4 bytes as counter
    /// prefix (unused by CryptoKit — it uses a 12-byte nonce), last 12 bytes
    /// as the ChaChaPoly nonce.
    private static func chacha20(data: Data, key: Data, nonce: Data) throws -> Data {
        // NIP-44 passes a 16-byte nonce: 4 zero bytes + 12-byte chacha_nonce.
        // ChaChaPoly uses 12-byte nonce — take the last 12.
        let nonce12: Data
        if nonce.count == 16 {
            nonce12 = nonce.suffix(12)
        } else if nonce.count == 12 {
            nonce12 = nonce
        } else {
            throw NIP44Error.encryptionFailed
        }

        let symmetricKey = SymmetricKey(data: key)
        let cryptoNonce = try ChaChaPoly.Nonce(data: nonce12)

        // Encrypt zeros to get keystream, then XOR with data
        let zeros = Data(count: data.count)
        let sealed = try ChaChaPoly.seal(zeros, using: symmetricKey, nonce: cryptoNonce)
        let keystream = Data(sealed.ciphertext)  // Copy to ensure zero-based indexing
        let inputData = Data(data)               // Same for input slice safety

        var output = Data(count: inputData.count)
        for i in 0..<inputData.count {
            output[i] = inputData[i] ^ keystream[i]
        }
        return output
    }
}
