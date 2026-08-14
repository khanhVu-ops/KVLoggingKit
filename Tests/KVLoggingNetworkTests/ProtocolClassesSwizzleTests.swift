import Foundation
import ObjectiveC
import XCTest
@testable import KVLoggingNetwork

/// Regression tests for `installGlobally(swizzlingSessionConfigurations:)`, which
/// crashed every app that enabled it on iOS 26.
///
/// They drive `protocolClassesReplacement` directly with a stubbed chain rather
/// than installing the real swizzle: installing is process-global, irreversible,
/// and would leak into every other test in this bundle.
///
/// The two failures being pinned down, both caused by the replacement having been
/// a Swift `@objc` method returning a bridged `[AnyClass]?`:
///
/// - The protocol class did not survive the return. It read back as
///   `NSURLSessionConfiguration`, which is not a `URLProtocol` subclass and
///   answers neither `+canInitWithTask:` nor `+canInitWithRequest:`. CFNetwork
///   asks every entry whether it can handle the task, so the first request
///   through any session built from a custom configuration died in
///   `-[__NSURLSessionLocal _protocolClassForTask:skipAppSSO:]` with
///   `+[NSURLSessionConfiguration canInitWithTask:]: unrecognized selector`.
/// - One more bogus entry was prepended on every read, so the list grew without
///   bound.
private final class FirstStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { false }
}

private final class SecondStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { false }
}

/// What the stubbed chain hands back. A global because `@convention(c)` cannot
/// capture context — the same constraint the real replacement works under.
nonisolated(unsafe) private var chainedClasses: [AnyClass] = []

private let chainStub: NetworkLoggingURLProtocol.ProtocolClassesIMP = { _, _ in
    Unmanaged.passRetained(NSArray(array: chainedClasses)).autorelease()
}

final class ProtocolClassesSwizzleTests: XCTestCase {
    private let getter = #selector(getter: URLSessionConfiguration.protocolClasses)

    /// Whether CFNetwork can safely ask this entry to handle a task. It sends
    /// `+canInitWithTask:` — the crash named that one — and `+canInitWithRequest:`
    /// is the older path, so an entry has to answer both.
    static func answersProtocolQueries(_ candidate: AnyClass) -> Bool {
        [Selector(("canInitWithTask:")), Selector(("canInitWithRequest:"))]
            .allSatisfy { (candidate as AnyObject).responds(to: $0) }
    }

    override func setUp() {
        super.setUp()
        chainedClasses = [FirstStubProtocol.self, SecondStubProtocol.self]
        NetworkLoggingURLProtocol.originalProtocolClassesIMP = chainStub
    }

    override func tearDown() {
        NetworkLoggingURLProtocol.originalProtocolClassesIMP = nil
        chainedClasses = []
        super.tearDown()
    }

    /// Any configuration will do — the replacement only passes it down the chain.
    private func readProtocolClasses() -> [AnyClass] {
        let received = URLSessionConfiguration.ephemeral
        let returned = NetworkLoggingURLProtocol.protocolClassesReplacement(
            received,
            getter
        )
        guard let array = returned?.takeUnretainedValue() else { return [] }
        return array as? [AnyClass] ?? []
    }

    func testTheProtocolClassSurvivesTheReturn() {
        let classes = readProtocolClasses()

        XCTAssertTrue(
            classes.first === NetworkLoggingURLProtocol.self,
            "expected the protocol first, got \(classes.map { NSStringFromClass($0) })"
        )
    }

    /// The crash itself: CFNetwork asks every entry whether it can handle the
    /// task, so an entry that does not answer terminates the process.
    func testEveryEntryAnswersCanInitWithRequest() {
        let deaf = readProtocolClasses().filter {
            !Self.answersProtocolQueries($0)
        }

        XCTAssertEqual(
            deaf.map { NSStringFromClass($0) },
            [],
            "these entries would crash CFNetwork"
        )
    }

    func testTheChainedClassesAreKept() {
        let classes = readProtocolClasses()

        XCTAssertEqual(classes.count, 3)
        XCTAssertTrue(classes.contains { $0 === FirstStubProtocol.self })
        XCTAssertTrue(classes.contains { $0 === SecondStubProtocol.self })
    }

    /// Reading the property repeatedly must not grow the list. Feeding the output
    /// back in as the chain's answer is what a real configuration does — the value
    /// gets stored and re-read.
    func testRepeatedReadsDoNotGrowTheList() {
        for round in 1...5 {
            let classes = readProtocolClasses()
            let appearances = classes.filter { $0 === NetworkLoggingURLProtocol.self }
            XCTAssertEqual(
                appearances.count,
                1,
                "round \(round) has \(appearances.count) copies of the protocol"
            )
            XCTAssertEqual(classes.count, 3, "round \(round) list length drifted")

            // Next round sees this round's answer, the way a stored value would.
            chainedClasses = classes
        }
    }

    /// Nothing to add when the protocol is already present, and the chain's own
    /// array comes straight back.
    func testAnAlreadyPresentProtocolIsNotDuplicated() {
        chainedClasses = [NetworkLoggingURLProtocol.self, FirstStubProtocol.self]

        let classes = readProtocolClasses()

        XCTAssertEqual(classes.count, 2)
        XCTAssertTrue(classes.first === NetworkLoggingURLProtocol.self)
    }

    /// An unswizzled chain means nothing to inherit; answering with the protocol
    /// alone still has to be a valid list.
    func testAnEmptyChainStillYieldsTheProtocol() {
        chainedClasses = []

        let classes = readProtocolClasses()

        XCTAssertEqual(classes.count, 1)
        XCTAssertTrue(classes.first === NetworkLoggingURLProtocol.self)
    }

    /// The returned array must reach the caller at +0 autoreleased, as an ObjC
    /// getter's would. Retaining it here and draining the pool would over-release
    /// a mismatched one.
    func testTheReturnedArrayIsAutoreleasedNotOwned() {
        var array: NSArray?
        autoreleasepool {
            array = NetworkLoggingURLProtocol
                .protocolClassesReplacement(URLSessionConfiguration.ephemeral, getter)?
                .takeUnretainedValue()
            XCTAssertNotNil(array)
            // Held past the pool drain below by this strong reference.
            _ = array?.count
        }
        XCTAssertEqual(array?.count, 3)
    }
}
