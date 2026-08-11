#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit
import XCTest
@testable import KVLoggingConsole

private final class Counter {
    var value = 0
}

@available(iOS 16.0, *)
@MainActor
final class ShakeDetectorTests: XCTestCase {
    override func tearDown() {
        ShakeDetector.stop()
        super.tearDown()
    }

    /// Drives the real responder method, which is what UIKit calls, so this
    /// exercises the installed swizzle rather than the handler in isolation.
    func testShakeOnAWindowInvokesTheHandler() {
        let counter = Counter()
        ShakeDetector.start { counter.value += 1 }

        UIWindow(frame: .zero).motionEnded(.motionShake, with: nil)

        XCTAssertEqual(counter.value, 1)
    }

    func testOtherMotionsAreIgnored() {
        let counter = Counter()
        ShakeDetector.start { counter.value += 1 }

        UIWindow(frame: .zero).motionEnded(.none, with: nil)

        XCTAssertEqual(counter.value, 0)
    }

    /// Motion travels the whole responder chain. Firing only for windows is
    /// what keeps one shake from opening the console several times.
    func testNonWindowRespondersDoNotFire() {
        let counter = Counter()
        ShakeDetector.start { counter.value += 1 }

        UIView().motionEnded(.motionShake, with: nil)
        UIViewController().motionEnded(.motionShake, with: nil)

        XCTAssertEqual(counter.value, 0)
    }

    func testStopDetaches() {
        let counter = Counter()
        ShakeDetector.start { counter.value += 1 }
        ShakeDetector.stop()

        UIWindow(frame: .zero).motionEnded(.motionShake, with: nil)

        XCTAssertEqual(counter.value, 0)
    }
}
#endif
