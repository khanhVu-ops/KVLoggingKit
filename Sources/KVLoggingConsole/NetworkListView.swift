import KVLoggingNetwork
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
struct NetworkListView: View {
    @ObservedObject var model: NetworkListModel

    var body: some View {
        VStack(spacing: 0) {
            filters

            if model.visibleRecords.isEmpty {
                ConsoleEmptyState(
                    message: model.records.isEmpty
                        ? "No requests captured yet."
                        : "No requests match the filter."
                )
            } else {
                List(model.visibleRecords) { record in
                    NavigationLink {
                        LiveNetworkLogDetailView(id: record.id, fallback: record, model: model)
                    } label: {
                        NetworkLogRow(record: record)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by URL, method, status")
        .task { model.startObserving() }
        .onDisappear { model.stopObserving() }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NetworkListModel.Filter.allCases) { filter in
                    let count = model.count(for: filter)
                    if filter == .all || filter == model.filter || count > 0 {
                        Button {
                            model.filter = filter
                        } label: {
                            ConsoleChip(
                                title: "\(filter.rawValue) \(count)",
                                isActive: model.filter == filter
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.hosts.count > 1 {
                    Menu {
                        Button("All hosts") { model.selectedHost = nil }
                        ForEach(model.hosts, id: \.self) { host in
                            Button(host) { model.selectedHost = host }
                        }
                    } label: {
                        ConsoleChip(
                            title: model.selectedHost ?? "All hosts",
                            isActive: model.selectedHost != nil
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct NetworkLogRow: View {
    let record: NetworkLogRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NetworkMethodBadge(method: record.request.method)
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.request.path ?? record.request.url)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if record.isEventStream {
                        NetworkStreamTag(isLive: record.state == .pending)
                    }
                    Text("\(record.request.host ?? "—") · \(NetworkLogFormatting.shortTime(record.startedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let error = record.error {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if record.state == .pending, record.response == nil {
                    ProgressView().controlSize(.small)
                } else if record.state == .pending, let statusCode = record.statusCode {
                    // Head received, body still streaming.
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(String(statusCode))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(NetworkLogFormatting.statusText(for: record))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(NetworkLogFormatting.statusColor(for: record))
                }

                Text(trailingDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trailingDetail: String {
        if let stream = record.stream {
            let events = NetworkLogFormatting.eventCount(stream.totalEventCount)
            guard record.state != .pending else { return events }
            return "\(NetworkLogFormatting.duration(record.duration)) · \(events)"
        }
        let duration = NetworkLogFormatting.duration(record.duration)
        guard let size = NetworkLogFormatting.responseSize(for: record) else { return duration }
        return "\(duration) · \(size)"
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct NetworkMethodBadge: View {
    let method: String

    var body: some View {
        let color = NetworkLogFormatting.methodColor(method)
        Text(method.uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Keeps an open detail screen in step with the store, so a stream that is
/// still running keeps adding events while you watch it.
@available(iOS 16.0, macOS 13.0, *)
private struct LiveNetworkLogDetailView: View {
    let id: UUID
    let fallback: NetworkLogRecord
    @ObservedObject var model: NetworkListModel

    var body: some View {
        NetworkLogDetailView(record: model.records.first { $0.id == id } ?? fallback)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct NetworkStreamTag: View {
    var isLive = false

    var body: some View {
        HStack(spacing: 3) {
            if isLive {
                Circle().fill(Color.red).frame(width: 5, height: 5)
            }
            Text(isLive ? "LIVE" : "SSE")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(Color.indigo)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.indigo.opacity(0.14), in: Capsule())
    }
}
