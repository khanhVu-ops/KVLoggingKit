import KVLoggingNetwork
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
struct NetworkListView: View {
    @ObservedObject var model: NetworkListModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $model.filter) {
                ForEach(NetworkListModel.Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if model.visibleRecords.isEmpty {
                ConsoleEmptyState(
                    message: model.records.isEmpty
                        ? "No requests captured yet."
                        : "No requests match the filter."
                )
            } else {
                List(model.visibleRecords) { record in
                    NavigationLink {
                        NetworkLogDetailView(record: record)
                    } label: {
                        NetworkLogRow(record: record)
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by URL, method, status")
        .task { model.startObserving() }
        .onDisappear { model.stopObserving() }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct NetworkLogRow: View {
    let record: NetworkLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(NetworkLogFormatting.statusText(for: record))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        NetworkLogFormatting.statusColor(for: record),
                        in: RoundedRectangle(cornerRadius: 4)
                    )

                Text(record.request.method)
                    .font(.caption.weight(.semibold))

                Spacer()

                Text(NetworkLogFormatting.duration(record.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(record.request.path ?? record.request.url)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(record.request.host ?? "—")
                Text("·")
                Text(NetworkLogFormatting.time(record.startedAt))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
