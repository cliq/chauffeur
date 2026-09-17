import CryptoKit
import Foundation

/// Shared pairing-code rules for the Mac runtime and the iOS client.
///
/// A pairing code is 10 characters of Crockford base32 (about 50 bits). Both ends derive the
/// pairing listener's TLS pre-shared key from the code alone, because the phone does not know
/// the host identity until pairing succeeds.
public enum PairingKeyDerivation {
    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let codeLength = 10
    public static let salt = "chauffeur-pair-v1"

    /// Uppercases, drops separators and whitespace, folds `I`/`L` to `1` and `O` to `0`.
    /// Returns nil unless the result is exactly `codeLength` alphabet characters.
    public static func normalize(_ text: String) -> String? {
        var result = ""
        for raw in text.uppercased() {
            if raw == "-" || raw == " " || raw == "\u{2011}" { continue }
            let folded: Character
            switch raw {
            case "I", "L": folded = "1"
            case "O": folded = "0"
            default: folded = raw
            }
            guard alphabet.contains(folded) else { return nil }
            result.append(folded)
        }
        return result.count == codeLength ? result : nil
    }

    /// Groups a normalized code as `XXXX-XXXX-XX` for display.
    public static func display(_ normalized: String) -> String {
        let chars = Array(normalized)
        guard chars.count == codeLength else { return normalized }
        return String(chars[0..<4]) + "-" + String(chars[4..<8]) + "-" + String(chars[8..<10])
    }

    /// 32-byte TLS pre-shared key for the pairing listener: HKDF-SHA256 over the normalized code.
    public static func derive(normalizedCode: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalizedCode.utf8)),
            salt: Data(salt.utf8),
            info: Data(),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
