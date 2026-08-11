#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

/// Turns a device shake anywhere in the app into a callback.
///
/// UIKit delivers motion events along the responder chain and offers no
/// app-wide notification for them. Rather than make the host app subclass
/// `UIWindow`, this exchanges `UIResponder.motionEnded(_:with:)` once.
///
/// The exchange has to happen on `UIResponder`, which is where the method is
/// actually implemented — swizzling `UIWindow` would silently rebind the
/// inherited implementation for every responder in the app. Since the callback
/// then runs for each link in the chain, it only fires for `UIWindow`, giving
/// exactly one shake per window.
///
/// It is installed only after ``DebugAccessPolicy`` has allowed the console, so
/// nothing is swizzled in a build that cannot show it.
@available(iOS 16.0, *)
@MainActor
enum ShakeDetector {
    private static var handler: (@MainActor () -> Void)?
    private static var isStarted = false

    static func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        guard !isStarted else { return }
        isStarted = true
        installSwizzle()
    }

    static func stop() {
        handler = nil
    }

    fileprivate static func handleShake() {
        handler?()
    }

    private static func installSwizzle() {
        let selector = #selector(UIResponder.motionEnded(_:with:))
        guard
            let original = class_getInstanceMethod(UIResponder.self, selector),
            let replacement = class_getInstanceMethod(
                UIResponder.self,
                #selector(UIResponder.kvLoggingConsole_motionEnded(_:with:))
            )
        else { return }

        MotionEndedForwarding.original = unsafeBitCast(
            method_getImplementation(original),
            to: MotionEndedForwarding.IMP.self
        )
        method_exchangeImplementations(original, replacement)
    }
}

/// Holds the pre-swizzle implementation so the replacement can chain to it
/// without a recursive-looking self-call.
private enum MotionEndedForwarding {
    typealias IMP = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void

    nonisolated(unsafe) static var original: IMP?
}

private extension UIResponder {
    @objc func kvLoggingConsole_motionEnded(
        _ motion: UIEvent.EventSubtype,
        with event: UIEvent?
    ) {
        if motion == .motionShake, self is UIWindow, #available(iOS 16.0, *) {
            MainActor.assumeIsolated {
                ShakeDetector.handleShake()
            }
        }

        MotionEndedForwarding.original?(
            self,
            #selector(UIResponder.motionEnded(_:with:)),
            motion,
            event
        )
    }
}
#endif
