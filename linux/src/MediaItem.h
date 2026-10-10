#ifndef MEDIAITEM_H
#define MEDIAITEM_H

#include <QString>
#include <QDir>
#include <optional>

struct MediaItem {
    int id = 0;
    QString filename;
    std::optional<int> viewCount;
    std::optional<int> like;
    int fileSizeMB = 0;
    QString viewedTime;
    std::optional<int> width;
    std::optional<int> density;

    QString fullPath(const QString& root) const {
        return QDir(root).filePath(filename);
    }
};

#endif // MEDIAITEM_H
