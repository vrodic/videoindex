#include "Database.h"
#include <QRegularExpression>
#include <QDateTime>
#include <QDebug>
#include <algorithm>

Database::Database(const QString& dbPath) {
    if (sqlite3_open(dbPath.toUtf8().constData(), &db) != SQLITE_OK) {
        qWarning() << "Unable to open database at" << dbPath << ":" << sqlite3_errmsg(db);
        db = nullptr;
    }
    initCommonExtensions();
}

Database::~Database() {
    if (db) {
        sqlite3_close(db);
        db = nullptr;
    }
}

void Database::initCommonExtensions() {
    static const char* extList[] = {
        "mp4", "mkv", "avi", "wmv", "mov", "flv", "webm", "mpg", "mpeg",
        "m4v", "ts", "3gp", "vob", "divx", "xvid", "zip", "rar", "jpg", "jpeg", "png",
        "the","and","web","videos","1080p","720p","com","with","source","video","art","aac",
        "siterip","xxx","clips","pack","1080","h265","x264","rip","split","all","1280","720","avc","collection",
        "apr","vip","sep","aug","jul","264","6000","full","partial","30fps","60fps","like","net","dvdrip","x265",
        "vid","265","you","jun","2160p","3x7z0p","2600","jan","combined","first","hevc","fullcomplete",
        "has","one","this","more","720hd","aac2","part","h264","vol","from","img","dvd","get","b9r","your","mixed","mvi"
    };
    for (const char* ext : extList) {
        commonExtensions.insert(QString::fromUtf8(ext));
    }
}

LoadResult Database::loadItems(const QString& search, const QString& conditionExpression) {
    LoadResult result;
    if (!db) {
        result.errorMessage = "Database not open";
        return result;
    }

    QString sql = QString(
        "SELECT id, filename, view_count, like, file_size, viewed_time, width, "
        "file_size / (duration * width) "
        "FROM media "
        "WHERE filename LIKE ? %1 %2"
    ).arg(extraConditions, conditionExpression);

    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.toUtf8().constData(), -1, &stmt, nullptr) != SQLITE_OK) {
        result.errorMessage = QString::fromUtf8(sqlite3_errmsg(db));
        return result;
    }

    QString searchPattern = "%" + search + "%";
    sqlite3_bind_text(stmt, 1, searchPattern.toUtf8().constData(), -1, SQLITE_TRANSIENT);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        MediaItem item;
        item.id = sqlite3_column_int(stmt, 0);

        const unsigned char* fn = sqlite3_column_text(stmt, 1);
        item.filename = fn ? QString::fromUtf8(reinterpret_cast<const char*>(fn)) : "";

        if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
            item.viewCount = sqlite3_column_int(stmt, 2);
        }

        if (sqlite3_column_type(stmt, 3) != SQLITE_NULL) {
            item.like = sqlite3_column_int(stmt, 3);
        }

        sqlite3_int64 fileSize = sqlite3_column_int64(stmt, 4);
        item.fileSizeMB = static_cast<int>(fileSize / (1024 * 1024));

        if (sqlite3_column_type(stmt, 5) != SQLITE_NULL) {
            const unsigned char* vt = sqlite3_column_text(stmt, 5);
            item.viewedTime = vt ? QString::fromUtf8(reinterpret_cast<const char*>(vt)) : "";
        }

        if (sqlite3_column_type(stmt, 6) != SQLITE_NULL) {
            item.width = sqlite3_column_int(stmt, 6);
        }

        if (sqlite3_column_type(stmt, 7) != SQLITE_NULL) {
            item.density = static_cast<int>(sqlite3_column_double(stmt, 7));
        }

        result.items.push_back(item);
    }

    sqlite3_finalize(stmt);
    return result;
}

void Database::updateViewCount(int id, int viewCount) {
    if (!db) return;
    const char* sql = "UPDATE media SET view_count = ?, viewed_time = datetime('now') WHERE id = ?";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, viewCount);
        sqlite3_bind_int(stmt, 2, id);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

void Database::updateLike(int id, int like) {
    if (!db) return;
    const char* sql = "UPDATE media SET like = ? WHERE id = ?";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, like);
        sqlite3_bind_int(stmt, 2, id);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

void Database::deleteMedia(int id) {
    if (!db) return;
    const char* sql = "DELETE FROM media WHERE id = ?";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, id);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

std::vector<WordFrequency> Database::fetchWordFrequencies() {
    std::vector<WordFrequency> result;
    if (!db) return result;

    QString sql = QString("SELECT filename FROM media WHERE 1=1 %1").arg(extraConditions);
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.toUtf8().constData(), -1, &stmt, nullptr) != SQLITE_OK) {
        return result;
    }

    QMap<QString, int> wordCounts;
    QRegularExpression nonAlpha("\\W+");

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char* fn = sqlite3_column_text(stmt, 0);
        if (!fn) continue;
        QString filename = QString::fromUtf8(reinterpret_cast<const char*>(fn));

        QStringList components = filename.split(nonAlpha, Qt::SkipEmptyParts);
        std::set<QString> uniqueWordsInFile;

        for (const QString& raw : components) {
            QString word = raw.toLower();
            if (word.length() <= 2) continue;
            if (commonExtensions.count(word) > 0) continue;

            bool isNum = false;
            word.toDouble(&isNum);
            if (isNum) continue;

            uniqueWordsInFile.insert(word);
        }

        for (const QString& w : uniqueWordsInFile) {
            wordCounts[w]++;
        }
    }
    sqlite3_finalize(stmt);

    for (auto it = wordCounts.begin(); it != wordCounts.end(); ++it) {
        result.push_back({it.key(), it.value()});
    }

    std::sort(result.begin(), result.end(), [](const WordFrequency& a, const WordFrequency& b) {
        if (a.count != b.count) return a.count > b.count;
        return a.word < b.word;
    });

    return result;
}

std::vector<WordFrequency> Database::fetchNameFrequencies() {
    std::vector<WordFrequency> result;
    if (!db) return result;

    QString sql = QString("SELECT filename FROM media WHERE 1=1 %1").arg(extraConditions);
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.toUtf8().constData(), -1, &stmt, nullptr) != SQLITE_OK) {
        return result;
    }

    QMap<QString, int> nameCounts;
    QRegularExpression nonAlpha("\\W+");

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char* fn = sqlite3_column_text(stmt, 0);
        if (!fn) continue;
        QString filename = QString::fromUtf8(reinterpret_cast<const char*>(fn));

        QStringList components = filename.split(nonAlpha, Qt::SkipEmptyParts);
        std::vector<QString> validWords;

        for (const QString& raw : components) {
            QString word = raw.toLower();
            if (word.length() <= 2) continue;
            if (commonExtensions.count(word) > 0) continue;

            bool isNum = false;
            word.toDouble(&isNum);
            if (isNum) continue;

            validWords.push_back(word);
        }

        if (validWords.size() < 2) continue;

        std::set<QString> uniqueNamesInFile;
        for (size_t i = 0; i < validWords.size() - 1; ++i) {
            QString pair = validWords[i] + "_" + validWords[i+1];
            uniqueNamesInFile.insert(pair);
        }

        for (const QString& namePair : uniqueNamesInFile) {
            nameCounts[namePair]++;
        }
    }
    sqlite3_finalize(stmt);

    for (auto it = nameCounts.begin(); it != nameCounts.end(); ++it) {
        result.push_back({it.key(), it.value()});
    }

    std::sort(result.begin(), result.end(), [](const WordFrequency& a, const WordFrequency& b) {
        if (a.count != b.count) return a.count > b.count;
        return a.word < b.word;
    });

    return result;
}
