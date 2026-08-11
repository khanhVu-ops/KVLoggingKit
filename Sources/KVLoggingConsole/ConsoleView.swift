import KVLoggingKit
import KVLoggingNetwork
import SwiftUI

/// The console shell: logs and network traffic in one place.
@available(iOS 16.0, macOS 13.0, *)
public struct ConsoleView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case network = "Network"

        var id: String { rawValue }
    }

    @StateObject private var logModel: LogListModel
    @StateObject private var networkModel: NetworkListModel
    @State private var tab: Tab = .logs
    @State private var isSharing = false

    private let onClose: (() -> Void)?

    public init(
        logStore: ConsoleLogStore? = nil,
        networkStore: NetworkLogStore? = nil,
        onClose: (() -> Void)? = nil
    ) {
        let logs = logStore ?? LogConsole.logStore ?? .shared
        let network = networkStore ?? LogConsole.networkStore ?? .shared

        _logModel = StateObject(wrappedValue: LogListModel(store: logs))
        _networkModel = StateObject(wrappedValue: NetworkListModel(store: network))
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch tab {
                case .logs:
                    LogListView(model: logModel)
                case .network:
                    NetworkListView(model: networkModel)
                }
            }
            .navigationTitle("Console")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            ConsoleClipboard.copy(exportText)
                        } label: {
                            Label("Copy visible", systemImage: "doc.on.doc")
                        }
                        Button {
                            isSharing = true
                        } label: {
                            Label("Share visible", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            clearCurrentTab()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                ConsoleShareSheet(text: exportText)
            }
        }
    }

    private var exportText: String {
        switch tab {
        case .logs: logModel.exportText()
        case .network: networkModel.exportText()
        }
    }

    private func clearCurrentTab() {
        switch tab {
        case .logs: logModel.clear()
        case .network: networkModel.clear()
        }
    }
}
