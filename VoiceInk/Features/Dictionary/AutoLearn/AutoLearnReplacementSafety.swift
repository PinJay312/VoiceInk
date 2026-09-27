import Foundation

enum AutoLearnReplacementSafety {
    /// Automatic replacements are global. A single character from a script
    /// without word boundaries would therefore rewrite unrelated terms.
    static func isSafeAutomaticSource(_ rawSource: String) -> Bool {
        let source = rawSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping

        guard !source.isEmpty else { return false }
        guard source.count == 1 else { return true }
        return !source.unicodeScalars.contains(where: isCompactScriptScalar)
    }

    private static func isCompactScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0E00...0x0E7F).contains(value)  // Thai
            || (0x3040...0x30FF).contains(value)  // Hiragana and Katakana
            || (0x31F0...0x31FF).contains(value)  // Katakana extensions
            || (0x3400...0x4DBF).contains(value)  // CJK Extension A
            || (0x4E00...0x9FFF).contains(value)  // CJK Unified Ideographs
            || (0xAC00...0xD7AF).contains(value)  // Hangul syllables
            || (0xF900...0xFAFF).contains(value)  // CJK compatibility ideographs
            || (0xFF66...0xFF9D).contains(value)  // Halfwidth Katakana
            || (0x20000...0x323AF).contains(value)  // CJK extensions B through H
    }
}
