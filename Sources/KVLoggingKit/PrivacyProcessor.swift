import Foundation

public struct PrivacyProcessor: LogProcessor {
    private struct Replacement: Sendable {
        let pattern: String
        let template: String
    }

    private let allowedMetadataKeys: Set<String>?
    private let replacements: [Replacement]

    private init(
        allowedMetadataKeys: Set<String>?,
        replacements: [Replacement]
    ) {
        self.allowedMetadataKeys = allowedMetadataKeys
        self.replacements = replacements
    }

    public static func strict(
        allowedMetadataKeys: Set<String>
    ) -> PrivacyProcessor {
        PrivacyProcessor(
            allowedMetadataKeys: allowedMetadataKeys,
            replacements: [
                .init(
                    pattern: #"(?i)bearer\s+[a-z0-9._~+/=-]+"#,
                    template: "Bearer <redacted-token>"
                ),
                .init(
                    pattern: #"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#,
                    template: "<redacted-email>"
                ),
                .init(
                    pattern: #"\+?[0-9][0-9\s().-]{7,}[0-9]"#,
                    template: "<redacted-phone>"
                )
            ]
        )
    }

    public func process(_ event: LogEvent) async -> LogEvent? {
        let metadata: LogMetadata
        if let allowedMetadataKeys {
            metadata = event.metadata.filter { allowedMetadataKeys.contains($0.key) }
        } else {
            metadata = event.metadata
        }

        let message = replacements.reduce(event.message) { result, replacement in
            result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.template,
                options: .regularExpression
            )
        }

        return event.replacing(message: message, metadata: metadata)
    }
}
