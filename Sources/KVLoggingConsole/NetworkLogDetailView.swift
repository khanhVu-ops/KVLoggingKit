import KVLoggingNetwork
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
public struct NetworkLogDetailView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case request = "Request"
        case response = "Response"
        case curl = "cURL"

        var id: String { rawValue }
    }

    private let record: NetworkLogRecord
    @State private var tab: Tab = .summary

    public init(record: NetworkLogRecord) {
        self.record = record
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .summary: summary
                    case .request: requestSection
                    case .response: responseSection
                    case .curl: curlSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .navigationTitle(record.request.method)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("URL", record.request.url, monospaced: true)

            rows([
                ("Status", NetworkLogFormatting.statusText(for: record)),
                ("Duration", NetworkLogFormatting.duration(record.duration)),
                ("Started", NetworkLogFormatting.time(record.startedAt))
            ])

            if let error = record.error {
                group("Error") {
                    field(error.type, error.message, monospaced: true)
                }
            }

            if let metrics = record.metrics {
                group("Timing") {
                    rows([
                        ("DNS", NetworkLogFormatting.duration(metrics.domainLookup)),
                        ("Connect", NetworkLogFormatting.duration(metrics.connect)),
                        ("TLS", NetworkLogFormatting.duration(metrics.secureConnect)),
                        ("Time to first byte", NetworkLogFormatting.duration(metrics.timeToFirstByte))
                    ])
                }
                group("Connection") {
                    rows([
                        ("Protocol", metrics.networkProtocolName ?? "—"),
                        ("Sent", NetworkLogFormatting.byteCount(Int(metrics.requestBytesSent))),
                        ("Received", NetworkLogFormatting.byteCount(Int(metrics.responseBytesReceived))),
                        ("Reused connection", metrics.isReusedConnection ? "Yes" : "No"),
                        ("Cellular", metrics.isCellular ? "Yes" : "No"),
                        ("Proxy", metrics.isProxyConnection ? "Yes" : "No")
                    ])
                }
            }
        }
    }

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Headers") { headerList(record.request.headers) }
            group("Body") { code(NetworkLogFormatting.bodyText(record.request.body)) }
        }
    }

    @ViewBuilder
    private var responseSection: some View {
        if let response = record.response {
            VStack(alignment: .leading, spacing: 16) {
                group("Headers") { headerList(response.headers) }
                group("Body") { code(NetworkLogFormatting.bodyText(response.body)) }
            }
        } else {
            Text("No response was received.")
                .foregroundStyle(.secondary)
        }
    }

    private var curlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                copy(record.curlCommand)
            } label: {
                Label("Copy command", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            code(record.curlCommand)

            Text("Redacted values keep their `<redacted>` placeholder — substitute the real credential before running the command.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func rows(_ entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries, id: \.0) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.0)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(entry.1)
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func headerList(_ headers: [String: String]) -> some View {
        if headers.isEmpty {
            Text("(none)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(headers.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key)
                            .font(.caption.weight(.semibold))
                        Text(headers[key] ?? "")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func field(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
