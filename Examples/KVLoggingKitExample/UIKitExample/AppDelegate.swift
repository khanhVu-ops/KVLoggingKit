import ExampleSupport
import KVLoggingUIKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let loggingService = ExampleLoggingService.live()
    private var loggingLifecycle: UIKitLoggingLifecycle?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        loggingLifecycle = UIKitLoggingLifecycle(
            application: application,
            logger: loggingService.logger
        )
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
