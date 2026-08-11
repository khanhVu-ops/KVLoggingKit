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
| `KVLoggingNetwork` | `URLSession` capture, redaction, and cURL export |
| `KVLoggingConsole` | On-device console for logs and API calls, shake to open (iOS 16+) |
| `KVLoggingTesting` | In-memory destination for application tests |

Add this directory as a local Swift package in Xcode, then select only the products required by the application target.

## Run the examples

Open `Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj` in Xcode. The project references the package at the repository root, so it does not require a remote package URL or a logging backend.

- Run the `UIKitExample` scheme on iOS 13 or later to see AppDelegate/SceneDelegate integration and `UIKitLoggingLifecycle`.
- Run the `SwiftUIExample` scheme on iOS 16 or later to see Environment injection with `.kvLogging(_:)` and `@Environment(\.logClient)`.
- The internal `ExampleSupport` framework is shared by both apps and has two behavior tests in the `ExampleSupportTests` scheme.

Try the offline queue flow in either app:

1. Tap **Go offline**.
2. Tap **Generate sample logs** to create info, warning, error, and private-metadata events.
3. Tap **Flush and replay queue** and confirm one encrypted batch remains queued.
4. Tap **Go online**, then flush again. The queued count returns to zero and the delivered event count reaches four.
5. Tap **Export encrypted local logs** to display the temporary export directory.

The mock transport stores delivered batches in memory and never contacts an external service. Local rolling files and the offline disk queue use AES-GCM encryption; the live examples keep their encryption key in Keychain.

Regenerate the committed project after changing `project.yml`:

```bash
xcodegen generate --spec Examples/KVLoggingKitExample/project.yml
```

Build or test from the command line:

```bash
xcodebuild -quiet \
  -scheme ExampleSupportTests \
  -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test

xcodebuild -quiet \
  -scheme UIKitExample \
  -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet \
  -scheme SwiftUIExample \
  -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

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
- Private fields reach encrypted local storage, are handed to the unified log as
  private data, and become `<redacted>` before remote delivery.
- Message text and error descriptions are scrubbed by `LogRedaction` on the way
  to a remote transport, because declaring a field private does nothing for the
  same value pasted into the message string.
- `LogRedaction.default` matches bearer tokens, `key=value` credential pairs, and
  email addresses. Phone numbers are opt-in via `.includingPhoneNumbers`: a bare
  run of digits is indistinguishable from a duration, an identifier, or a
  timestamp, so matching them by default corrupts ordinary messages.
- `PrivacyProcessor.strict` additionally drops metadata keys outside its
  allowlist. It unions in the `DeviceContextProcessor` keys, so device context is
  never dropped by accident, and it must run after the processors whose keys it
  should keep.
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

## Network logging

`KVLoggingNetwork` captures API calls so they can be inspected on the device
while using the app, and exported as a `curl` command.

Apple ships no in-app network inspector. The two supported hooks are
`URLSessionTaskDelegate` and `URLProtocol`, and this module offers both because
they capture different things:

| | `NetworkLoggingDelegate` | `NetworkLoggingURLProtocol` |
| --- | --- | --- |
| Mechanism | Official delegate API | `URLSessionConfiguration.protocolClasses` |
| Request/response bodies | Only for delegate-based data tasks | Yes |
| `URLSessionTaskMetrics` timings | Yes | Yes |
| Shows requests while in flight | No, records on completion | Yes |
| Overhead | None | One replay `URLSession` per request |
| Background sessions | Yes | No, `URLProtocol` is ignored there |
| Suitable for release builds | Yes | Debug only |

Neither mode changes what the app receives: the response is passed through
untouched.

### Debug builds: capture bodies

```swift
import KVLoggingNetwork

#if DEBUG
NetworkLoggingURLProtocol.settings = .init(
    recorder: NetworkLogRecorder(logger: logger),
    // Otherwise uploading logs would generate more logs.
    shouldCapture: { $0.url?.host != "logs.example.com" }
)
NetworkLoggingURLProtocol.install(in: apiSessionConfiguration)
#endif
```

`install(in:)` covers sessions built from that configuration. To also cover
`URLSession.shared` and sessions the app builds elsewhere:

```swift
#if DEBUG
NetworkLoggingURLProtocol.installGlobally(swizzlingSessionConfigurations: true)
#endif
```

`swizzlingSessionConfigurations` exchanges the implementation of
`URLSessionConfiguration.protocolClasses` process-wide. Keep it inside
`#if DEBUG`.

### Release builds: timing and status only

```swift
let session = URLSession.networkLogging(
    configuration: .default,
    recorder: NetworkLogRecorder(
        redactor: .headersAndBodiesOff,
        logger: logger
    ),
    delegate: existingDelegate   // forwarded transparently
)
```

### What leaves the device

Headers and bodies stay in `NetworkLogStore`, an in-memory ring that never
touches disk. Each finished exchange also emits one `LogEvent` on the `network`
category carrying method, host, path, status, duration, and byte count — and
nothing else. Turning network logging on therefore never widens what remote
destinations receive.

