# KVLoggingKit Example Apps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one buildable Xcode project with UIKit iOS 13 and SwiftUI iOS 16 example applications that demonstrate local, encrypted, privacy-safe, batched, offline-capable logging.

**Architecture:** An internal `ExampleSupport` framework compiles `ExampleLoggingService` and `MockLogTransport` once for both apps and the test target. The service bootstraps real KVLoggingKit local and remote destinations, while the mock transport deterministically switches between successful in-memory delivery and offline errors.

**Tech Stack:** Swift 6, UIKit, SwiftUI, XcodeGen 2.45, XCTest, KVLoggingKit local package products.

---

## File Map

- `Examples/KVLoggingKitExample/project.yml`: XcodeGen source of truth for targets, schemes, deployment versions, and local package products.
- `Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj`: Generated project committed for users who do not have XcodeGen.
- `Examples/KVLoggingKitExample/Shared/MockLogTransport.swift`: Actor-backed online/offline transport in the `ExampleSupport` framework.
- `Examples/KVLoggingKitExample/Shared/ExampleLoggingService.swift`: Logger bootstrap and example actions shared by both apps.
- `Examples/KVLoggingKitExample/Shared/SampleError.swift`: Deterministic error used by sample events.
- `Examples/KVLoggingKitExample/UIKitExample/*`: UIKit app and programmatic screen.
- `Examples/KVLoggingKitExample/SwiftUIExample/*`: SwiftUI app and logging screen.
- `Examples/KVLoggingKitExample/ExampleSupportTests/*`: Shared service behavior tests hosted by the UIKit example target.
- `README.md`: Instructions for opening and running both schemes.

### Task 1: Generate the project and establish failing shared-service tests

**Files:**
- Create: `Examples/KVLoggingKitExample/project.yml`
- Create: `Examples/KVLoggingKitExample/ExampleSupportTests/ExampleLoggingServiceTests.swift`
- Generate: `Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj`

- [ ] **Step 1: Define both app targets and the test target**

Create `project.yml` with local package path `../..`, an iOS 13 `ExampleSupport` framework, UIKit deployment `13.0`, SwiftUI deployment `16.0`, explicit Info.plists, and dependencies on the required KVLoggingKit products.

- [ ] **Step 2: Write failing behavior tests**

```swift
final class ExampleLoggingServiceTests: XCTestCase {
    func testOnlineFlushDeliversAllSampleEvents() async throws {
        let harness = try ExampleLoggingService.makeTestHarness()
        harness.service.generateSampleLogs()
        let snapshot = await harness.service.flushAndSnapshot()
        XCTAssertEqual(snapshot.deliveredEventCount, 4)
        XCTAssertEqual(snapshot.queuedBatchCount, 0)
    }

    func testOfflineBatchQueuesThenReplaysWhenOnline() async throws {
        let harness = try ExampleLoggingService.makeTestHarness()
        await harness.service.setOnline(false)
        harness.service.generateSampleLogs()
        let offline = await harness.service.flushAndSnapshot()
        XCTAssertEqual(offline.queuedBatchCount, 1)

        await harness.service.setOnline(true)
        let online = await harness.service.flushAndSnapshot()
        XCTAssertEqual(online.queuedBatchCount, 0)
        XCTAssertEqual(online.deliveredEventCount, 4)
    }
}
```

- [ ] **Step 3: Generate the Xcode project**

Run: `xcodegen generate --spec Examples/KVLoggingKitExample/project.yml`

Expected: `KVLoggingKitExample.xcodeproj` is generated without warnings.

- [ ] **Step 4: Verify tests fail for missing shared types**

Run: `xcodebuild -scheme ExampleSupportTests -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`

Expected: FAIL because `ExampleLoggingService` does not exist.

### Task 2: Implement shared logging support

**Files:**
- Create: `Examples/KVLoggingKitExample/Shared/MockLogTransport.swift`
- Create: `Examples/KVLoggingKitExample/Shared/ExampleLoggingService.swift`
- Create: `Examples/KVLoggingKitExample/Shared/SampleError.swift`
- Test: `Examples/KVLoggingKitExample/ExampleSupportTests/ExampleLoggingServiceTests.swift`

- [ ] **Step 1: Implement deterministic mock transport**

```swift
actor MockLogTransport: LogTransport {
    enum TransportError: Error { case offline }
    private var isOnline = true
    private var batches: [[LogEvent]] = []

    func send(_ events: [LogEvent]) async throws {
        guard isOnline else { throw TransportError.offline }
        batches.append(events)
    }

    func setOnline(_ value: Bool) { isOnline = value }
    func snapshot() -> [[LogEvent]] { batches }
    func onlineState() -> Bool { isOnline }
}
```

- [ ] **Step 2: Implement the service and snapshot model**

Use these concrete public-to-the-example signatures:

```swift
struct ExampleSnapshot: Sendable {
    let isOnline: Bool
    let deliveredBatchCount: Int
    let deliveredEventCount: Int
    let queuedBatchCount: Int
    let localFileCount: Int
    let bootstrapError: String?
    static let empty: ExampleSnapshot
}

struct ExampleTestHarness {
    let service: ExampleLoggingService
    let rootDirectory: URL
}

struct ExampleLoggingService: Sendable {
    let logger: LogClient
    private let transport: MockLogTransport
    private let queue: any LogBatchQueue
    private let localFiles: RollingFileDestination?
    private let bootstrapError: String?

    static func live() -> ExampleLoggingService
    static func makeTestHarness() throws -> ExampleTestHarness
    func generateSampleLogs()
    func setOnline(_ value: Bool) async
    func snapshot() async -> ExampleSnapshot
    func flushAndSnapshot() async -> ExampleSnapshot
    func exportLocalLogs() async throws -> URL
}
```

