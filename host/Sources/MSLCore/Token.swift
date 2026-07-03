import Foundation

/// Single-use attach tokens: 16 random bytes as 32 lowercase hex characters,
/// the same shape as the guest data-plane token.
public enum Token {
    /// Generate a fresh token from the system CSPRNG.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var hex = ""
        hex.reserveCapacity(LocalProto.tokenHexLength)
        for _ in 0..<16 {  // bounded: exactly 16 bytes
            let byte = UInt8.random(in: 0...255, using: &generator)
            hex += String(format: "%02x", byte)
        }
        assert(hex.count == LocalProto.tokenHexLength, "token must be 32 hex chars")
        return hex
    }

    /// Constant-time-ish equality: compares every byte regardless of mismatch
    /// position so a comparison cannot leak the shared-prefix length by timing.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for idx in 0..<left.count {  // bounded: token length
            diff |= left[idx] ^ right[idx]
        }
        return diff == 0
    }
}
