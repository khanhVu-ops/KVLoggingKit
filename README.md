# KVLoggingKit

`KVLoggingKit` is a modular, privacy-first logging package for UIKit and SwiftUI applications. The core package has no third-party dependencies and uses Swift 6 strict concurrency.

## Requirements

- Xcode 16+
- Swift 6
- UIKit: iOS 13+
- SwiftUI integration: iOS 16+

## Products

| Product | Purpose |
| --- | --- |
| `KVLoggingKit` | Structured events, processors, `LogClient`, and destination protocols |
| `KVLoggingSecurity` | AES-GCM encryption and Keychain key storage |
| `KVLoggingLocal` | Unified logging and encrypted rolling files |
| `KVLoggingRemote` | HTTP transport, batching, retry, and offline queues |
| `KVLoggingUIKit` | UIKit lifecycle flushing |
| `KVLoggingSwiftUI` | SwiftUI Environment injection and background flushing |
| `KVLoggingTesting` | In-memory destination for application tests |

Add this directory as a local Swift package in Xcode, then select only the products required by the application target.

## Bootstrap

```swift
import Foundation
import KVLoggingKit
import KVLoggingLocal
import KVLoggingRemote
import KVLoggingSecurity

enum LoggingBootstrap {
    static func makeLogger() throws -> (
        client: LogClient,
        localFiles: RollingFileDestination
    ) {
        let service = Bundle.main.bundleIdentifier ?? "KVLoggingKit.Application"
        let keyProvider = KeychainLogEncryptionKeyProvider(service: service)
        let cipher = AESGCMLogCipher(keyProvider: keyProvider)

        let logsDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Logs")

        let queueDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PendingLogs")

        let localFiles = try RollingFileDestination(
            directory: logsDirectory,
            policy: .init(
                maxFileSize: 2_000_000,
                maxFileCount: 5,
                retentionDays: 7,
                protection: .encrypted(cipher)
            )
        )

        let offlineQueue = try DiskLogBatchQueue(
            directory: queueDirectory,
            cipher: cipher
        )

        let remote = RemoteBatchDestination(
            transport: HTTPLogTransport(
                endpoint: URL(string: "https://logs.example.com/v1/events")!,
                headers: ["Authorization": "Bearer your-api-key"]
            ),
            queue: offlineQueue,
            policy: .init(
                maxBatchSize: 50,
                flushInterval: 10,
                retry: .init(
                    maximumAttempts: 5,
                    initialDelay: 1,
                    maximumDelay: 60
                )
            )
        )

        let client = LogClient(
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
                            "user_id",
                            "email",
                            "screen",
                            "request_id",
                            "duration_ms"
                        ]
                    )
                ]
            ),
            destinations: [
                SystemLogDestination(subsystem: service),
                localFiles,
                remote
            ]
        )

        return (client, localFiles)
    }
}
```

Use `.disabled` as a safe fallback if bootstrap fails:

```swift
let logger = (try? LoggingBootstrap.makeLogger().client) ?? .disabled
```

## Logging

Calls are synchronous and do not block the caller on file or network I/O.

```swift
logger.debug("Preparing profile screen")
logger.info("Profile loaded")
logger.warning("Profile response is stale")
logger.error("Cannot load profile", error: error)
```

Structured metadata declares its privacy explicitly:

```swift
logger.info(
    "Profile loaded",
    category: "profile",
    metadata: [
        "user_id": .public(user.id),
        "email": .private(user.email),
        "duration_ms": .public(duration)
    ]
)
```

- Public fields may be sent to every destination.
- Private fields remain available to encrypted local storage and become `<redacted>` before remote delivery.
- `PrivacyProcessor.strict` drops keys outside its allowlist and redacts common token, email, and phone patterns from messages.
- Do not pass passwords, access tokens, or raw request/response bodies to the logger.

Use a scoped logger for shared context:

```swift
let requestLogger = logger.scoped(
    category: "network",
    metadata: ["request_id": .public(requestID)]
)

requestLogger.info("Request started")
requestLogger.info(
    "Request completed",
    metadata: ["duration_ms": .public(duration)]
)
```

## UIKit

Retain the lifecycle object for as long as the application is running:

```swift
import UIKit
import KVLoggingKit
import KVLoggingUIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let logger = (try? LoggingBootstrap.makeLogger().client) ?? .disabled
    private var loggingLifecycle: UIKitLoggingLifecycle?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        loggingLifecycle = UIKitLoggingLifecycle(
            application: application,
            logger: logger
        )
        logger.info("Application launched", category: "lifecycle")
        return true
    }
}
```

Inject `LogClient` into view controllers and services instead of reading a global singleton.

## SwiftUI

The SwiftUI integration is available on iOS 16+:

```swift
import SwiftUI
import KVLoggingKit
import KVLoggingSwiftUI

@main
struct ExampleApp: App {
    private let logger =
        (try? LoggingBootstrap.makeLogger().client) ?? .disabled

    var body: some Scene {
        WindowGroup {
            RootView()
                .kvLogging(logger)
        }
    }
}
```

Read the injected client from a view:

```swift
struct ProfileView: View {
    @Environment(\.logClient) private var logger

    var body: some View {
        Button("Refresh") {
            logger.info(
                "Refresh selected",
                category: "profile",
                metadata: ["screen": .public("profile")]
            )
        }
    }
}
```

`.kvLogging(_:)` also flushes pending destinations when the scene moves to the background.

## Flush and export

Use `flush()` before a controlled shutdown or after a user explicitly requests upload:

```swift
Task {
    await logger.flush()
}
```

Export retained local files through the configured `RollingFileDestination`:

```swift
let exportDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SupportLogs")

Task {
    let directory = try await localFiles.export(to: exportDirectory)
    presentShareSheet(for: directory)
}
```

## Custom remote adapters

Keep third-party SDKs outside the core package by conforming to `LogTransport`:

```swift
import KVLoggingKit
import KVLoggingRemote
import Sentry

actor SentryLogTransport: LogTransport {
    func send(_ events: [LogEvent]) async throws {
        for event in events {
            let breadcrumb = Breadcrumb()
            breadcrumb.category = event.category
            breadcrumb.message = event.message
            breadcrumb.data = event.metadata.mapValues(\.value.stringValue)
            SentrySDK.addBreadcrumb(breadcrumb)
        }
    }
}
```

Register the adapter through `RemoteBatchDestination` to reuse batching and retry behavior.

## Testing

```swift
import XCTest
import KVLoggingKit
import KVLoggingTesting

func testRefreshLogsAnEvent() async {
    let destination = InMemoryLogDestination()
    let logger = LogClient(destinations: [destination])

    logger.info("Refresh selected")
    await logger.flush()

    let events = await destination.snapshot()
    XCTAssertEqual(events.map(\.message), ["Refresh selected"])
}
```

## Architecture

```text
App code
   │ synchronous log call
   ▼
LogClient → ordered AsyncStream → processor chain → destinations
                                      ├─ unified logging
                                      ├─ encrypted rolling files
                                      └─ batch → retry → encrypted queue → transport
```

Destination failures are isolated by `LogClient`. Supply `internalErrorHandler` in `LogConfiguration` when the host application needs diagnostics about logging infrastructure failures.
