import Foundation

/// Fuzzy matching for the command palette — dmenu/rofi's contract: every
/// query character must appear in order, and the *shape* of where they land
/// decides the ranking.
///
/// Deliberately small: prefixes beat word-starts beat runs beat scattered
/// letters, ties break toward shorter candidates. That's the entire model —
/// launcher muscle memory is built on ranking being predictable, so a
/// cleverer scorer that occasionally surprises is worse than a dumb one that
/// never does.
public enum PaletteScore {
    /// nil = not a match. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        var qi = 0
        var total = 0
        var previousHit = -2
        for (index, character) in c.enumerated() {
            guard qi < q.count, character == q[qi] else { continue }
            var points = 1
            if index == 0 {
                points += 8
            } else if !c[index - 1].isLetter && !c[index - 1].isNumber {
                // Word boundary: "sw" hitting "Switch Workspace"'s capitals.
                points += 6
            }
            if index == previousHit + 1 {
                // Consecutive run — typing a real substring should dominate.
                points += 4
            }
            previousHit = index
            total += points
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Shorter candidates win ties: "Mail" over "Mail Importer Helper".
        return total * 100 - c.count
    }

    /// Rank candidates by score, best first, non-matches dropped. Stable for
    /// equal scores so source ordering (windows before apps) survives.
    public static func rank<T>(
        query: String, in items: [T], by name: (T) -> String
    ) -> [T] {
        items.compactMap { item -> (T, Int)? in
            score(query: query, candidate: name(item)).map { (item, $0) }
        }
        .enumerated()
        .sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }
        .map(\.element.0)
    }
}
