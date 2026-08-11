import Foundation

/// Pattern-based scrubbing for free-form text.
///
/// Patterns are compiled once at construction. `PrivacyProcessor` uses this to
/// clean messages before they reach any destination, and `LogEvent`
/// uses it again on the way out to a remote transport, because a message is the
/// one place a caller can leak a private value without declaring it as one.
public struct LogRedaction: Sendable {
    /// `NSRegularExpression` is documented as thread-safe once created, and the
    /// template never changes, so instances are safe to share.
    public struct Pattern: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String

        /// Returns `nil` when the pattern does not compile, so a bad custom
        /// pattern degrades to "not redacted" instead of trapping at launch.
        public init?(_ pattern: String, template: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            self.expression = expression
            self.template = template
        }
    }

    private let patterns: [Pattern]

    public init(patterns: [Pattern]) {
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.isEmpty }

    public static let none = LogRedaction(patterns: [])

    /// Credentials and email addresses. These patterns are specific enough that
    /// a match is almost never a false positive.
    public static let `default` = LogRedaction(
        patterns: [
            // `Bearer abc…`, and `token=abc…` / `api_key: abc…` style pairs.
            Pattern(
                #"(?i)\bbearer\s+[a-z0-9._~+/=-]{8,}"#,
                template: "Bearer <redacted-token>"
            ),
            Pattern(
                #"(?i)\b(access_token|refresh_token|id_token|api[-_]?key|apikey|secret|password)\b\s*[:=]\s*\S+"#,
                template: "$1=<redacted>"
            ),
            Pattern(
                #"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#,
                template: "<redacted-email>"
            )
        ].compactMap { $0 }
    )

    /// Adds phone-number scrubbing to ``default``.
    ///
    /// Kept separate because a bare run of digits is indistinguishable from a
    /// duration, an identifier, or a timestamp. This pattern only matches
    /// international format, which requires a leading `+`, and refuses to start
    /// or end inside a decimal number.
    public static let includingPhoneNumbers = LogRedaction(
        patterns: `default`.patterns + [
            Pattern(
                #"(?<![\d.])\+\d[\d ().-]{7,}\d(?![\d.])"#,
                template: "<redacted-phone>"
            )
        ].compactMap { $0 }
    )

    public func redacting(_ text: String) -> String {
        guard !patterns.isEmpty, !text.isEmpty else { return text }

        return patterns.reduce(text) { current, pattern in
            let range = NSRange(current.startIndex..., in: current)
            return pattern.expression.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: pattern.template
            )
        }
    }

    public func adding(_ patterns: [Pattern]) -> LogRedaction {
        LogRedaction(patterns: self.patterns + patterns)
    }
}
