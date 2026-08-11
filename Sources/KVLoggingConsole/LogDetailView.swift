import KVLoggingKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
struct LogDetailView: View {
    let event: LogEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(LogConsoleFormatting.label(for: event.level))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            LogConsoleFormatting.color(for: event.level),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    if let category = event.category {
                        Text(category).font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }

                ConsoleSection(title: "Message") {
                    Text(event.message)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                if !event.metadata.isEmpty {
                    ConsoleSection(title: "Metadata") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(event.metadata.keys.sorted(), id: \.self) { key in
                                metadataRow(key: key, field: event.metadata[key])
                            }
                        }
                    }
                }

                if let error = event.error {
                    ConsoleSection(title: "Error") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error.type).font(.caption.weight(.semibold))
                            if let domain = error.domain, let code = error.code {
                                Text("\(domain) · \(code)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(error.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                ConsoleSection(title: "Source") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.source.file):\(event.source.line)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(event.source.function)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(LogConsoleFormatting.time(event.timestamp))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    ConsoleClipboard.copy(LogConsoleFormatting.line(for: event))
                } label: {
                    Label("Copy line", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Event")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func metadataRow(key: String, field: LogField?) -> some View {
        if let field {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key).font(.caption.weight(.semibold))
                    if field.privacy == .private {
                        // Worth surfacing: this value is withheld from remote
                        // destinations and from the unified log.
                        Text("private")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(field.value.stringValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct ConsoleSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ConsoleClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit) && !os(watchOS)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
