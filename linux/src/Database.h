#ifndef DATABASE_H
#define DATABASE_H

#include "MediaItem.h"
#include <QString>
#include <vector>
#include <set>
#include <utility>
#include <sqlite3.h>

struct LoadResult {
    std::vector<MediaItem> items;
    QString errorMessage;
};

struct WordFrequency {
    QString word;
    int count;
};

class Database {
public:
    explicit Database(const QString& dbPath);
    ~Database();

    bool isOpen() const { return db != nullptr; }

    LoadResult loadItems(const QString& search, const QString& conditionExpression);
    void updateViewCount(int id, int viewCount);
    void updateLike(int id, int like);
    void deleteMedia(int id);

    std::vector<WordFrequency> fetchWordFrequencies();
    std::vector<WordFrequency> fetchNameFrequencies();

    void commit() {}

private:
    sqlite3* db = nullptr;
    const QString extraConditions =
        " AND filename NOT LIKE '%.jpg' AND codec_name <> 'mjpeg' "
        " AND filename NOT LIKE '%.unwanted%' AND filename NOT LIKE '%SMP-B9R%' "
        " AND filename NOT LIKE '%SAMPLE-B9R%'";

    std::set<QString> commonExtensions;

    void initCommonExtensions();
};

#endif // DATABASE_H
