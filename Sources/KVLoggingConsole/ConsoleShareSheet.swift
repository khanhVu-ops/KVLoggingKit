import SwiftUI

#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

/// Writes the export to a temporary `.log` file and hands it to the share
/// sheet, so a long session attaches to a bug report as a file rather than as
/// an unwieldy block of pasted text.
@available(iOS 16.0, *)
struct ConsoleShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item()], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    private func item() -> Any {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-\(Int(Date().timeIntervalSince1970)).log")

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return text
        }
    }
}
#else
@available(macOS 13.0, *)
struct ConsoleShareSheet: View {
    let text: String

    var body: some View {
        ShareLink(item: text) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .padding()
    }
}
#endif
