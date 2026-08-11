import Foundation
import KVLoggingKit
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LogListModel: ObservableObject {
    @Published private(set) var events: [LogEvent] = []
    @Published var searchText = ""
    @Published var minimumLevel: LogLevel = .trace
    @Published var selectedCategory: String?

    private let store: ConsoleLogStore
    private var observation: Task<Void, Never>?

    init(store: ConsoleLogStore) {
        self.store = store
    }

    deinit {
        observation?.cancel()
    }

    var categories: [String] {
        Array(Set(events.compactMap(\.category))).sorted()
    }

    var visibleEvents: [LogEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return events.filter { event in
            guard event.level >= minimumLevel else { return false }
            if let selectedCategory, event.category != selectedCategory { return false }
            guard !query.isEmpty else { return true }

            return event.message.lowercased().contains(query)
                || event.category?.lowercased().contains(query) == true
                || event.metadata.contains { key, field in
                    key.lowercased().contains(query)
                        || field.value.stringValue.lowercased().contains(query)
                }
        }
    }

    /// Pulls a snapshot on each change signal. The signal stream buffers only
    /// the newest value, so a burst of a thousand events costs one refresh
    /// rather than a thousand array copies.
    func startObserving() {
        guard observation == nil else { return }

        observation = Task { [store] in
            for await _ in store.changes() {
                if Task.isCancelled { return }
                let snapshot = await store.all()
                if Task.isCancelled { return }
                self.events = snapshot

                // Coalesces bursts and keeps the console from monopolising the
                // main actor while the app is busy.
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
        visibleEvents.reversed().map(LogConsoleFormatting.line(for:)).joined(separator: "\n")
    }
}
