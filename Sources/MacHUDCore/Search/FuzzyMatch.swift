import Foundation

/// How well a typed query matches a name, from 0 to 1000; nil when it does not match.
/// Case and diacritics are ignored. The tiers, best first and `tierGap` apart: the whole name;
/// the start of the name (shorter names first); the start of a word (spaces, punctuation and
/// camel case separate words: "hud" starts a word of "MacHUD"); the words' initials ("vsc" for
/// Visual Studio Code); every word of a several-word query at a word's start; anywhere in the
/// name; the query's letters in order. Within a tier a match loses at most half the gap.
enum FuzzyMatch {
    static let tierGap = 100
    static let exact = 1000
    static let prefix = 900
    static let wordPrefix = 800
    static let initials = 700
    static let allWords = 600
    static let substring = 500
    static let subsequence = 400

    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !candidate.isEmpty else { return nil }
        let c = fold(candidate)
        if c == q { return exact }
        if c.hasPrefix(q) { return prefix - min(tierGap / 2, 2 * (c.count - q.count)) }
        let words = Self.words(candidate)
        if let i = words.firstIndex(where: { $0.hasPrefix(q) }) { return wordPrefix - min(tierGap / 2, i * 10) }
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return initials }
        let tokens = q.split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.count > 1 {
            guard tokens.allSatisfy({ t in words.contains { $0.hasPrefix(t) } || c.contains(t) }) else { return nil }
            return tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } } ? allWords : substring - tierGap / 2
        }
        if let range = c.range(of: q) { return substring - min(tierGap / 2, c.distance(from: c.startIndex, to: range.lowerBound)) }
        return subsequenceScore(q, c)
    }

    /// Lowercased, without diacritics.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The name's words, folded: split at anything not a letter or digit and where a lowercase
    /// letter meets an uppercase one ("FaceTime" is "face", "time"; "MacHUD" is "mac", "hud").
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previousLower = false
        for ch in s {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { out.append(current); current = "" }
                previousLower = false
                continue
            }
            if ch.isUppercase && previousLower && !current.isEmpty { out.append(current); current = "" }
            current.append(ch)
            previousLower = ch.isLowercase
        }
        if !current.isEmpty { out.append(current) }
        return out.map(fold)
    }

    /// The query's characters in order: better when they fall on word starts or run together,
    /// worse the more the name spreads them out, and no match once more than two letters per
    /// typed letter lie between them. Clamped to its band, like every tier: from half the gap
    /// below `subsequence` up to it.
    private static func subsequenceScore(_ q: String, _ c: String) -> Int? {
        var starts = Set<Int>()
        var offset = 0
        var previousWasWordChar = false
        for ch in c {
            let wordChar = ch.isLetter || ch.isNumber
            if wordChar && !previousWasWordChar { starts.insert(offset) }
            previousWasWordChar = wordChar
            offset += 1
        }
        let chars = Array(c)
        var i = 0
        var last = -2
        var bonus = 0
        var first = -1
        for qc in q where qc != " " {
            while i < chars.count && chars[i] != qc { i += 1 }
            guard i < chars.count else { return nil }
            if first < 0 { first = i }
            if starts.contains(i) { bonus += 15 }
            if i == last + 1 { bonus += 10 }
            last = i
            i += 1
        }
        let spread = last - first + 1 - q.count
        guard spread <= 2 * q.count + 2 else { return nil }
        let band = (subsequence - tierGap / 2)...subsequence
        return min(band.upperBound, max(band.lowerBound, subsequence - tierGap / 4 + bonus - spread * 5))
    }
}
