# Changelog

All notable changes to KVLoggingKit are documented in this file.

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
