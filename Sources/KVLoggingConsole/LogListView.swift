import KVLoggingKit
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
struct LogListView: View {
    @ObservedObject var model: LogListModel

    var body: some View {
        VStack(spacing: 0) {
            filters

            if model.visibleEvents.isEmpty {
                ConsoleEmptyState(
                    message: model.events.isEmpty
                        ? "No log events yet."
                        : "No events match the filter."
                )
            } else {
                List(model.visibleEvents) { event in
                    NavigationLink {
                        LogDetailView(event: event)
                    } label: {
                        LogRow(event: event)
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by message, category, metadata")
        .task { model.startObserving() }
        .onDisappear { model.stopObserving() }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Button {
                            model.minimumLevel = level
                        } label: {
                            if model.minimumLevel == level {
                                Label(LogConsoleFormatting.label(for: level), systemImage: "checkmark")
                            } else {
                                Text(LogConsoleFormatting.label(for: level))
                            }
                        }
                    }
                } label: {
                    ConsoleChip(
                        title: "≥ \(LogConsoleFormatting.label(for: model.minimumLevel))",
                        isActive: model.minimumLevel != .trace
                    )
                }

                if !model.categories.isEmpty {
                    Menu {
                        Button("All categories") { model.selectedCategory = nil }
                        ForEach(model.categories, id: \.self) { category in
                            Button(category) { model.selectedCategory = category }
                        }
                    } label: {
                        ConsoleChip(
                            title: model.selectedCategory ?? "All categories",
                            isActive: model.selectedCategory != nil
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
private struct LogRow: View {
    let event: LogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(LogConsoleFormatting.label(for: event.level))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        LogConsoleFormatting.color(for: event.level),
                        in: RoundedRectangle(cornerRadius: 4)
                    )

                if let category = event.category {
                    Text(category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(LogConsoleFormatting.time(event.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(event.message)
                .font(.callout)
                .lineLimit(3)

            if event.error != nil || !event.metadata.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let error = event.error {
            return "\(error.type)\(error.code.map { "(\($0))" } ?? "")"
        }
        return event.metadata.keys.sorted().joined(separator: " · ")
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct ConsoleChip: View {
    let title: String
    var isActive = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct ConsoleEmptyState: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
