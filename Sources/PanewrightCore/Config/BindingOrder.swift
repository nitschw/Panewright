import Foundation

/// The order bindings are listed in, wherever they're listed.
///
/// Config order is authoring order — whatever the defaults or the importer
/// happened to emit — which puts the number row at 1…9 then 0, and drops any
/// hand-added binding wherever it was typed. Reading a list like that means
/// scanning it rather than looking in the obvious place.
///
/// Shared by the Settings editor and the cheat sheet deliberately. Two lists
/// of the same bindings in two different orders is worse than either order.
public enum BindingOrder {
    /// Sort key: digits before letters, numbers compared numerically, and a
    /// modified key kept beside the key it modifies.
    ///
    /// The clustering is the point. Sorting the raw strings would file every
    /// `shift-` binding together under S, so `shift-1` would sit nine rows
    /// from `1` — but what you're looking for is the *key*, and the modifier
    /// is a variant of it. So the base key sorts first and the modifier breaks
    /// the tie: 0, shift-0, 1, shift-1, 2, shift-2.
    public static func sortKey(_ key: String) -> (Int, String, Int, String) {
        let lowered = key.lowercased()
        let separator = lowered.lastIndex(of: "-")
        let modifier = separator.map { String(lowered[lowered.startIndex..<$0]) } ?? ""
        let base = separator.map { String(lowered[lowered.index(after: $0)...]) } ?? lowered
        let digits = Int(base)
        // Digits first as a group, then either numerically or by name, and
        // finally the bare key ahead of its modified variants.
        return (digits == nil ? 1 : 0, digits == nil ? base : "", digits ?? 0, modifier)
    }

    public static func before(_ lhs: String, _ rhs: String) -> Bool {
        sortKey(lhs) < sortKey(rhs)
    }

    public static func sorted(_ bindings: [PanewrightConfig.Binding])
        -> [PanewrightConfig.Binding]
    {
        bindings.sorted { before($0.key, $1.key) }
    }
}
