# KVLoggingKit Design

## Goal

Build a zero-third-party-dependency Swift logging package for UIKit applications on iOS 13+ and SwiftUI applications on iOS 16+. The package supports structured local logs, encrypted rolling files, batched remote delivery, offline persistence, privacy filtering, dependency injection, and testing utilities.

## Package Products

- `KVLoggingKit`: Core event model, synchronous logging facade, processors, scoped loggers, and destination protocols.
- `KVLoggingSecurity`: AES-GCM encryption and Keychain-backed key providers.
- `KVLoggingLocal`: Apple unified logging and encrypted rolling files.
- `KVLoggingRemote`: Batched transports, retry policy, encrypted disk queue, and generic HTTP delivery.
- `KVLoggingUIKit`: UIKit lifecycle integration for background flushing on iOS 13+.
- `KVLoggingSwiftUI`: Environment injection and scene-phase flushing on iOS 16+.
- `KVLoggingTesting`: In-memory destination for application tests.

## Core API

Applications create one `LogClient`, inject it into services or UI, and call synchronous methods such as `info`, `warning`, and `error`. Calls enqueue immutable `LogEvent` values into an `AsyncStream`; a single worker processes events in order without blocking the caller. `flush()` is asynchronous and waits until previously enqueued events and every destination have completed.

Each event contains a level, message, optional category, structured metadata, captured error, source location, timestamp, and identifier. A scoped logger adds common category and metadata without introducing global singletons.

## Privacy

`PrivacyProcessor.strict` applies an allowlist to metadata and redacts common bearer-token, email, and phone patterns from messages. Metadata fields explicitly declare public or private visibility. Local encrypted storage may preserve private values; remote destinations replace private values with `<redacted>` before transport.

No request bodies, credentials, tokens, or passwords are collected automatically. Unknown metadata keys are dropped in strict mode.

## Local Storage

`SystemLogDestination` writes to Apple's unified logging system, using `Logger` where available and `os_log` as the iOS 13 fallback.

`RollingFileDestination` writes one encoded event per line, rotates at a configured byte limit, removes expired files, and caps retained file count. A caller-provided `LogDataCipher` controls at-rest encryption. `AESGCMLogCipher` uses a 256-bit key supplied by either Keychain or a custom provider.

## Remote Delivery

`RemoteBatchDestination` accumulates sanitized events until the batch size or flush interval is reached. It retries transient transport errors using bounded exponential backoff. If delivery still fails, it persists the batch through `LogBatchQueue`; `DiskLogBatchQueue` encrypts each queued batch and replays oldest-first on the next flush.

`LogTransport` keeps the core independent of Sentry, Datadog, Firebase, or a company backend. `HTTPLogTransport` is the built-in generic transport; SDK-specific adapters can conform to the same protocol in separate packages.

## UI Integration

UIKit applications retain `UIKitLoggingLifecycle`, which observes background and termination notifications and requests a flush. SwiftUI applications apply `.kvLogging(client)` at the root; the modifier injects the client through `EnvironmentValues` and flushes when `scenePhase` becomes background.

Business services should receive `LogClient` through initializers in both UI frameworks. The environment integration is a convenience for SwiftUI views, not a replacement for dependency injection.

## Error Handling

Logging must never crash the host application. Destination failures are isolated and reported to an optional internal error handler. Remote delivery failures are queued when persistence succeeds. Corrupt queue files are reported and skipped without blocking newer logs. `.disabled` is a safe no-op fallback when bootstrap fails.

## Testing

- Core tests verify level filtering, ordering, scoped metadata, processors, error capture, and flush semantics.
- Privacy tests verify allowlisting and redaction.
- Local tests verify rolling files and that AES-GCM output does not contain plaintext.
- Remote tests verify batching, retries, sanitization, and offline replay.
- Platform targets receive compile checks through `xcodebuild` for an iOS Simulator destination.
- `swift test` validates platform-neutral behavior on the host.

## Non-goals

- Crash capture and symbolication.
- Analytics, traces, and metrics.
- A hosted logging backend.
- Direct dependencies on third-party observability SDKs.
- Uploading arbitrary request or response bodies.
