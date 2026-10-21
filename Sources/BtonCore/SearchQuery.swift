import Foundation

/// What the panel's search field matches. Digits, with or without a leading `#`, match a PR
/// number that starts with them, so `36` finds #360 to #369 while typing; anything else matches
/// a title or a login containing it, whatever the case.
public struct SearchQuery: Sendable, Equatable {
    public let text: String

    public init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { text.isEmpty }

    public func matches(numbers: [Int], texts: [String]) -> Bool {
        if text.isEmpty { return true }
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) {
            return numbers.contains { String($0).hasPrefix(digits) }
        }
        return texts.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
