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
        case overview = "Info"
        case events = "Events"
        case request = "Request"
        case response = "Response"
        case curl = "cURL"

        var id: String { rawValue }
    }

    private let record: NetworkLogRecord
    @State private var tab: Tab = .overview

    public init(record: NetworkLogRecord) {
        self.record = record
        // A stream is opened for its events; anything else for its summary.
        _tab = State(initialValue: record.isEventStream ? .events : .overview)
    }

    private var tabs: [Tab] {
        record.isEventStream ? Tab.allCases : Tab.allCases.filter { $0 != .events }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Picker("Section", selection: $tab) {
                    ForEach(tabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .overview: overview
                case .events: eventsSection
                case .request: requestSection
                case .response: responseSection
                case .curl: curlSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(NetworkCardStyle.pageBackground)
        .navigationTitle(record.request.path ?? record.request.method)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    /// Stays above the tabs so the request is always identifiable.
    private var header: some View {
        NetworkCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    NetworkMethodBadge(method: record.request.method)
                    if record.isEventStream {
                        NetworkStreamTag(isLive: record.state == .pending)
                    }
                    Text(NetworkLogFormatting.statusDescription(for: record))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NetworkLogFormatting.statusColor(for: record))
                    Spacer()
                    copyButton(record.request.url)
                }

                Text(record.request.url)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .top, spacing: 0) {
                    if let stream = record.stream {
                        stat("Duration", record.state == .pending ? "Streaming…" : NetworkLogFormatting.duration(record.duration))
                        stat("Events", "\(stream.totalEventCount)")
                        stat("First event", stream.firstEventOffset.map(NetworkLogFormatting.duration) ?? "—")
                    } else {
                        stat("Duration", NetworkLogFormatting.duration(record.duration))
                        stat("Size", NetworkLogFormatting.responseSize(for: record) ?? "—")
                        stat("Started", NetworkLogFormatting.time(record.startedAt))
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tabs

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = record.error {
                NetworkCard(title: "Error", tint: .red) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error.type)
                            .font(.subheadline.weight(.semibold))
                        if let domain = error.domain, let code = error.code {
                            Text("\(domain) · \(code)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(error.message)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            let query = NetworkLogFormatting.queryItems(for: record)
            if !query.isEmpty {
                NetworkCard(title: "Query parameters", count: query.count) {
                    keyValueList(query.map { ($0.name, $0.value ?? "") })
                }
            }

            let timing = timingRows
            if !timing.isEmpty {
                NetworkCard(title: "Timing") {
                    keyValueList(timing, inline: true)
                }
            }

            NetworkCard(title: "Transfer") {
                keyValueList(transferRows, inline: true)
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if let stream = record.stream {
            NetworkStreamEventsView(stream: stream, isLive: record.state == .pending)
        }
    }

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            headersCard(record.request.headers)
            bodyCard(record.request.body)
        }
    }

    @ViewBuilder
    private var responseSection: some View {
        if let response = record.response {
            VStack(alignment: .leading, spacing: 16) {
                headersCard(response.headers)
                bodyCard(response.body)
            }
        } else {
            NetworkCard {
                Text(record.state == .pending ? "Waiting for a response…" : "No response was received.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var curlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NetworkCard(title: "Command", accessory: AnyView(copyButton(record.curlCommand))) {
                codeBlock(record.curlCommand)
            }

            Text("Redacted values keep their `<redacted>` placeholder — substitute the real credential before running the command.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private var timingRows: [(String, String)] {
        guard let metrics = record.metrics else { return [] }
        let entries: [(String, TimeInterval?)] = [
            ("DNS lookup", metrics.domainLookup),
            ("Connect", metrics.connect),
            ("TLS handshake", metrics.secureConnect),
            ("Time to first byte", metrics.timeToFirstByte)
        ]
        let measured = entries.compactMap { name, value in
            value.map { (name, NetworkLogFormatting.duration($0)) }
        }
        guard !measured.isEmpty else { return [] }
        return measured + [("Total", NetworkLogFormatting.duration(record.duration))]
    }

    private var transferRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Request body", NetworkLogFormatting.byteCount(record.request.body.byteCount)),
            ("Response body", NetworkLogFormatting.byteCount(record.response?.body.byteCount ?? 0))
        ]
        if let metrics = record.metrics {
            if let name = metrics.networkProtocolName { rows.append(("Protocol", name)) }
            if metrics.isReusedConnection { rows.append(("Connection", "Reused")) }
            if metrics.isCellular { rows.append(("Interface", "Cellular")) }
            if metrics.isProxyConnection { rows.append(("Proxy", "Yes")) }
        }
        return rows
    }

    // MARK: - Building blocks

    private func headersCard(_ headers: [String: String]) -> some View {
        NetworkCard(title: "Headers", count: headers.count) {
            if headers.isEmpty {
                Text("No headers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                keyValueList(headers.keys.sorted().map { ($0, headers[$0] ?? "") })
            }
        }
    }

    private func bodyCard(_ body: NetworkLogBody) -> some View {
        NetworkCard(
            title: "Body",
            subtitle: NetworkLogFormatting.bodyMeta(body),
            accessory: body.text.map { AnyView(copyButton($0)) }
        ) {
            if case .text = body.content {
                codeBlock(NetworkLogFormatting.bodyText(body))
            } else {
                Text(NetworkLogFormatting.bodyText(body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `inline` keeps short values on the same line as their key; otherwise
    /// the value wraps underneath so long tokens and URLs stay readable.
    private func keyValueList(_ entries: [(String, String)], inline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Divider().padding(.vertical, 8)
                }
                if inline {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.0)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(entry.1)
                            .font(.callout.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        valueText(entry.1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func valueText(_ value: String) -> some View {
        if value.contains("<redacted>") || value == "REDACTED" {
            Label(value, systemImage: "eye.slash")
                .font(.footnote.monospaced())
                .foregroundStyle(.orange)
        } else {
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        NetworkCodeBlock(text: text)
    }

    private func copyButton(_ text: String) -> some View {
        NetworkCopyButton(text: text)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct NetworkCopyButton: View {
    let text: String

    var body: some View {
        Button {
            ConsoleClipboard.copy(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy")
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct NetworkCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NetworkCardStyle.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Card

@available(iOS 16.0, macOS 13.0, *)
struct NetworkCard<Content: View>: View {
    var title: String?
    var count: Int?
    var subtitle: String?
    var tint: Color?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        count: Int? = nil,
        subtitle: String? = nil,
        tint: Color? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.subtitle = subtitle
        self.tint = tint
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint ?? .secondary)
                    if let count {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NetworkCardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if let tint {
                RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35))
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum NetworkCardStyle {
    #if canImport(UIKit)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let codeBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    #else
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let codeBackground = Color(nsColor: .textBackgroundColor)
    #endif
}
