#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import SwiftUI
import UIKit

/// Shows the console in its own window above everything else.
///
/// A dedicated `UIWindow` rather than a modal presentation, because the console
/// has to be reachable while the app is already showing a sheet, an alert, or a
/// full-screen ad — presenting from the top view controller fails in exactly
/// the situations worth debugging.
@available(iOS 16.0, *)
@MainActor
enum ConsolePresenter {
    private static var window: UIWindow?

    static var isPresented: Bool { window != nil }

    static func present() {
        guard window == nil else { return }
        guard let scene = activeScene() else { return }

        let controller = UIHostingController(
            rootView: ConsoleView(onClose: { dismiss() })
        )

        let window = UIWindow(windowScene: scene)
        // Above alerts so it is never buried by whatever is already on screen.
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        window.makeKeyAndVisible()

        self.window = window
    }

    static func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
#endif
