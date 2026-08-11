import Foundation
import KVLoggingNetwork
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class NetworkListModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case success = "2xx–3xx"
        case failure = "Errors"

        var id: String { rawValue }
    }

    @Published private(set) var records: [NetworkLogRecord] = []
    @Published var searchText = ""
    @Published var filter: Filter = .all

    private let store: NetworkLogStore
    private var observation: Task<Void, Never>?

    init(store: NetworkLogStore) {
        self.store = store
    }

    deinit {
        observation?.cancel()
    }

    var visibleRecords: [NetworkLogRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return records.filter { record in
            switch filter {
            case .all:
                break
            case .success:
                guard record.isSuccess else { return false }
            case .failure:
                let failed = record.error != nil || (record.statusCode.map { $0 >= 400 } ?? false)
                guard failed else { return false }
            }

            guard !query.isEmpty else { return true }
            return record.request.url.lowercased().contains(query)
                || record.request.method.lowercased().contains(query)
                || (record.statusCode.map { String($0).contains(query) } ?? false)
        }
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
