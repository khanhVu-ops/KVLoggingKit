import Foundation
import KVLoggingNetwork
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class NetworkListModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case success = "Success"
        case failure = "Errors"
        case pending = "Pending"

        var id: String { rawValue }
    }

    @Published private(set) var records: [NetworkLogRecord] = []
    @Published var searchText = ""
    @Published var filter: Filter = .all
    @Published var selectedHost: String?

    private let store: NetworkLogStore
    private var observation: Task<Void, Never>?

    init(store: NetworkLogStore) {
        self.store = store
    }

    deinit {
        observation?.cancel()
    }

    var hosts: [String] {
        Array(Set(records.compactMap(\.request.host))).sorted()
    }

    func count(for filter: Filter) -> Int {
        records.filter { matches($0, filter: filter) && matchesHost($0) }.count
    }

    var visibleRecords: [NetworkLogRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return records.filter { record in
            guard matches(record, filter: filter), matchesHost(record) else { return false }

            guard !query.isEmpty else { return true }
            return record.request.url.lowercased().contains(query)
                || record.request.method.lowercased().contains(query)
                || (record.statusCode.map { String($0).contains(query) } ?? false)
        }
    }

    private func matches(_ record: NetworkLogRecord, filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .success: record.state != .pending && record.isSuccess
        case .failure: NetworkLogFormatting.isFailure(record)
        case .pending: record.state == .pending
        }
    }

    private func matchesHost(_ record: NetworkLogRecord) -> Bool {
        guard let selectedHost else { return true }
        return record.request.host == selectedHost
    }

    /// Same pull-on-signal shape as the log list: the store never copies its
    /// contents per event, and bursts collapse into one refresh.
    func startObserving() {
        guard observation == nil else { return }

        observation = Task { [store] in
            for await _ in store.changes() {
                if Task.isCancelled { return }
                let snapshot = await store.all()
                if Task.isCancelled { return }
                self.records = snapshot

                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    func clear() {
        Task { [store] in await store.clear() }
    }

    func exportText() -> String {
        visibleRecords.reversed().map(\.curlCommand).joined(separator: "\n\n")
    }
}
