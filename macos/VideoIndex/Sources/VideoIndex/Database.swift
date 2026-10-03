import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper around the SQLite index database, replicating the
/// queries used by the original Python/PyQt tool.
final class Database {
    private var db: OpaquePointer?

    /// Extra filtering the Python version always applied, kept as-is.
    private let extraConditions =
        " AND filename NOT LIKE '%.jpg' AND codec_name <> 'mjpeg' " +
        " AND filename NOT LIKE '%.unwanted%' AND filename NOT LIKE '%SMP-B9R%' " +
        " AND filename NOT LIKE '%SAMPLE-B9R%'"

    init(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            fatalError("Unable to open database at \(path): \(message)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// What one `loadItems` call produces: the matching rows, or — if the
    /// free-form condition fragment was malformed SQL — the rows are empty
    /// and `errorMessage` explains why, so the UI can show *that* instead of
    /// silently rendering an empty table (the Python version only printed
    /// this to the console).
    struct LoadResult {
        let items: [MediaItem]
        let errorMessage: String?
    }

    /// Loads items matching `search` (substring of filename), filtered/ordered
    /// by the free-form SQL fragment in `conditionExpression` (e.g.
    /// "ORDER BY view_count ASC" or "AND like > 2 ORDER BY viewed_time, random()").
    func loadItems(search: String, conditionExpression: String) -> LoadResult {
        let sql = """
        SELECT id, filename, view_count, like, file_size, viewed_time, width,
               file_size / (duration * width)
        FROM media
        WHERE filename LIKE ? \(extraConditions) \(conditionExpression)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            print("Query failed: \(message)\nSQL: \(sql)")
            return LoadResult(items: [], errorMessage: message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "%\(search)%", -1, SQLITE_TRANSIENT)

        var results: [MediaItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(statement, 0))
            let filename = columnText(statement, 1) ?? ""
            let viewCount = columnInt(statement, 2)
            let like = columnInt(statement, 3)
            let fileSize = sqlite3_column_int64(statement, 4)
            let viewedTime = columnText(statement, 5)
            let width = columnInt(statement, 6)
            let density = columnInt(statement, 7)

            results.append(MediaItem(
                id: id,
                filename: filename,
                viewCount: viewCount,
                like: like,
                fileSizeMB: Int(fileSize / (1024 * 1024)),
                viewedTime: viewedTime,
                width: width,
                density: density
            ))
        }
        return LoadResult(items: results, errorMessage: nil)
    }

    func updateViewCount(id: Int, viewCount: Int) {
        let sql = "UPDATE media SET view_count = ?, viewed_time = datetime('now') WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(viewCount))
        sqlite3_bind_int(statement, 2, Int32(id))
        sqlite3_step(statement)
    }

    func updateLike(id: Int, like: Int) {
        let sql = "UPDATE media SET like = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(like))
        sqlite3_bind_int(statement, 2, Int32(id))
        sqlite3_step(statement)
    }

    func deleteMedia(id: Int) {
        let sql = "DELETE FROM media WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(id))
        sqlite3_step(statement)
    }

    /// Fetches word frequencies from all filenames in the database.
    /// Returns an array of (word, count) sorted by count descending.
    func fetchWordFrequencies() -> [(word: String, count: Int)] {
        let sql = "SELECT filename FROM media WHERE 1=1 \(extraConditions)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var wordCounts: [String: Int] = [:]
        let commonExtensions: Set<String> = [
            "mp4", "mkv", "avi", "wmv", "mov", "flv", "webm", "mpg", "mpeg",
            "m4v", "ts", "3gp", "vob", "divx", "xvid", "zip", "rar", "jpg", "jpeg", "png"
        ]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let filename = columnText(statement, 0) else { continue }

            // Split by non-alphanumeric characters
            let components = filename.components(separatedBy: CharacterSet.alphanumerics.inverted)

            var uniqueWordsInFile = Set<String>()
            for rawComponent in components {
                let word = rawComponent.lowercased()
                if word.count <= 2 { continue }
                if commonExtensions.contains(word) { continue }
                uniqueWordsInFile.insert(word)
            }

            for word in uniqueWordsInFile {
                wordCounts[word, default: 0] += 1
            }
        }

        return wordCounts.map { (word: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.word < $1.word
            }
    }

    /// SQLite auto-commits each statement by default, so this is a no-op —
    /// kept only for parity with the Python code's explicit connection.commit().
    func commit() {}

    // MARK: - Helpers

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }
}
