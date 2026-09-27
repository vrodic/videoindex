import Foundation

/// One row of the `media` table, mirroring the columns pulled by the
/// original query:
/// id, filename, view_count, like, file_size, viewed_time, width,
/// file_size/(duration*width)
struct MediaItem: Identifiable, Equatable, Hashable {
    let id: Int
    let filename: String
    var viewCount: Int?
    var like: Int?
    let fileSizeMB: Int
    var viewedTime: String?
    let width: Int?
    let density: Int?   // file_size / (duration * width), rounded

    // Non-optional helper properties for SwiftUI Table sorting
    var sortViewCount: Int { viewCount ?? -1 }
    var sortLike: Int { like ?? Int.min }
    var sortViewedTime: String { viewedTime ?? "" }
    var sortWidth: Int { width ?? -1 }
    var sortDensity: Int { density ?? -1 }

    /// Full path on disk, given the root media directory.
    func fullPath(root: String) -> String {
        (root as NSString).appendingPathComponent(filename)
    }
}
