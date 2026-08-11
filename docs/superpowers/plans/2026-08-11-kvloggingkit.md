# KVLoggingKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a production-ready modular logging package for UIKit iOS 13+ and SwiftUI iOS 16+ with privacy-safe local and remote delivery.

**Architecture:** A synchronous `LogClient` publishes immutable events into one ordered asynchronous worker. Processors normalize and filter events before fan-out to modular local and remote destinations; optional UI targets only manage injection and lifecycle flushing.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, OSLog, CryptoKit, Security, UIKit, SwiftUI, XCTest.

---

## File Map

- `Package.swift`: Products, deployment targets, target dependencies, and Swift 6 mode.
- `Sources/KVLoggingKit/*`: Core models, protocols, processor chain, client, and scoped logger.
- `Sources/KVLoggingSecurity/*`: AES-GCM cipher and key providers.
- `Sources/KVLoggingLocal/*`: System log and rolling file destinations.
- `Sources/KVLoggingRemote/*`: Batch policy, queue, destination, and HTTP transport.
- `Sources/KVLoggingUIKit/*`: UIKit lifecycle observer.
- `Sources/KVLoggingSwiftUI/*`: SwiftUI environment and root modifier.
- `Sources/KVLoggingTesting/*`: In-memory destination.
- `Tests/*`: Behavior tests for each non-UI product.
- `README.md`: Installation, bootstrap, UIKit, SwiftUI, privacy, export, and adapter examples.

### Task 1: Package skeleton and core event model

- [ ] Write `KVLoggingCoreTests` for level ordering, metadata values, error capture, and remote redaction before creating core types.
- [ ] Run `swift test --filter KVLoggingCoreTests` and verify compilation fails because `LogEvent`, `LogLevel`, and `LogField` do not exist.
- [ ] Add `Package.swift`, `LogLevel.swift`, `LogValue.swift`, and `LogEvent.swift` with Codable and Sendable conformance.
- [ ] Run the filtered test and verify it passes.
- [ ] Commit with `feat: add structured log event model`.

### Task 2: Ordered client pipeline

- [ ] Write tests using a recording destination to prove minimum-level filtering, enqueue ordering, processor drops, scoped metadata merging, and that `flush()` waits for prior events.
- [ ] Run the tests and verify failures reference missing `LogClient`, `LogDestination`, and `LogProcessor` APIs.
- [ ] Implement the protocols, configuration, `AsyncStream` command worker, synchronous convenience methods, and `ScopedLogClient`.
- [ ] Run all core tests and verify they pass without warnings.
- [ ] Commit with `feat: add ordered asynchronous logging pipeline`.

### Task 3: Privacy processor

- [ ] Write tests proving strict allowlisting, bearer-token redaction, email redaction, phone redaction, and preservation of allowed private field values for encrypted local storage.
- [ ] Run the tests and verify they fail because `PrivacyProcessor` is missing.
- [ ] Implement `PrivacyProcessor` and `StaticContextProcessor` as Sendable value types.
- [ ] Run privacy and core tests and verify they pass.
- [ ] Commit with `feat: add privacy-first log processors`.

### Task 4: Encryption support

- [ ] Write security tests proving AES-GCM round trips, random nonces produce different ciphertext, invalid ciphertext throws, and static keys require 32 bytes.
- [ ] Run the tests and verify the cipher types are missing.
- [ ] Implement `LogDataCipher`, `NoEncryptionCipher`, `AESGCMLogCipher`, `StaticLogEncryptionKeyProvider`, and `KeychainLogEncryptionKeyProvider`.
- [ ] Run security tests and verify they pass.
- [ ] Commit with `feat: add AES-GCM and Keychain log encryption`.

### Task 5: Local destinations

- [ ] Write local tests proving JSONL writes, encrypted output lacks plaintext, size rotation creates bounded files, retention removes old files, and export copies retained logs.
- [ ] Run the tests and verify local destination types are missing.
- [ ] Implement `SystemLogDestination`, `RollingFilePolicy`, and actor-isolated `RollingFileDestination`.
- [ ] Run local tests and verify they pass.
- [ ] Commit with `feat: add system and encrypted rolling file logs`.

### Task 6: Remote batching and offline queue

- [ ] Write remote tests proving threshold batching, private-field sanitization, bounded retry, failed-batch persistence, oldest-first replay, and explicit flush.
- [ ] Run the tests and verify remote types are missing.
- [ ] Implement `LogTransport`, `RemoteBatchPolicy`, `RetryPolicy`, `LogBatchQueue`, `MemoryLogBatchQueue`, `DiskLogBatchQueue`, and `RemoteBatchDestination`.
- [ ] Add `HTTPLogTransport` with JSON encoding, configurable headers, and 2xx status validation.
- [ ] Run remote tests and the full suite and verify they pass.
- [ ] Commit with `feat: add batched remote logging with offline replay`.

### Task 7: UIKit, SwiftUI, and testing integrations

- [ ] Write tests for `InMemoryLogDestination` snapshots and clear behavior.
- [ ] Run tests and verify the testing destination is missing.
- [ ] Implement `KVLoggingTesting`, `UIKitLoggingLifecycle`, `EnvironmentValues.logClient`, and `.kvLogging(_:)` scene-phase modifier with correct availability annotations.
- [ ] Run `swift test` and an iOS Simulator `xcodebuild` compile check.
- [ ] Commit with `feat: add UIKit and SwiftUI integrations`.

### Task 8: Documentation and final verification

- [ ] Write `README.md` with exact SPM products and copy-paste bootstrap, UIKit, SwiftUI, scoped logging, privacy, flush, export, HTTP, and custom adapter examples.
- [ ] Run placeholder-marker and forced-termination scans in package sources and documentation.
- [ ] Run `swift test`, `swift build`, and the iOS Simulator compile check from a clean package state.
- [ ] Review public symbols for iOS availability and Swift 6 Sendable diagnostics.
- [ ] Commit with `docs: add KVLoggingKit usage guide`.
