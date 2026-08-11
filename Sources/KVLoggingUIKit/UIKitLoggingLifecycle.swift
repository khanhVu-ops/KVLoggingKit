#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import KVLoggingKit

/// Flushes pending logs when the app leaves the foreground.
///
/// Both notifications request a background task first. `willTerminate` gives
/// the app only a few seconds of main-thread time, and the previous version
/// started an unstructured `Task` and returned immediately — the flush almost
/// never completed before the process died.
@MainActor
public final class UIKitLoggingLifecycle {
    private struct ObserverToken: @unchecked Sendable {
        let value: NSObjectProtocol
    }

    private let notificationCenter: NotificationCenter
    private var observers: [ObserverToken] = []

    public init(
        logger: LogClient,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter

        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]

        observers = names.map { name in
            ObserverToken(
                value: notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        Self.flush(logger)
                    }
                }
            )
        }
    }

    public convenience init(
        application: UIApplication,
        logger: LogClient,
        notificationCenter: NotificationCenter = .default
    ) {
        _ = application
        self.init(logger: logger, notificationCenter: notificationCenter)
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer.value)
        }
    }

    /// Holds the process alive for the duration of the flush, and always ends
    /// the background task so the system never kills the app for overrunning.
    @MainActor
    private static func flush(_ logger: LogClient) {
        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid

        identifier = application.beginBackgroundTask(withName: "KVLogging.flush") {
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }

        Task {
            await logger.flush()
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }
}
#endif
