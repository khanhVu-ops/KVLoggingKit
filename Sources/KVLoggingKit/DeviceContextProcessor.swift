import Foundation

public struct DeviceContextProcessor: LogProcessor {
    /// Keys this processor contributes. `PrivacyProcessor.strict` unions them
    /// into its allowlist so device context is never dropped by accident.
    public static let metadataKeys: Set<String> = [
        "app_version",
        "app_build",
        "os_version",
        "session_id"
    ]

    private let metadata: LogMetadata

    public init(
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        appBuild: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        sessionID: UUID = UUID()
    ) {
        metadata = [
            "app_version": .public(appVersion),
            "app_build": .public(appBuild),
            "os_version": .public(osVersion),
            "session_id": .public(sessionID)
        ]
    }

    public func process(_ event: LogEvent) async -> LogEvent? {
        event.replacing(
            metadata: metadata.merging(event.metadata) { _, eventValue in eventValue }
        )
    }
}
