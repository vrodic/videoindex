import SwiftUI
import AppKit

struct PreviewPanelView: View {
    @ObservedObject var viewModel: VideoIndexViewModel

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 10) {
                // Filmstrip (Left side of preview panel)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.previewTitle)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.bottom, 2)

                        ForEach(viewModel.previewPercentages, id: \.self) { percent in
                            ThumbnailRow(percent: percent, image: viewModel.previewImages[percent])
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity)

                // Up Next (Right side of preview panel)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up Next")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.top, 8)
                        .padding(.leading, 8)

                    UpNextColumnView(viewModel: viewModel, totalHeight: geometry.size.height)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ThumbnailRow: View {
    let percent: Int
    let image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color(NSColor.underPageBackgroundColor))
                        .aspectRatio(16/9, contentMode: .fit)
                }
            }
            .cornerRadius(4)

            Text("\(percent)%")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

struct UpNextColumnView: View {
    @ObservedObject var viewModel: VideoIndexViewModel
    let totalHeight: CGFloat

    private let rowAspect: CGFloat = 9.0 / 16.0
    private let rowSpacing: CGFloat = 8.0

    var body: some View {
        GeometryReader { geo in
            let availableHeight = max(0, totalHeight - 40)
            let rowHeight = geo.size.width * rowAspect
            let slots = max(0, min(24, Int((availableHeight + rowSpacing) / (rowHeight + rowSpacing))))

            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(0..<slots, id: \.self) { slot in
                    if slot < viewModel.upNextThumbnails.count {
                        UpNextSlotView(
                            slot: slot,
                            image: viewModel.upNextThumbnails[slot],
                            itemID: slot < viewModel.upNextItemIDs.count ? viewModel.upNextItemIDs[slot] : nil,
                            filename: slot < viewModel.upNextItemIDs.count ? viewModel.items.first(where: { $0.id == viewModel.upNextItemIDs[slot] })?.filename : nil,
                            onSelect: { itemID in
                                if let itemID = itemID {
                                    viewModel.selectedItemID = itemID
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .onChange(of: slots) { newSlots in
                viewModel.refreshUpNext(slotCount: newSlots)
            }
            .onAppear {
                viewModel.refreshUpNext(slotCount: slots)
            }
        }
    }
}

struct UpNextSlotView: View {
    let slot: Int
    let image: NSImage?
    let itemID: MediaItem.ID?
    let filename: String?
    let onSelect: (MediaItem.ID?) -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color(NSColor.underPageBackgroundColor))
                    .aspectRatio(16/9, contentMode: .fit)
            }
        }
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(slot == 0 ? Color(NSColor.controlAccentColor) : Color.clear, lineWidth: slot == 0 ? 2 : 0)
        )
        .help(filename ?? "")
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            onSelect(itemID)
        }
    }
}
