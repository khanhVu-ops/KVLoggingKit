# KVLoggingKit Example Apps Design

## Goal

Add one self-contained Xcode project demonstrating how to integrate KVLoggingKit into both a UIKit application targeting iOS 13 and a SwiftUI application targeting iOS 16. The examples must run without a logging backend, API key, or third-party dependency.

## Project Structure

The example lives under `Examples/KVLoggingKitExample` and contains one Xcode project with two application schemes:

- `UIKitExample`: UIKit lifecycle, deployment target iOS 13.
- `SwiftUIExample`: SwiftUI app lifecycle, deployment target iOS 16.

Both targets compile shared files from `Shared` and reference package products through a local Swift package dependency pointing to the repository root.

```text
Examples/KVLoggingKitExample/
├── KVLoggingKitExample.xcodeproj
├── Shared/
│   ├── ExampleLoggingService.swift
│   ├── MockLogTransport.swift
│   └── SampleError.swift
├── UIKitExample/
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   ├── LoggingViewController.swift
│   └── Info.plist
└── SwiftUIExample/
    ├── SwiftUIExampleApp.swift
    ├── LoggingExampleView.swift
    └── Info.plist
```

## Shared Logging Service

`ExampleLoggingService` owns the `LogClient`, encrypted `RollingFileDestination`, encrypted `DiskLogBatchQueue`, and `MockLogTransport`. It exposes small methods for UI code:

- Generate info, warning, error, and private-metadata sample events.
- Toggle simulated connectivity.
- Flush all destinations.
- Refresh a snapshot containing remote batch count, queued batch count, retained file count, and current connectivity.
- Export retained files to a fresh temporary directory.

Bootstrap uses `KeychainLogEncryptionKeyProvider`, `AESGCMLogCipher`, `DeviceContextProcessor`, and `PrivacyProcessor.strict`. If bootstrap fails, the service retains `.disabled` and reports the bootstrap error through its snapshot instead of crashing either app.

## Mock Remote Transport

`MockLogTransport` conforms to `LogTransport`. In online mode it stores successfully delivered batches in memory. In offline mode it throws a deterministic `offline` error, allowing `RemoteBatchDestination` to exercise retry and encrypted disk persistence without real networking.

The mock provides actor-isolated methods for toggling connectivity and reading delivered batches. The example never logs secrets or contacts an external host.

## UIKit Example

`AppDelegate` creates the shared service and retains `UIKitLoggingLifecycle`. `SceneDelegate` injects the service into `LoggingViewController`.

The view controller is built programmatically to avoid storyboard maintenance. It contains:

- A status panel with connectivity, remote batch, queued batch, and local file counts.
- Buttons for generating sample logs, toggling offline mode, flushing, and exporting.
- A text view showing the latest action and export path.

All asynchronous work starts from button actions in `Task` blocks. UI state updates occur on the main actor.

## SwiftUI Example

`SwiftUIExampleApp` creates the service and applies `.kvLogging(service.logger)` at the root. `LoggingExampleView` reads the same client through `@Environment(\.logClient)` for direct view-level logging while using the service for mock connectivity, snapshots, and export.

The SwiftUI screen presents the same information and actions as the UIKit app with native `Form`, `Section`, `Button`, and status text components available on iOS 16.

## Data Flow

```text
Example UI action
    ├─ LogClient synchronous event
    └─ ExampleLoggingService async operation
              │
              ▼
       processor chain
              │
       ┌──────┴───────────┐
       ▼                  ▼
encrypted rolling file   RemoteBatchDestination
                              │
                      MockLogTransport offline?
                         ├─ yes → encrypted disk queue
                         └─ no  → in-memory delivered batches
```

## Error Handling

- Bootstrap errors produce a disabled logger and visible status text.
- Log destination errors never terminate the host application.
- Export errors are displayed in the latest-action area.
- Mock offline errors are expected behavior and are persisted by the remote destination.
- Example actions do not force unwrap runtime file paths or package state.

## Project Generation

Both `project.yml` and the generated `.xcodeproj` are committed. `project.yml` keeps target and package settings reviewable, while the committed Xcode project lets users open and build the examples without installing or running XcodeGen.

## Documentation

The root README gains a “Run the examples” section describing both schemes, deployment targets, expected offline/replay behavior, and the fact that the package is referenced locally.

## Verification

- Build `UIKitExample` for a generic iOS Simulator destination.
- Build `SwiftUIExample` for a generic iOS Simulator destination.
- Run the package's existing 32-test suite to ensure the examples do not regress library behavior.
- Confirm both schemes resolve the local package without network access.
- Confirm the repository contains no API key, endpoint secret, unfinished marker, or generated build output.

## Non-goals

- UI test automation.
- A production monitoring dashboard.
- Sending data to a real remote service.
- Demonstrating Sentry, Datadog, Firebase, or OpenTelemetry SDKs.
- Shipping the example applications to the App Store.
