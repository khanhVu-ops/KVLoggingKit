#if canImport(UIKit)
import Foundation
import UIKit
import KVLoggingKit

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
                ) { [logger] _ in
                    Task {
                        await logger.flush()
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
}
#endif