Within the store, `NetworkLogRedactor` replaces credential-bearing headers
(`Authorization`, `Cookie`, `Set-Cookie`, …), query items (`access_token`,
`api_key`, …), and JSON body keys at any depth (`password`, `refresh_token`, …)
with `<redacted>`, caps bodies at 32 KB, and pretty-prints JSON. Extend the
lists for app-specific fields:

```swift
var redactor = NetworkLogRedactor.default
redactor.redactedBodyKeys.insert("device_fingerprint")
redactor.redactedHeaderFields.insert("x-signature")
```

## Debug console

`KVLoggingConsole` shows log events and captured API calls in one screen, on the
device, while using the app.

### Minimal setup

Console logging plus network capture, nothing else — no files, no remote, no
encryption:

```swift
import KVLoggingKit
import KVLoggingLocal     // SystemLogDestination
import KVLoggingConsole

enum Logging {
    static let client: LogClient = {
        // 1. Install the console. Returns the destination, or nil when the
        //    policy denies access.
        var destinations: [any LogDestination] = [SystemLogDestination()]
        if let console = LogConsole.install(
            policy: .debugOrBundleIdentifiers(["varmeta.test.app"])
        ) {
            destinations.append(console)
        }

        // 2. Build the client.
        let client = LogClient(
            configuration: .init(minimumLevel: .debug),
            destinations: destinations
        )

        // 3. Capture network traffic into the Network tab and the log
        //    pipeline. No-op when the console was not installed.
        LogConsole.startNetworkCapture(logger: client)

        return client
    }()
}
```

That is the whole integration. Shake the device to open the console;
`LogConsole.present()` opens it from a debug menu.

Use it like any logger:

```swift
Logging.client.info("Profile loaded", category: "profile")
```

Nothing else has to change for network capture — with the default
`.allSessions` scope, `URLSession.shared` and any session the app or an SDK
creates are captured as they are.

### Scoping network capture

```swift
LogConsole.startNetworkCapture(
    logger: client,
    scope: .allSessions,            // or .sharedSessionOnly, or .manual
    excluding: { $0.url?.host != "logs.example.com" }
)
```

| Scope | Reaches | Swizzles |
| --- | --- | --- |
| `.allSessions` | `URLSession.shared` and every session built from a configuration | `URLSessionConfiguration.protocolClasses` |
| `.sharedSessionOnly` | `URLSession.shared` | no |
| `.manual` | Only what you register yourself | no |

With `.manual`, opt individual sessions in:

```swift
NetworkLoggingURLProtocol.install(in: myConfiguration)
```

Swizzling happens only after the access policy has already allowed the console,
so it never runs in a build that cannot show it. Exclude the log-upload endpoint
if you have one, otherwise uploading logs generates more logs.

### Access policy

The console is compiled into the binary either way, so the gate is a runtime
check. `DebugAccessPolicy` passes when **any** rule matches:

| Rule | Passes when |
| --- | --- |
| `.debugBuild` | The package was compiled with `DEBUG`, which for a source-integrated SPM dependency follows the app's configuration |
| `.bundleIdentifiers([...])` | `Bundle.main.bundleIdentifier` is in the set — for internal or TestFlight builds |
| `.environmentVariable(name)` | The variable is set and is not `"0"` |
| `.custom { ... }` | Your own predicate, e.g. a remote flag |

When the policy denies access, `install` returns `nil` and registers nothing —
no shake handler, no swizzling, no window, and no store retaining events. That
is what keeps the console free in production rather than merely inert. Leaving
the destination out of the array is the point; do not add an empty one.

### What it shows

**Logs** — level badge, category, message, timestamp; filter by minimum level
and category; full-text search across message, category, and metadata. The
detail screen marks which metadata fields are `.private`, so it is visible at a
glance which values are withheld from remote destinations and from the unified
log.

**Network** — status, method, path, host, duration; filter by success or error.
The detail screen has the timing breakdown (DNS, connect, TLS, time to first
byte), both header sets, both bodies, and a copyable `curl` command. Redacted
values keep their placeholder there, so it is safe to paste into a bug report
but needs the real credential filled in before it will run.

Both tabs export the currently visible rows to the clipboard or the share sheet.

### Cost when open

Stores are fixed-capacity ring buffers — appending is O(1) with no allocation,
and nothing is written to disk. The stores publish a change *signal* rather than
their contents, and each signal stream keeps only the newest value, so a burst
of a thousand events wakes the UI once instead of copying the buffer a thousand
times. Views additionally coalesce refreshes to at most one per 150 ms.

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

URLSession
   │ URLProtocol interception, or URLSessionTaskDelegate observation
   ▼
NetworkLogRecorder ──┬─ redacted record → NetworkLogStore → on-device viewer
                     └─ summary LogEvent → LogClient (category "network")
```

Destination failures are isolated by `LogClient`. Supply `internalErrorHandler` in `LogConfiguration` when the host application needs diagnostics about logging infrastructure failures.
