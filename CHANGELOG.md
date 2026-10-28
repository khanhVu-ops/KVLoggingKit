# Changelog

All notable changes to KVLoggingKit are documented in this file.

## 1.2.1 - 2026-10-28

### Fixed

- `NetworkLoggingURLProtocol` crashed the app with `EXC_BAD_ACCESS` in
  `objc_retain` on `com.apple.network.connections`, from
  `-[__NSCFLocalSessionTask dealloc]`. Each intercepted request replayed through
  its own `URLSession`, invalidated on completion; Network.framework retires the
  connection later, and the task's dealloc then read the freed session. It took
  a few requests to show, typically after an upload. Every request now replays
  through one shared session that is never released.

## 1.2.0 - 2026-10-14

### Added

- Server-sent events support. A `text/event-stream` response is parsed into
  `NetworkLogRecord.stream` (`NetworkStreamLog` / `NetworkStreamEvent`): one
  entry per event with its arrival time, type (SSE `event:` or a JSON `"type"`),
  redacted payload, and any text delta it carries. Under
  `NetworkLoggingURLProtocol` this happens live: the record gets its status and
  headers when the response head arrives and new events every 250 ms while the
  stream is open, instead of a pending row until the connection closes. Long
  strings (base64 audio, images) are elided past `maximumStreamStringLength`,
  and a recorder keeps the latest `maximumStreamEvents` (2,000) per response.
- The console marks streams with an `SSE` / `LIVE` tag and an event count, keeps
  an open detail screen updating while it streams, and adds an Events tab: the
  assembled answer, a filter per event type, and every event with its offset,
  size and an expandable pretty-printed payload.

### Fixed

- Capture callbacks from `NetworkLoggingURLProtocol` are delivered to the
  recorder in order. Each one used to start its own `Task`, so a completion
  could overtake the `begin` for the same request.

### Changed

- Reworked the console's Network tab for readability. Rows now line up a
  colored method badge, the path, host and time, with the status code, duration
  and response size on the trailing edge. Filters are chips with counts
  (All / Success / Errors / Pending) plus a host filter when traffic spans
  several hosts. The detail screen keeps a header card (method, status with
  reason phrase, URL, duration, size, start time) above the tabs, splits out
  query parameters, hides empty timing rows, shows headers as a divided list
  with redacted values highlighted, and labels bodies with content type and
  size plus a copy button.

## 1.1.1 - 2026-09-30

### Fixed

- `NetworkLoggingURLProtocol` sent every captured request that had a body with
  **no body at all**. A JSON `POST` logged correctly in the console, but the
  server received an empty body (seen as a `400` validation error from a real
  backend). URLSession hands a protocol the body as `httpBodyStream`, and the
  protocol read it back into `httpBody`. It then assigned `httpBodyStream = nil`
  second, and on `NSMutableURLRequest` assigning the stream, even `nil`, clears
  the body. The stream is now cleared first and the body set after.
- Uploads over the capture limit (1 MB by default) were sent **truncated**. The
  outgoing body was read only up to `maximumCapturedResponseBytes`. The whole
  body is now read and sent, and the limit bounds only the copy kept for the
  console.
- The body stream is read to end of stream instead of while `hasBytesAvailable`,
  and a stream that fails part-way fails the request rather than sending a
  shortened body.

Tests now assert on the bytes the transport receives, not only on the record.
The record looked right the whole time the server was getting nothing.

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
