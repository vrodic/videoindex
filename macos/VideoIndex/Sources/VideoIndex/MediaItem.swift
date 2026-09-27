import Foundation

/// One row of the `media` table, mirroring the columns pulled by the
/// original query:
/// id, filename, view_count, like, file_size, viewed_time, width,
/// file_size/(duration*width)
struct MediaItem {
    let id: Int
    let filename: String
    var viewCount: Int?
    var like: Int?
    let fileSizeMB: Int
    var viewedTime: String?
    let width: Int?
    let density: Int?   // file_size / (duration * width), rounded

    /// Full path on disk, given the root media directory.
    func fullPath(root: String) -> String {
        (root as NSString).appendingPathComponent(filename)
    }
}
