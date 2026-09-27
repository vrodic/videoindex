import Foundation
import SwiftUI
import AVFoundation
import AppKit

@MainActor
final class VideoIndexViewModel: ObservableObject {
    let rootDir: String
    let db: Database

    @Published var items: [MediaItem] = []
    @Published var selectedItemID: MediaItem.ID? {
        didSet {
            if selectedItemID != oldValue {
                onSelectionChanged()
            }
        }
    }

    @Published var searchTerm: String = "" {
        didSet {
            reload()
        }
    }

    @Published var conditionExpression: String {
        didSet {
            reload()
        }
    }

    @Published var statusMessage: String = ""
    @Published var isStatusError: Bool = false

    // Table sorting
    @Published var sortDescriptors: [KeyPathComparator<MediaItem>] = [] {
        didSet {
            applySort()
        }
    }

    // Preview state
    @Published var previewTitle: String = ""
    @Published var previewImages: [Int: NSImage] = [:] // percent -> image
    @Published var upNextThumbnails: [NSImage?] = []
    @Published var upNextItemIDs: [MediaItem.ID?] = []

    let previewPercentages = [15, 30, 45, 60, 75, 90]
    let upNextPercent = 45

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var previewTask: Task<Void, Never>?
    private var upNextTasks: [Int: Task<Void, Never>] = [:]

    init(rootDir: String, indexFile: String) {
        self.rootDir = rootDir
        self.db = Database(path: indexFile)
        // Mirrors the Python default: dislikes/likes-only shuffled queue,
        // most-recently-viewed last.
        self.conditionExpression = "AND like > 2 ORDER BY viewed_time, random()"
        reload()
    }

    func reload() {
        let result = db.loadItems(search: searchTerm, conditionExpression: conditionExpression)
        items = result.items
        updateStatusLabel(itemCount: items.count, errorMessage: result.errorMessage)

        if !sortDescriptors.isEmpty {
            applySortInternal()
        }

        if let selectedID = selectedItemID, items.contains(where: { $0.id == selectedID }) {
            // retain existing selection
        } else {
            selectedItemID = items.first?.id
        }

        refreshUpNext()
    }

    private func updateStatusLabel(itemCount: Int, errorMessage: String?) {
        if let errorMessage {
            isStatusError = true
            statusMessage = "Query error: \(errorMessage)"
        } else {
            isStatusError = false
            statusMessage = itemCount == 1 ? "1 item" : "\(itemCount) items"
        }
    }

    // MARK: - Sorting

    func applySort() {
        applySortInternal()
        refreshUpNext()
    }

    private func applySortInternal() {
        guard let descriptor = sortDescriptors.first else { return }
        items.sort(using: descriptor)
    }

    var selectedItem: MediaItem? {
        guard let id = selectedItemID else { return nil }
        return items.first(where: { $0.id == id })
    }

    var selectedIndex: Int? {
        guard let id = selectedItemID else { return nil }
        return items.firstIndex(where: { $0.id == id })
    }

    // MARK: - Actions

    func moveSelection(by amount: Int) {
        guard let currentIndex = selectedIndex else {
            if !items.isEmpty { selectedItemID = items.first?.id }
            return
        }
        let targetIndex = currentIndex + amount
        if items.indices.contains(targetIndex) {
            selectedItemID = items[targetIndex].id
        }
    }

    func selectFirst() {
        if let first = items.first {
            selectedItemID = first.id
        }
    }

    func selectLast() {
        if let last = items.last {
            selectedItemID = last.id
        }
    }

