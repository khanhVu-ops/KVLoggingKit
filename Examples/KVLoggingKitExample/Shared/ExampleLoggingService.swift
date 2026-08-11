import Foundation
import KVLoggingKit
import KVLoggingLocal
import KVLoggingRemote
import KVLoggingSecurity

public struct ExampleSnapshot: Sendable {
    public let isOnline: Bool
    public let deliveredBatchCount: Int
    public let deliveredEventCount: Int
    public let queuedBatchCount: Int
    public let localFileCount: Int
    public let bootstrapError: String?

    public static let empty = ExampleSnapshot(
        isOnline: true,
        deliveredBatchCount: 0,
        deliveredEventCount: 0,
        queuedBatchCount: 0,
        localFileCount: 0,
        bootstrapError: nil
    )
}

struct ExampleTestHarness {
    let service: ExampleLoggingService
    let rootDirectory: URL
}

public struct ExampleLoggingService: Sendable {
    public let logger: LogClient

    private let transport: MockLogTransport
    private let queue: any LogBatchQueue
    private let localFiles: RollingFileDestination?
    private let bootstrapError: String?

    private init(
        logger: LogClient,
        transport: MockLogTransport,
        queue: any LogBatchQueue,
        localFiles: RollingFileDestination?,
        bootstrapError: String?
    ) {
        self.logger = logger
        self.transport = transport
        self.queue = queue
        self.localFiles = localFiles
        self.bootstrapError = bootstrapError
    }

    public static func live() -> ExampleLoggingService {
        let transport = MockLogTransport()

        do {
            let service = Bundle.main.bundleIdentifier ?? "KVLoggingKit.Example"
            let cipher = AESGCMLogCipher(
                keyProvider: KeychainLogEncryptionKeyProvider(service: service)
            )
            let fileManager = FileManager.default
            let logsDirectory = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("KVLoggingKit/Logs", isDirectory: true)
            let queueDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("KVLoggingKit/PendingLogs", isDirectory: true)

            return try make(
                transport: transport,
                queueDirectory: queueDirectory,
                logsDirectory: logsDirectory,
                cipher: cipher,
                retryPolicy: .init(maximumAttempts: 3, initialDelay: 0.25, maximumDelay: 1)
            )
        } catch {
            return ExampleLoggingService(
                logger: .disabled,
                transport: transport,
                queue: MemoryLogBatchQueue(),
                localFiles: nil,
                bootstrapError: String(describing: error)
            )
        }
    }

    static func makeTestHarness() throws -> ExampleTestHarness {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KVLoggingKitExampleTests-\(UUID().uuidString)", isDirectory: true)
        let cipher = AESGCMLogCipher(
            keyProvider: try StaticLogEncryptionKeyProvider(
                keyData: Data(repeating: 0x2A, count: 32)
            )
        )
        let transport = MockLogTransport()
        let service = try make(
            transport: transport,
            queueDirectory: rootDirectory.appendingPathComponent("Queue", isDirectory: true),
            logsDirectory: rootDirectory.appendingPathComponent("Logs", isDirectory: true),
            cipher: cipher,
            retryPolicy: .init(maximumAttempts: 2, initialDelay: 0, maximumDelay: 0)
        )
        return ExampleTestHarness(service: service, rootDirectory: rootDirectory)
    }

    public func generateSampleLogs() {
        logger.info("Example session started", category: "example")
        logger.warning(
            "Profile request completed slowly",
            category: "network",
            metadata: ["duration_ms": .public(1_250)]
        )
        logger.error(
            "Profile request failed",
            category: "network",
            error: SampleError.requestTimedOut
        )
        logger.info(
            "Profile displayed",
            category: "profile",
            metadata: [
                "screen": .public("profile"),
                "email": .private("reader@example.com")
            ]
        )
    }

    public func setOnline(_ value: Bool) async {
        await transport.setOnline(value)
    }

    public func snapshot() async -> ExampleSnapshot {
        let batches = await transport.snapshot()
        let queueCount = (try? await queue.count()) ?? 0
        let fileCount = await localFiles?.logFiles().count ?? 0

        return ExampleSnapshot(
            isOnline: await transport.onlineState(),
            deliveredBatchCount: batches.count,
            deliveredEventCount: batches.reduce(0) { $0 + $1.count },
            queuedBatchCount: queueCount,
            localFileCount: fileCount,
            bootstrapError: bootstrapError
        )
    }

    public func flushAndSnapshot() async -> ExampleSnapshot {
        await logger.flush()
        return await snapshot()
    }

    public func exportLocalLogs() async throws -> URL {
        guard let localFiles else {
            throw ExampleLoggingServiceError.localLoggingUnavailable
        }

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KVLoggingKitExport-\(UUID().uuidString)", isDirectory: true)
        return try await localFiles.export(to: exportDirectory)
    }

    private static func make(
        transport: MockLogTransport,
        queueDirectory: URL,
        logsDirectory: URL,
        cipher: any LogDataCipher,
        retryPolicy: RetryPolicy
    ) throws -> ExampleLoggingService {
        let queue = try DiskLogBatchQueue(directory: queueDirectory, cipher: cipher)
        let localFiles = try RollingFileDestination(
            directory: logsDirectory,
            policy: .init(
                maxFileSize: 250_000,
                maxFileCount: 3,
                retentionDays: 7,
                protection: .encrypted(cipher)
            )
        )
        let remote = RemoteBatchDestination(
            transport: transport,
            queue: queue,
            policy: .init(
                maxBatchSize: 4,
                flushInterval: 5,
                retry: retryPolicy
            )
        )
        let logger = LogClient(
            configuration: .init(
                minimumLevel: .debug,
                processors: [
                    DeviceContextProcessor(),
                    PrivacyProcessor.strict(
                        allowedMetadataKeys: [
                            "app_version",
                            "app_build",
                            "os_version",
                            "session_id",
                            "email",
                            "screen",
                            "duration_ms"
                        ]
                    )
                ]
            ),
            destinations: [
                SystemLogDestination(),
                localFiles,
                remote
            ]
        )

        return ExampleLoggingService(
            logger: logger,
            transport: transport,
            queue: queue,
            localFiles: localFiles,
            bootstrapError: nil
        )
    }
}

private enum ExampleLoggingServiceError: LocalizedError {
    case localLoggingUnavailable

    var errorDescription: String? {
        "Local logging is unavailable because the logger could not be initialized."
    }
}
