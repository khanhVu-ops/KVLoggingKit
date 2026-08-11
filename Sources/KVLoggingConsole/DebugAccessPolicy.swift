import Foundation

/// Decides whether the debug console is reachable in this build, on this device.
///
/// The console is compiled into the binary either way — a TestFlight build with
/// an allowlisted bundle identifier has to be able to open it — so the gate is
/// evaluated at runtime and every activation path checks it.
public struct DebugAccessPolicy: Sendable {
    public enum Rule: Sendable {
        /// True when the package itself was compiled with `DEBUG`, which for a
        /// source-integrated SPM dependency follows the app's build
        /// configuration.
        case debugBuild
        /// True when the main bundle identifier is one of these.
        case bundleIdentifiers(Set<String>)
        /// True when the environment variable is present and not `"0"`.
        case environmentVariable(String)
        case custom(@Sendable () -> Bool)
        case always
    }

    private let rules: [Rule]

    /// The console opens when *any* rule passes.
    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// Debug builds only.
    public static let debugOnly = DebugAccessPolicy(rules: [.debugBuild])

    /// Debug builds, plus the named internal builds regardless of configuration.
    public static func debugOrBundleIdentifiers(
        _ identifiers: Set<String>
    ) -> DebugAccessPolicy {
        DebugAccessPolicy(rules: [.debugBuild, .bundleIdentifiers(identifiers)])
    }

    public static let disabled = DebugAccessPolicy(rules: [])

    public func isAllowed(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        rules.contains { rule in
            switch rule {
            case .debugBuild:
                #if DEBUG
                return true
                #else
                return false
                #endif
            case let .bundleIdentifiers(identifiers):
                guard let bundleIdentifier else { return false }
                return identifiers.contains(bundleIdentifier)
            case let .environmentVariable(name):
                guard let value = environment[name] else { return false }
                return value != "0"
            case let .custom(predicate):
                return predicate()
            case .always:
                return true
            }
        }
    }
}
