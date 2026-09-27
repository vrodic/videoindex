import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject var viewModel: VideoIndexViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Search Bar
            TextField("Search filename…", text: $viewModel.searchTerm)
                .textFieldStyle(.roundedBorder)

            // Split View: Table | Preview Panel
            HSplitView {
                // Media Items Table
                Table(viewModel.items, selection: $viewModel.selectedItemID, sortOrder: $viewModel.sortDescriptors) {
                    TableColumn("ID", value: \.id) { item in
                        Text("\(item.id)")
                    }
                    .width(min: 40, ideal: 60)

                    TableColumn("Filename", value: \.filename) { item in
                        Text(item.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 200, ideal: 520)

                    TableColumn("Views", value: \.sortViewCount) { item in
                        Text(item.viewCount.map(String.init) ?? "")
                    }
                    .width(min: 40, ideal: 60)

                    TableColumn("Likes", value: \.sortLike) { item in
                        Text(item.like.map(String.init) ?? "")
                            .foregroundColor(likeColor(for: item.like))
                    }
                    .width(min: 40, ideal: 60)

                    TableColumn("Size (MB)", value: \.fileSizeMB) { item in
                        Text("\(item.fileSizeMB)")
                    }
                    .width(min: 60, ideal: 90)

                    TableColumn("Last Viewed", value: \.sortViewedTime) { item in
                        Text(item.viewedTime ?? "")
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Width", value: \.sortWidth) { item in
                        Text(item.width.map(String.init) ?? "")
                    }
                    .width(min: 50, ideal: 70)

                    TableColumn("Density", value: \.sortDensity) { item in
                        Text(item.density.map(String.init) ?? "")
                    }
                    .width(min: 50, ideal: 80)
                }
                .frame(minWidth: 600)

                // Right Panel: Filmstrip + Up Next
                PreviewPanelView(viewModel: viewModel)
                    .frame(minWidth: 380)
            }

            // Custom SQL Condition
            TextField("SQL condition / ORDER BY…", text: $viewModel.conditionExpression)
                .textFieldStyle(.roundedBorder)

            // Status Bar
            HStack {
                Text(viewModel.statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(viewModel.isStatusError ? .red : .secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(10)
        .background(
            KeyEventHandlerContainer(
                onPlay: { viewModel.playSelected() },
                onLikeIncrement: { viewModel.handleLikeIncrement() },
                onDeleteOrDislike: { viewModel.handleDeleteOrDislike() },
                onHome: { viewModel.selectFirst() },
                onEnd: { viewModel.selectLast() },
                onEscape: { viewModel.commitAndQuit() }
            )
            .frame(width: 0, height: 0)
        )
    }

    private func likeColor(for like: Int?) -> Color {
        guard let like = like else { return .primary }
        if like > 0 {
            return .green
        } else if like < 0 {
            return .red
        } else {
            return .primary
        }
    }
}
