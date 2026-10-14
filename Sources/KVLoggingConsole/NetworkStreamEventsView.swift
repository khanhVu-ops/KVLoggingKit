import KVLoggingNetwork
import SwiftUI

/// The Events tab of a server-sent events response: the answer as the user
/// saw it, a breakdown by event type, and every event with its arrival time.
@available(iOS 16.0, macOS 13.0, *)
struct NetworkStreamEventsView: View {
    let stream: NetworkStreamLog
    let isLive: Bool

    @State private var selectedType: String?
    @State private var expanded: Set<Int> = []
    @State private var visibleLimit = Self.pageSize

    /// Rows rendered at once. A token-by-token stream reaches thousands of
    /// events, and every row is a few views.
    private static let pageSize = 200
    private static let untyped = "message"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let assembled = stream.assembledText
            if !assembled.isEmpty {
                NetworkCard(
                    title: "Assembled text",
                    subtitle: "\(assembled.count) characters",
                    accessory: AnyView(NetworkCopyButton(text: assembled))
                ) {
                    Text(assembled)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            typeFilter

            NetworkCard(
                title: "Events",
                count: filteredEvents.count,
                accessory: AnyView(NetworkCopyButton(text: rawText(filteredEvents)))
            ) {
                eventList
            }
        }
    }

    // MARK: - Type filter

    /// Types in order of first appearance, with their counts.
    private var typeCounts: [(type: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for event in stream.events {
            let type = event.type ?? Self.untyped
            if counts[type] == nil { order.append(type) }
            counts[type, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    @ViewBuilder
    private var typeFilter: some View {
        let types = typeCounts
        if types.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedType = nil
                    } label: {
                        ConsoleChip(title: "All \(stream.events.count)", isActive: selectedType == nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(types, id: \.type) { entry in
                        Button {
                            selectedType = selectedType == entry.type ? nil : entry.type
                        } label: {
                            ConsoleChip(title: "\(entry.type) \(entry.count)", isActive: selectedType == entry.type)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filteredEvents: [NetworkStreamEvent] {
        guard let selectedType else { return stream.events }
        return stream.events.filter { ($0.type ?? Self.untyped) == selectedType }
    }

    // MARK: - Event list

    @ViewBuilder
    private var eventList: some View {
        let events = filteredEvents
        let hidden = max(0, events.count - visibleLimit)

        VStack(alignment: .leading, spacing: 0) {
            if stream.droppedEventCount > 0 {
                note("\(stream.droppedEventCount) earlier events were dropped to bound memory.")
                Divider().padding(.vertical, 8)
            }

            if hidden > 0 {
                Button("Show \(min(hidden, Self.pageSize)) earlier of \(hidden)") {
                    visibleLimit += Self.pageSize
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.borderless)
                Divider().padding(.vertical, 8)
            }

            if events.isEmpty {
                note(isLive ? "Waiting for the first event…" : "No events.")
            }

            // Newest last, the order they arrived in, so a live stream grows downwards.
            ForEach(Array(events.suffix(visibleLimit).enumerated()), id: \.element.id) { index, event in
                if index > 0 || hidden > 0 {
                    Divider().padding(.vertical, 8)
                }
                row(event)
            }

            if isLive {
                Divider().padding(.vertical, 8)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Streaming…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ event: NetworkStreamEvent) -> some View {
        let isExpanded = expanded.contains(event.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(NetworkLogFormatting.offset(event.offset))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                typeBadge(event.type)

                if event.isTruncated {
                    Text("elided")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 4)

                Text(NetworkLogFormatting.byteCount(event.byteCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            if isExpanded {
                HStack(alignment: .top) {
                    if let id = event.lastEventID {
                        Text("id: \(id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NetworkCopyButton(text: event.data)
                }
                NetworkCodeBlock(text: NetworkLogFormatting.prettyEventData(event.data))
            } else {
                Text(preview(event))
                    .font(.caption.monospaced())
                    .foregroundStyle(event.text == nil ? .secondary : .primary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded {
                expanded.remove(event.id)
            } else {
                expanded.insert(event.id)
            }
        }
    }

    /// Text deltas read better as the text they carry than as their JSON.
    private func preview(_ event: NetworkStreamEvent) -> String {
        if let text = event.text {
            return "“" + text.replacingOccurrences(of: "\n", with: "⏎") + "”"
        }
        return event.data.isEmpty ? "(no data)" : event.data
    }

    private func typeBadge(_ type: String?) -> some View {
        let color = NetworkLogFormatting.eventColor(type)
        return Text(type ?? Self.untyped)
            .font(.caption2.weight(.semibold).monospaced())
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func rawText(_ events: [NetworkStreamEvent]) -> String {
        events.map { event in
            var block = ""
            if let name = event.event { block += "event: \(name)\n" }
            block += event.data.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "data: \($0)\n" }
                .joined()
            return block
        }
        .joined(separator: "\n")
    }
}