    func playSelected() {
        guard let item = selectedItem, let index = selectedIndex else { return }
        let path = item.fullPath(root: rootDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["mpv", path]
        try? process.run()

        let newCount = (item.viewCount ?? 0) + 1
        var updatedItem = item
        updatedItem.viewCount = newCount
        updatedItem.viewedTime = Self.sqliteNowString()
        items[index] = updatedItem
        db.updateViewCount(id: item.id, viewCount: newCount)
    }

    @discardableResult
    func adjustLike(by amount: Int) -> Int? {
        guard let item = selectedItem, let index = selectedIndex else { return nil }
        let current = item.like ?? 0
        let resolvedLike = current + amount
        var updatedItem = item
        updatedItem.like = resolvedLike
        items[index] = updatedItem
        db.updateLike(id: item.id, like: resolvedLike)
        return resolvedLike
    }

    func handleDeleteOrDislike() {
        adjustLike(by: -1)
        if !deleteSelectedIfAllowed() {
            moveSelection(by: 1)
        }
    }

    func handleLikeIncrement() {
        adjustLike(by: 1)
        moveSelection(by: 1)
    }

    func deleteSelectedIfAllowed() -> Bool {
        guard let item = selectedItem, let index = selectedIndex else { return false }
        if let like = item.like, like >= -1 {
            print("can't delete liked")
            return false
        }
        let path = item.fullPath(root: rootDir)
        try? FileManager.default.removeItem(atPath: path)
        db.deleteMedia(id: item.id)
        items.remove(at: index)

        if !items.isEmpty {
            let nextIndex = min(index, items.count - 1)
            selectedItemID = items[nextIndex].id
        } else {
            selectedItemID = nil
        }
        refreshUpNext()
        return true
    }

    func commitAndQuit() {
        db.commit()
        NSApplication.shared.terminate(nil)
    }

    private static func sqliteNowString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: - Selection & Up Next updates

    private func onSelectionChanged() {
        updatePreview(for: selectedItem)
        refreshUpNext()
    }

    func refreshUpNext(slotCount: Int = 12) {
        upNextTasks.values.forEach { $0.cancel() }
        upNextTasks.removeAll()

        guard slotCount > 0, let selectedIndex = selectedIndex else {
            upNextThumbnails = []
            upNextItemIDs = []
            return
        }

        let visibleSlice = items.suffix(from: selectedIndex).prefix(slotCount)
        let visibleItems = Array(visibleSlice)

        var newThumbnails: [NSImage?] = Array(repeating: nil, count: visibleItems.count)
        var newIDs: [MediaItem.ID?] = Array(repeating: nil, count: visibleItems.count)

        for (slot, item) in visibleItems.enumerated() {
            newIDs[slot] = item.id
            let key = cacheKey(id: item.id, percent: upNextPercent)
            if let cached = thumbnailCache.object(forKey: key) {
                newThumbnails[slot] = cached
            } else {
                loadUpNextThumbnail(item: item, slot: slot, totalSlots: visibleItems.count)
            }
        }

        upNextThumbnails = newThumbnails
        upNextItemIDs = newIDs
    }

    private func loadUpNextThumbnail(item: MediaItem, slot: Int, totalSlots: Int) {
        let key = cacheKey(id: item.id, percent: upNextPercent)
        let requestedID = item.id
        let url = URL(fileURLWithPath: item.fullPath(root: rootDir))

        let task = Task {
            let asset = AVURLAsset(url: url)
            guard let durationSeconds = await self.loadDuration(asset: asset, url: url) else { return }
            if Task.isCancelled { return }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let seconds = durationSeconds * Double(self.upNextPercent) / 100
            guard let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds) else { return }
            if Task.isCancelled { return }

            self.thumbnailCache.setObject(image, forKey: key)

            await MainActor.run {
                if slot < self.upNextItemIDs.count, self.upNextItemIDs[slot] == requestedID {
                    if slot < self.upNextThumbnails.count {
                        self.upNextThumbnails[slot] = image
                    }
                }
            }
        }
        upNextTasks[slot] = task
    }

    // MARK: - Preview Filmstrip with Cancellation

    private func updatePreview(for item: MediaItem?) {
        previewTask?.cancel()
        previewTask = nil

        guard let item = item else {
            previewTitle = ""
            previewImages = [:]
            return
        }

        previewTitle = item.filename
        let requestedID = item.id
        let url = URL(fileURLWithPath: item.fullPath(root: rootDir))

        var currentImages: [Int: NSImage] = [:]
        var percentsNeeded: [Int] = []

        for percent in previewPercentages {
            let key = cacheKey(id: requestedID, percent: percent)
            if let cached = thumbnailCache.object(forKey: key) {
                currentImages[percent] = cached
            } else {
                percentsNeeded.append(percent)
            }
        }

        previewImages = currentImages
        guard !percentsNeeded.isEmpty else { return }

        previewTask = Task {
            let asset = AVURLAsset(url: url)
            guard let durationSeconds = await self.loadDuration(asset: asset, url: url) else { return }
            if Task.isCancelled { return }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for percent in percentsNeeded {
                    group.addTask {
                        if Task.isCancelled { return (percent, nil) }
                        let seconds = durationSeconds * Double(percent) / 100
                        let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds)
                        return (percent, image)
                    }
                }

                for await (percent, image) in group {
                    if Task.isCancelled { break }
                    guard let image = image else { continue }
                    self.thumbnailCache.setObject(image, forKey: self.cacheKey(id: requestedID, percent: percent))

                    await MainActor.run {
                        if self.selectedItemID == requestedID {
                            self.previewImages[percent] = image
                        }
                    }
                }
            }
        }
    }

    private func cacheKey(id: Int, percent: Int) -> NSString {
        "\(id)-\(percent)" as NSString
    }

    private func loadDuration(asset: AVURLAsset, url: URL) async -> Double? {
        if let duration = try? await asset.load(.duration),
           duration.isValid, duration.seconds.isFinite, duration.seconds > 0 {
            return duration.seconds
        }
        return await probeDurationViaFFmpeg(url: url)
    }

    private func generateFrame(generator: AVAssetImageGenerator, url: URL, atSeconds seconds: Double) async -> NSImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if let (cgImage, _) = try? await generator.image(at: time) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return await extractFrameViaFFmpeg(url: url, atSeconds: seconds)
    }

    private func probeDurationViaFFmpeg(url: URL) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let seconds = Double(text), seconds.isFinite, seconds > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: seconds)
            }
        }
    }

    private func extractFrameViaFFmpeg(url: URL, atSeconds seconds: Double) async -> NSImage? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoindex-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-loglevel", "error",
            "-ss", String(seconds), "-i", url.path,
            "-frames:v", "1", "-q:v", "3", "-y", outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        return NSImage(contentsOf: outputURL)
    }
}
