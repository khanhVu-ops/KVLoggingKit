import Foundation
import KVLoggingKit
import KVLoggingNetwork

/// Where `URLProtocol` capture applies.
public enum NetworkCaptureScope: Sendable {
    /// `URLSession.shared` plus sessions built from their own configuration.
    ///
    /// Reaching the latter needs `URLSessionConfiguration.protocolClasses` to be
    /// swizzled, which only happens after ``DebugAccessPolicy`` has allowed the
    /// console — never in a build that cannot show it.
    case allSessions
    /// `URLSession.shared` only. No swizzling.
    case sharedSessionOnly
    /// Nothing is registered. Call `NetworkLoggingURLProtocol.install(in:)` on
    /// the configurations you want, or use `URLSession.networkLogging(...)`.
    case manual
}

/// Setup for the in-app debug console.
///
/// ```swift
/// var destinations: [any LogDestination] = [SystemLogDestination()]
/// if let store = LogConsole.install(policy: .debugOrBundleIdentifiers(["varmeta.test.app"])) {
///     destinations.append(store)
/// }
///
/// let logger = LogClient(destinations: destinations)
/// LogConsole.startNetworkCapture(logger: logger)
/// ```
///
/// When the policy rejects the build, `install` returns `nil` and registers
/// nothing — no shake handler, no swizzling, no window, no store retaining
/// events — and every other call here becomes a no-op.
public enum LogConsole {
    /// Locked rather than main-actor isolated, so a plain `static let` logger
    /// bootstrap can call `install` without hopping actors.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var isInstalled = false
        private var logStore: ConsoleLogStore?
        private var networkStore: NetworkLogStore?

        func install(
            logLimit: Int,
            networkLimit: Int
        ) -> (store: ConsoleLogStore, isFirstInstall: Bool) {
            lock.lock()
            defer { lock.unlock() }

            if let logStore {
                return (logStore, false)
            }

            let store = ConsoleLogStore(limit: logLimit)
            logStore = store
            networkStore = NetworkLogStore(limit: networkLimit)
            isInstalled = true
            return (store, true)
        }

        var installed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isInstalled
        }

        var logs: ConsoleLogStore? {
            lock.lock()
            defer { lock.unlock() }
            return logStore
        }

        var network: NetworkLogStore? {
            lock.lock()
            defer { lock.unlock() }
            return networkStore
        }
    }

    private static let state = State()

    public struct Configuration: Sendable {
        public var policy: DebugAccessPolicy
        /// Events kept for the Logs tab.
        public var logLimit: Int
        /// Exchanges kept for the Network tab.
        public var networkLimit: Int
        /// Opens the console when the device is shaken.
        public var opensOnShake: Bool

        public init(
            policy: DebugAccessPolicy = .debugOnly,
            logLimit: Int = 2_000,
            networkLimit: Int = 250,
            opensOnShake: Bool = true
        ) {
            self.policy = policy
            self.logLimit = logLimit
            self.networkLimit = networkLimit
            self.opensOnShake = opensOnShake
        }
    }

    public static var isInstalled: Bool { state.installed }
    public static var logStore: ConsoleLogStore? { state.logs }
    public static var networkStore: NetworkLogStore? { state.network }

    /// Registers the console and returns the `LogDestination` to add to the
    /// `LogClient`, or `nil` when the policy denies access.
    ///
    /// Keeping the destination out of the pipeline — rather than adding an
    /// inert one — is what makes this free in production.
    @discardableResult
    public static func install(configuration: Configuration = .init()) -> ConsoleLogStore? {
        guard configuration.policy.isAllowed() else { return nil }

        let (store, isFirstInstall) = state.install(
            logLimit: configuration.logLimit,
            networkLimit: configuration.networkLimit
        )

        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        if isFirstInstall, configuration.opensOnShake {
            Task { @MainActor in
                guard #available(iOS 16.0, *) else { return }
                ShakeDetector.start { present() }
            }
        }
        #endif

        return store
    }

    @discardableResult
    public static func install(
        policy: DebugAccessPolicy,
        opensOnShake: Bool = true
    ) -> ConsoleLogStore? {
        install(configuration: .init(policy: policy, opensOnShake: opensOnShake))
    }

    /// Routes captured requests into the Network tab and emits one redacted
    /// summary event per exchange into `logger`.
    ///
    /// Call it after the `LogClient` exists. No-op when the console was not
    /// installed, so it is safe to call unconditionally.
    @discardableResult
    public static func startNetworkCapture(
        logger: LogClient? = nil,
        redactor: NetworkLogRedactor = .default,
        scope: NetworkCaptureScope = .allSessions,
        excluding shouldCapture: @escaping @Sendable (URLRequest) -> Bool = { _ in true }
    ) -> NetworkLogRecorder? {
        guard let networkStore else { return nil }

        let recorder = NetworkLogRecorder(
            store: networkStore,
            redactor: redactor,
            logger: logger
        )

        NetworkLoggingURLProtocol.settings = .init(
            recorder: recorder,
            shouldCapture: shouldCapture
        )

        switch scope {
        case .allSessions:
            NetworkLoggingURLProtocol.installGlobally(swizzlingSessionConfigurations: true)
        case .sharedSessionOnly:
            NetworkLoggingURLProtocol.installGlobally()
        case .manual:
            break
        }

        return recorder
    }

    /// Shows the console in its own window, above anything already on screen.
    /// No-op when the policy denied installation.
    public static func present() {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        guard isInstalled else { return }
        Task { @MainActor in
            guard #available(iOS 16.0, *) else { return }
            ConsolePresenter.present()
        }
        #endif
    }

    public static func dismiss() {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        Task { @MainActor in
            guard #available(iOS 16.0, *) else { return }
            ConsolePresenter.dismiss()
        }
        #endif
    }

    public static func toggle() {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        Task { @MainActor in
            guard #available(iOS 16.0, *) else { return }
            ConsolePresenter.isPresented ? ConsolePresenter.dismiss() : ConsolePresenter.present()
        }
        #endif
    }
}
