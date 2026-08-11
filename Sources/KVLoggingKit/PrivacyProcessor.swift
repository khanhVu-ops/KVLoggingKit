import Foundation

/// Scrubs message text and, optionally, drops metadata keys outside an allowlist.
public struct PrivacyProcessor: LogProcessor {
    private let allowedMetadataKeys: Set<String>?
    private let redaction: LogRedaction

    public init(
        allowedMetadataKeys: Set<String>? = nil,
        redaction: LogRedaction = .default
    ) {
        self.allowedMetadataKeys = allowedMetadataKeys
        self.redaction = redaction
    }

    /// Scrubs messages but keeps every metadata key the caller supplied.
    ///
    /// Prefer this over ``strict(allowedMetadataKeys:)`` unless the app must
    /// guarantee that no unexpected key ever reaches a destination: an
    /// allowlist silently discards fields that processors add later, which
    /// makes the pipeline order-sensitive.
    public static let standard = PrivacyProcessor()

    /// Drops every metadata key outside `allowedMetadataKeys`.
    ///
    /// The allowlist must also cover keys contributed by other processors —
    /// `DeviceContextProcessor` adds `app_version`, `app_build`, `os_version`,
    /// and `session_id` — and this processor has to run after them.
    public static func strict(
        allowedMetadataKeys: Set<String>,
        redaction: LogRedaction = .default
    ) -> PrivacyProcessor {
        PrivacyProcessor(
            allowedMetadataKeys: allowedMetadataKeys.union(
                DeviceContextProcessor.metadataKeys
            ),
            redaction: redaction
        )
    }

    public func process(_ event: LogEvent) async -> LogEvent? {
        let metadata: LogMetadata
        if let allowedMetadataKeys {
            metadata = event.metadata.filter { allowedMetadataKeys.contains($0.key) }
        } else {
            metadata = event.metadata
        }

        return event.replacing(
            message: redaction.redacting(event.message),
            metadata: metadata
        )
    }
}
