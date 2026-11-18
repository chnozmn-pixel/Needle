import Foundation

/// Deterministic, path-based stable identifiers.
///
/// Everything needs an ID that survives restarts and works on network shares
/// where inodes are not reliable. A 64-bit FNV-1a hash of the full path gives
/// us exactly that (collision probability is negligible at realistic sizes).
public enum EntryID {
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return hash
    }

    public static func forPath(_ path: String) -> UInt64 {
        fnv1a64(normalize(path))
    }

    public static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
