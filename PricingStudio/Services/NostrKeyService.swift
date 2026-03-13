import Foundation
import P256K

enum NostrKeyService {

    enum KeyError: LocalizedError {
        case invalidNsec
        case invalidBech32
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .invalidNsec: return "Invalid nsec format — must start with nsec1"
            case .invalidBech32: return "Invalid bech32 encoding"
            case .keyDerivationFailed: return "Failed to derive public key from secret key"
            }
        }
    }

    /// Derive an npub from an nsec.
    static func npubFromNsec(_ nsec: String) throws -> String {
        guard nsec.hasPrefix("nsec1") else { throw KeyError.invalidNsec }

        // 1. Bech32 decode nsec → 32-byte private key
        guard let (hrp, data5bit) = bech32Decode(nsec), hrp == "nsec" else {
            throw KeyError.invalidBech32
        }
        guard let privateKeyBytes = convertBits(data: data5bit, fromBits: 5, toBits: 8, pad: false),
              privateKeyBytes.count == 32 else {
            throw KeyError.invalidNsec
        }

        // 2. Derive x-only public key via secp256k1
        let privateKey: P256K.Schnorr.PrivateKey
        do {
            privateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyBytes)
        } catch {
            throw KeyError.keyDerivationFailed
        }
        let publicKeyBytes = Array(privateKey.xonly.bytes)

        // 3. Bech32 encode as npub
        guard let data5bitOut = convertBits(data: publicKeyBytes, fromBits: 8, toBits: 5, pad: true) else {
            throw KeyError.keyDerivationFailed
        }
        return bech32Encode(hrp: "npub", data: data5bitOut)
    }

    /// Validate that a string looks like a valid nsec.
    static func isValidNsec(_ nsec: String) -> Bool {
        guard nsec.hasPrefix("nsec1"), nsec.count > 10 else { return false }
        return (try? npubFromNsec(nsec)) != nil
    }

    // MARK: - Bech32 Codec (BIP173)

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charsetMap: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in charset.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()

    private static func bech32Polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 {
                if ((b >> i) & 1) != 0 {
                    chk ^= gen[i]
                }
            }
        }
        return chk
    }

    private static func bech32HrpExpand(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for c in hrp.unicodeScalars {
            result.append(UInt8(c.value >> 5))
        }
        result.append(0)
        for c in hrp.unicodeScalars {
            result.append(UInt8(c.value & 31))
        }
        return result
    }

    private static func bech32VerifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        bech32Polymod(bech32HrpExpand(hrp) + data) == 1
    }

    private static func bech32CreateChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = bech32HrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let polymod = bech32Polymod(values) ^ 1
        return (0..<6).map { UInt8((polymod >> (5 * (5 - $0))) & 31) }
    }

    static func bech32Decode(_ str: String) -> (hrp: String, data: [UInt8])? {
        let lower = str.lowercased()
        guard let sepIndex = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[lower.startIndex..<sepIndex])
        let dataStr = lower[lower.index(after: sepIndex)...]
        guard dataStr.count >= 6 else { return nil }

        var data = [UInt8]()
        for c in dataStr {
            guard let val = charsetMap[c] else { return nil }
            data.append(val)
        }

        guard bech32VerifyChecksum(hrp: hrp, data: data) else { return nil }
        return (hrp, Array(data.dropLast(6)))
    }

    static func bech32Encode(hrp: String, data: [UInt8]) -> String {
        let checksum = bech32CreateChecksum(hrp: hrp, data: data)
        let combined = data + checksum
        return hrp + "1" + String(combined.map { charset[Int($0)] })
    }

    /// Convert between bit groups (BIP173 convertbits).
    static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << toBits) - 1

        for value in data {
            let v = Int(value)
            if v < 0 || (v >> fromBits) != 0 { return nil }
            acc = (acc << fromBits) | v
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else {
            if bits >= fromBits { return nil }
            if ((acc << (toBits - bits)) & maxv) != 0 { return nil }
        }
        return result
    }
}
