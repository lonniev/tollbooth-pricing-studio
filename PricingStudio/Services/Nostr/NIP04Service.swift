import CommonCrypto
import Foundation
import P256K

/// NIP-04 encryption: AES-256-CBC with ECDH shared secret.
///
/// Content format: `base64(ciphertext)?iv=base64(iv)`
/// Shared secret: x-coordinate of ECDH(privkey, pubkey) — raw, no SHA-256.
///
/// Reference: https://github.com/nostr-protocol/nips/blob/master/04.md
enum NIP04Service {

    enum NIP04Error: LocalizedError {
        case invalidKey
        case ecdhFailed
        case encryptionFailed
        case decryptionFailed(String)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Invalid key data"
            case .ecdhFailed: return "ECDH key agreement failed"
            case .encryptionFailed: return "AES-256-CBC encryption failed"
            case .decryptionFailed(let msg): return "NIP-04 decryption failed: \(msg)"
            case .invalidFormat: return "Invalid NIP-04 format (expected base64?iv=base64)"
            }
        }
    }

    // MARK: - ECDH Shared Secret

    /// Derive NIP-04 shared secret: x-coordinate of ECDH shared point.
    static func sharedSecret(
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> Data {
        guard let privBytes = Data(hexString: privateKeyHex), privBytes.count == 32,
              let pubBytes = Data(hexString: publicKeyHex), pubBytes.count == 32 else {
            throw NIP04Error.invalidKey
        }

        // P256K.KeyAgreement requires a compressed public key (02 prefix + 32 bytes)
        let compressedPub = [UInt8(0x02)] + Array(pubBytes)
        let privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: Array(privBytes))
        let pubKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: compressedPub)
        let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)

        // Extract x-coordinate (32 bytes) from the shared secret
        // SharedSecret conforms to ContiguousBytes; extract raw representation
        let sharedBytes = shared.withUnsafeBytes { Data($0) }

        // The shared secret from P256K is already the 32-byte x-coordinate
        guard sharedBytes.count == 32 else {
            throw NIP04Error.ecdhFailed
        }
        return sharedBytes
    }

    // MARK: - Encrypt

    /// Encrypt plaintext using NIP-04 AES-256-CBC.
    ///
    /// - Returns: `base64(ciphertext)?iv=base64(iv)`
    static func encrypt(
        _ plaintext: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        let key = try sharedSecret(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        let plaintextData = Data(plaintext.utf8)

        // PKCS7 pad to AES block size (16 bytes)
        let blockSize = kCCBlockSizeAES128
        let paddedLen = plaintextData.count + blockSize - (plaintextData.count % blockSize)
        var padded = plaintextData
        let paddingByte = UInt8(paddedLen - plaintextData.count)
        padded.append(contentsOf: [UInt8](repeating: paddingByte, count: Int(paddingByte)))

        // Random 16-byte IV
        var iv = Data(count: 16)
        iv.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        // AES-256-CBC encrypt
        let bufferSize = paddedLen
        var ciphertext = Data(count: bufferSize)
        var numBytesEncrypted = 0
        let status = ciphertext.withUnsafeMutableBytes { ctPtr in
            padded.withUnsafeBytes { ptPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,  // No padding option — we padded manually
                            keyPtr.baseAddress!, key.count,
                            ivPtr.baseAddress!,
                            ptPtr.baseAddress!, padded.count,
                            ctPtr.baseAddress!, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw NIP04Error.encryptionFailed }
        ciphertext = ciphertext.prefix(numBytesEncrypted)

        let ctBase64 = ciphertext.base64EncodedString()
        let ivBase64 = iv.base64EncodedString()
        return "\(ctBase64)?iv=\(ivBase64)"
    }

    // MARK: - Decrypt

    /// Decrypt a NIP-04 `base64(ciphertext)?iv=base64(iv)` message.
    static func decrypt(
        _ ciphertextWithIV: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        guard ciphertextWithIV.contains("?iv=") else {
            throw NIP04Error.invalidFormat
        }

        let parts = ciphertextWithIV.components(separatedBy: "?iv=")
        guard parts.count == 2 else { throw NIP04Error.invalidFormat }

        // Normalize base64 padding — some clients strip trailing '='
        let ctBase64 = normalizeBase64(parts[0])
        let ivBase64 = normalizeBase64(parts[1])

        guard let ciphertext = Data(base64Encoded: ctBase64),
              let iv = Data(base64Encoded: ivBase64) else {
            throw NIP04Error.decryptionFailed("base64 decode failed")
        }
        guard iv.count == 16 else {
            throw NIP04Error.decryptionFailed("IV must be 16 bytes, got \(iv.count)")
        }

        let key = try sharedSecret(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)

        // AES-256-CBC decrypt
        let decryptBufferSize = ciphertext.count + kCCBlockSizeAES128
        var plaintext = Data(count: decryptBufferSize)
        var numBytesDecrypted = 0
        let status = plaintext.withUnsafeMutableBytes { ptPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,  // No auto-unpadding
                            keyPtr.baseAddress!, key.count,
                            ivPtr.baseAddress!,
                            ctPtr.baseAddress!, ciphertext.count,
                            ptPtr.baseAddress!, decryptBufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NIP04Error.decryptionFailed("CCCrypt returned \(status)")
        }

        // PKCS7 unpad
        let decrypted = plaintext.prefix(numBytesDecrypted)
        guard let lastByte = decrypted.last, lastByte > 0, lastByte <= 16 else {
            throw NIP04Error.decryptionFailed("invalid PKCS7 padding")
        }
        let unpadded = decrypted.prefix(decrypted.count - Int(lastByte))

        guard let result = String(data: unpadded, encoding: .utf8) else {
            throw NIP04Error.decryptionFailed("UTF-8 decode failed")
        }
        return result
    }

    // MARK: - Helpers

    /// Normalize base64 by adding trailing `=` to make length a multiple of 4.
    private static func normalizeBase64(_ str: String) -> String {
        var s = str
        while s.count % 4 != 0 { s += "=" }
        return s
    }
}
