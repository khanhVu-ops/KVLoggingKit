import ExampleSupport
import KVLoggingSwiftUI
import SwiftUI

@MainActor
struct LoggingExampleView: View {
    @Environment(\.logClient) private var logger
    @State private var snapshot = ExampleSnapshot.empty
    @State private var latestAction = "Ready"

    let service: ExampleLoggingService

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                actionsSection

                Section("Latest action") {
                    Text(latestAction)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("KVLoggingKit")
            .task {
                await refresh()
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Connectivity", value: snapshot.isOnline ? "Online" : "Offline")
            LabeledContent("Delivered batches", value: snapshot.deliveredBatchCount.formatted())
            LabeledContent("Delivered events", value: snapshot.deliveredEventCount.formatted())
            LabeledContent("Queued batches", value: snapshot.queuedBatchCount.formatted())
            LabeledContent("Local files", value: snapshot.localFileCount.formatted())

            if let bootstrapError = snapshot.bootstrapError {
                Text(bootstrapError)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Logging bootstrap error: \(bootstrapError)")
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Generate sample logs", systemImage: "waveform.path.ecg") {
                service.generateSampleLogs()
                latestAction = "Generated four sample events."

                Task {
                    await refresh(using: await service.flushAndSnapshot())
                }
            }

            Button(snapshot.isOnline ? "Go offline" : "Go online", systemImage: connectivitySymbol) {
                Task {
                    let nextState = !snapshot.isOnline
                    await service.setOnline(nextState)
                    latestAction = nextState ? "Mock transport is online." : "Mock transport is offline."
                    await refresh()
                }
            }

            Button("Flush and replay queue", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    let flushedSnapshot = await service.flushAndSnapshot()
                    latestAction = "Flushed destinations and replayed any queued batches."
                    await refresh(using: flushedSnapshot)
                }
            }

            Button("Export encrypted local logs", systemImage: "square.and.arrow.up") {
                Task {
                    do {
                        let directory = try await service.exportLocalLogs()
                        latestAction = "Exported encrypted logs to:\n\(directory.path)"
                    } catch {
                        latestAction = "Export failed: \(error.localizedDescription)"
                    }
                    await refresh()
                }
            }

            Button("Log a SwiftUI interaction", systemImage: "swift") {
                logger.info("SwiftUI interaction selected", category: "ui")
                latestAction = "Logged directly through @Environment(\\.logClient)."
            }
        }
        .buttonStyle(.borderless)
    }

    private var connectivitySymbol: String {
        snapshot.isOnline ? "wifi.slash" : "wifi"
    }

    private func refresh(using suppliedSnapshot: ExampleSnapshot? = nil) async {
        if let suppliedSnapshot {
            snapshot = suppliedSnapshot
        } else {
            snapshot = await service.snapshot()
        }
    }
}
