import KVLoggingKit
import KVLoggingRemote

actor MockLogTransport: LogTransport {
    enum TransportError: Error {
        case offline
    }

    private var isOnline = true
    private var batches: [[LogEvent]] = []

    func send(_ events: [LogEvent]) async throws {
        guard isOnline else {
            throw TransportError.offline
        }
        batches.append(events)
    }

    func setOnline(_ value: Bool) {
        isOnline = value
    }

    func snapshot() -> [[LogEvent]] {
        batches
    }

    func onlineState() -> Bool {
        isOnline
    }
}
