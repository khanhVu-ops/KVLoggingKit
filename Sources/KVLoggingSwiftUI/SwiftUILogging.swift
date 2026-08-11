import SwiftUI
import KVLoggingKit

@available(iOS 16.0, macOS 13.0, *)
public extension EnvironmentValues {
    @Entry var logClient: LogClient = .disabled
}

@available(iOS 16.0, macOS 13.0, *)
public extension View {
    func kvLogging(_ client: LogClient) -> some View {
        modifier(KVLoggingModifier(client: client))
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct KVLoggingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let client: LogClient

    func body(content: Content) -> some View {
        content
            .environment(\.logClient, client)
            .onChange(of: scenePhase) { phase in
                guard phase == .background else { return }
                Task {
                    await client.flush()
                }
            }
    }
}
