/// Fixed-capacity buffer that overwrites its oldest element once full.
///
/// Appending is O(1) with no allocation after construction. A plain array with
/// `insert(at: 0)` plus a trailing `removeLast` would move every element on
/// every log line, which is exactly the cost an in-app console must not add.
public struct LogRingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element?]
    private var writeIndex = 0

    public let capacity: Int
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Newest first, which is the order every view here displays.
    public func newestFirst() -> [Element] {
        guard count > 0 else { return [] }

        var result = [Element]()
        result.reserveCapacity(count)

        for offset in 1...count {
            let index = (writeIndex - offset + capacity) % capacity
            if let element = storage[index] {
                result.append(element)
            }
        }
        return result
    }

    /// Overwrites the newest matching element in place. Returns `false` when no
    /// element matches, which happens once the ring has evicted it.
    ///
    /// Scans newest-first because callers update recent entries — a request
    /// that just completed is near the head, not buried at the tail.
    public mutating func replace(
        where matches: (Element) -> Bool,
        with element: Element
    ) -> Bool {
        guard count > 0 else { return false }

        for offset in 1...count {
            let index = (writeIndex - offset + capacity) % capacity
            if let existing = storage[index], matches(existing) {
                storage[index] = element
                return true
            }
        }
        return false
    }

    public mutating func removeAll() {
        for index in storage.indices {
            storage[index] = nil
        }
        writeIndex = 0
        count = 0
    }
}
