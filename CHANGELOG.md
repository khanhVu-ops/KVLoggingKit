# Changelog

All notable changes to KVLoggingKit are documented in this file.

## 1.2.0 - Unreleased

### Fixed

- **`NetworkLoggingURLProtocol` sent every request body empty.** With capture on
  — including a plain `LogConsole.install()` plus `startNetworkCapture`, whose
  default `.allSessions` scope reaches every session in the process — any
  request that had a body reached the server without one: JSON posts, form
  submissions, multipart and image uploads alike. It was first reported as
  streamed uploads above 1 MB arriving truncated, which the code also did, but
  the second bug hid the first.

  The loading system hands a `URLProtocol` its body as `httpBodyStream` even
  when the app set `httpBody`, so every body took the stream path. That path
  read at most `maximumCapturedResponseBytes` (1 MB) of the stream, assigned the
  bytes to `httpBody`, and then assigned `httpBodyStream = nil`. The two
  properties are one slot in `NSURLRequest` — assigning either clears the other
  — so the second assignment erased the body that had just been put back.

  The stream is now read until `read` returns 0 and forwarded whole; a read
  error fails the request rather than sending part of the body. Buffering the
  body is unavoidable, since the replay is a second request that must send it
  again, so an upload is held in memory once while in flight. The log still
  stores only the redactor's capped copy (`maximumBodyByteCount`, 32 KB by
  default), now with the real byte count. `maximumCapturedResponseBytes` limits
  responses only, as its name always said.

  Interception first worked in 1.1.0 (see below), so 1.1.0 is the affected
  release. Verified on macOS and the iOS 26.2 simulator: the new tests fail
  against 1.1.0 with the server receiving 0 bytes, and pass now — for `httpBody`,
  in-memory and file-backed `httpBodyStream`, and `upload(for:from:)` /
  `upload(for:fromFile:)`, up to 3 MB, byte for byte.

- **Console list models leaked.** `LogListModel` and `NetworkListModel` captured
  `self` strongly in their observation task, so the task kept the model alive
  and `deinit` never ran to cancel it; only the list's `onDisappear` broke the
  cycle. They now capture `self` weakly.

### Changed

- **`SystemLogDestination` writes on the calling thread.** Before, the unified
  log was batched with every other destination: entries reached the Xcode
  console up to `batchInterval` (200 ms) late, from the worker's thread, and
  anything still batched when the process died was lost — usually the lines
  that explain the crash. They are now written before the log call returns.
  `SystemLogDestination(mode: .batched)` restores the old behaviour.

  The processor chain runs on the calling thread for this, once per event, and
  batched destinations receive the same processed event. That requires every
  processor to be a `SynchronousLogProcessor`; the built-in ones are. With any
  async-only processor in the chain the unified log stays batched, because an
  event must never reach a sink before its redaction has run.

  Xcode still shows `SystemLogDestination.swift` as each entry's source
  location: `os_log` records the address it was called from, and a wrapper
  cannot pass its caller's through.

### Added

- `ImmediateLogDestination` — a destination `LogClient` writes on the calling
  thread (`writeImmediately(_:)`), with `writesImmediately` to opt out.
  `SystemLogDestination` conforms.
- `SynchronousLogProcessor` — `processSynchronously(_:)`, with `process(_:)`
  provided. `PrivacyProcessor`, `DeviceContextProcessor` and
  `StaticContextProcessor` conform.
- `SystemLogDestination.Mode` and the `mode:` initializer parameter, defaulting
  to `.immediate`.

Source compatible with 1.1.0: every new parameter has a default, and existing
`LogProcessor` and `LogDestination` conformances keep working unchanged.

### Documentation

- The README and `NetworkCaptureScope.allSessions` spell out what the default
  capture scope does to the process: every session afterwards, SDKs' included,
  is intercepted and replayed with its body buffered, until relaunch. The
  default is unchanged.

## 1.1.0 - 2026-08-14

### Fixed

- `NetworkLoggingURLProtocol.installGlobally(swizzlingSessionConfigurations: true)`
  no longer terminates the process on iOS 26. The first request through any
  session built from its own `URLSessionConfiguration` died in CFNetwork:

  ```
  +[NSURLSessionConfiguration canInitWithTask:]: unrecognized selector sent to class
    -[__NSURLSessionLocal _protocolClassForTask:skipAppSSO:]
  ```

  The replacement for the `protocolClasses` getter was a Swift `@objc` method on
  `NetworkLoggingURLProtocol` returning a bridged `[AnyClass]?`, installed with
  `method_exchangeImplementations`. Once installed it ran with `self` bound to a
  `URLSessionConfiguration`, and the list it produced was corrupt: the protocol
  class did not survive the return — it read back as `NSURLSessionConfiguration`,
  which is not a `URLProtocol` subclass and answers neither `+canInitWithTask:`
  nor `+canInitWithRequest:` — and one more bogus entry was prepended on every
  read, so the list grew without bound. CFNetwork asks every entry whether it can
  handle the task, so it sent that selector to a configuration class and the app
  went down.

  The replacement is now a free `@convention(c)` function returning `NSArray` at
  +0 autoreleased, which is the contract an ObjC getter actually has. A Swift
  `@objc` method is the wrong tool here: its thunk is entitled to assume `self` is
  an instance of the class that declares it. `method_exchangeImplementations` was
  not at fault — an exchange with a correctly typed C function is clean — but the
  install now uses `class_replaceMethod`, which adds the method to the class it is
  given when the implementation is inherited, so a superclass is never edited
  process-wide. The implementation to chain to is captured before installing;
  doing it after leaves a window where the getter answers with this protocol alone
  and drops `_NSURLHTTPProtocol` and the rest, breaking networking rather than
  logging it.

  Two things worth knowing beyond the crash. **Interception never worked at all**
  — the protocol appeared in `protocolClasses` zero times, on iOS 18 as well as
  26, so this was never a working feature that iOS 26 regressed; iOS 26 only
  turned silent failure into termination. And the blast radius was wider than the
  flag: `LogConsole`'s network capture scope defaults to `.allSessions`, which
  turns the swizzle on, so a plain `LogConsole.install()` crashed too.

  Verified on the iOS 26.2 and iOS 18.6 simulators, in both directions — the new
  tests fail against the old implementation and pass against this one.

### Documentation

- The README and `installGlobally` now say that `swizzlingSessionConfigurations`
  replaces the getter for the life of the process and that `uninstallGlobally()`
  cannot undo it, and point at `LogConsole`'s `scope:` parameter —
  `.sharedSessionOnly` covers `URLSession.shared` without the swizzle, `.manual`
  leaves the `install(in:)` calls to you.

## 1.0.0 - 2026-08-11

Initial release.
