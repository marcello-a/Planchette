import Foundation

/// Minimal semantic-version comparison used by the updater.
enum Semver {
    /// True if `a` is a strictly newer version than `b`, comparing numeric
    /// components left to right (missing components count as 0).
    /// Any leading "v" and pre-release suffix (after "-") are ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = components(a)
        let pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-").first.map(String.init)
            .map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
    }
}