Configure `RemoteBatchDestination` with `maxBatchSize: 4`, `flushInterval: 5`, and one zero-delay retry in the test harness. `generateSampleLogs()` emits exactly four events: info, warning with public duration, error with `SampleError`, and profile info with private email metadata. Production bootstrap uses Keychain/AES-GCM; test bootstrap uses a static 32-byte key and temporary directories.

- [ ] **Step 3: Run shared tests**

Run the Task 1 `xcodebuild ... test` command.

Expected: 2 tests pass with 0 failures.

- [ ] **Step 4: Commit shared support**

```bash
git add Examples/KVLoggingKitExample
git commit -m "feat: add shared logging example service"
```

### Task 3: Build the UIKit iOS 13 example

**Files:**
- Create: `Examples/KVLoggingKitExample/UIKitExample/AppDelegate.swift`
- Create: `Examples/KVLoggingKitExample/UIKitExample/SceneDelegate.swift`
- Create: `Examples/KVLoggingKitExample/UIKitExample/LoggingViewController.swift`
- Create: `Examples/KVLoggingKitExample/UIKitExample/Info.plist`

- [ ] **Step 1: Add UIKit lifecycle integration**

`AppDelegate` creates `ExampleLoggingService.live()` and retains `UIKitLoggingLifecycle`. `SceneDelegate` reads that service and injects it into `LoggingViewController`.

```swift
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let loggingService = ExampleLoggingService.live()
    private var loggingLifecycle: UIKitLoggingLifecycle?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        loggingLifecycle = UIKitLoggingLifecycle(
            application: application,
            logger: loggingService.logger
        )
        return true
    }
}
```

- [ ] **Step 2: Build the programmatic screen**

The screen must display connectivity, delivered event count, queued batch count, local file count, and latest action. Buttons call generate, toggle connectivity, flush, and export operations.

Use one vertical `UIStackView`, a multiline status label, four `UIButton.Configuration.filled()` buttons when available with iOS 13-compatible `.system` button fallback, and a read-only `UITextView` for the latest action. Every async action calls a single `refresh(using:)` method after completion.

- [ ] **Step 3: Build the UIKit scheme**

Run: `xcodebuild -quiet -scheme UIKitExample -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: BUILD SUCCEEDED with an iOS 13.0 deployment target.

- [ ] **Step 4: Commit the UIKit example**

```bash
git add Examples/KVLoggingKitExample/UIKitExample Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj
git commit -m "feat: add UIKit logging example"
```

### Task 4: Build the SwiftUI iOS 16 example

**Files:**
- Create: `Examples/KVLoggingKitExample/SwiftUIExample/SwiftUIExampleApp.swift`
- Create: `Examples/KVLoggingKitExample/SwiftUIExample/LoggingExampleView.swift`
- Create: `Examples/KVLoggingKitExample/SwiftUIExample/Info.plist`

- [ ] **Step 1: Add SwiftUI lifecycle and Environment injection**

```swift
@main
struct SwiftUIExampleApp: App {
    private let service = ExampleLoggingService.live()

    var body: some Scene {
        WindowGroup {
            LoggingExampleView(service: service)
                .kvLogging(service.logger)
        }
    }
}
```

- [ ] **Step 2: Build the SwiftUI screen**

Use `Form` sections for status and actions. Read `@Environment(\.logClient)` for a direct view-level log action, and use the service for connectivity, flush, snapshot, and export operations.

```swift
struct LoggingExampleView: View {
    @Environment(\.logClient) private var logger
    let service: ExampleLoggingService
    @State private var snapshot = ExampleSnapshot.empty
    @State private var latestAction = "Ready"

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                actionSection
                Section("Latest action") { Text(latestAction) }
            }
            .navigationTitle("KVLoggingKit")
            .task { await refresh() }
        }
    }
}
```

Add `ExampleSnapshot.empty` so both initial UI state and previews avoid asynchronous bootstrap assumptions.

- [ ] **Step 3: Build the SwiftUI scheme**

Run: `xcodebuild -quiet -scheme SwiftUIExample -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: BUILD SUCCEEDED with an iOS 16.0 deployment target.

- [ ] **Step 4: Commit the SwiftUI example**

```bash
git add Examples/KVLoggingKitExample/SwiftUIExample Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj
git commit -m "feat: add SwiftUI logging example"
```

### Task 5: Documentation and final verification

**Files:**
- Modify: `README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Document how to run both schemes**

Add commands and expected offline flow: generate logs while offline, flush to encrypted queue, switch online, flush again, and observe delivered counts.

- [ ] **Step 2: Ignore Xcode user state without ignoring the committed project**

Add `*.xcuserstate` and project `xcuserdata` patterns while retaining `.xcodeproj/project.pbxproj` and shared schemes.

- [ ] **Step 3: Run full verification**

Run:

```bash
swift test --disable-sandbox
xcodebuild -quiet -scheme ExampleSupportTests -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -quiet -scheme UIKitExample -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -scheme SwiftUIExample -project Examples/KVLoggingKitExample/KVLoggingKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: existing 32 package tests pass, 2 example tests pass, and both app schemes build successfully.

- [ ] **Step 4: Scan and commit**

Verify no secrets, unfinished markers, build output, or Xcode user state are tracked, then commit:

```bash
git add README.md .gitignore Examples docs/superpowers/plans/2026-08-11-kvloggingkit-example.md
git commit -m "docs: add example app instructions"
```
