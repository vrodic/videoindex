#ifndef THUMBNAILMANAGER_H
#define THUMBNAILMANAGER_H

#include <QObject>
#include <QString>
#include <QPixmap>
#include <QCache>
#include <QThread>
#include <QMutex>
#include <QWaitCondition>
#include <atomic>
#include <vector>
#include <memory>
#include "MediaItem.h"

class ThumbnailWorker : public QThread {
    Q_OBJECT
public:
    ThumbnailWorker(
        const QString& rootDir,
        bool saveToDisk,
        const MediaItem& selectedItem,
        const std::vector<MediaItem>& upNextItems,
        const std::optional<MediaItem>& nextItem,
        std::atomic<uint64_t>* currentTaskId,
        uint64_t taskId,
        QObject* parent = nullptr
    );

    void run() override;

signals:
    void filmstripThumbnailReady(uint64_t taskId, int itemId, int percent, QPixmap pixmap);
    void upNextThumbnailReady(uint64_t taskId, int slot, int itemId, QPixmap pixmap);
    void fileMissing(int itemId);

private:
    QString m_rootDir;
    bool m_saveToDisk;
    MediaItem m_selectedItem;
    std::vector<MediaItem> m_upNextItems;
    std::optional<MediaItem> m_nextItem;
    std::atomic<uint64_t>* m_currentTaskId;
    uint64_t m_taskId;

    double probeDuration(const QString& filePath);
    QImage extractFrame(const QString& filePath, double seconds);
    QString diskThumbPath(int id, int percent) const;
    QImage loadDiskThumb(int id, int percent) const;
    void saveDiskThumb(const QImage& img, int id, int percent) const;
    bool isCancelled() const { return m_currentTaskId->load() != m_taskId; }
};

class ThumbnailManager : public QObject {
    Q_OBJECT
public:
    explicit ThumbnailManager(const QString& rootDir, QObject* parent = nullptr);
    ~ThumbnailManager();

    void setSaveThumbnailsToDisk(bool enable) { m_saveToDisk = enable; }
    bool saveThumbnailsToDisk() const { return m_saveToDisk; }

    QPixmap getCachedThumbnail(int id, int percent);

    void requestThumbnails(
        const MediaItem& selectedItem,
        const std::vector<MediaItem>& upNextItems,
        const std::optional<MediaItem>& nextItem
    );

signals:
    void filmstripThumbnailReady(int itemId, int percent, QPixmap pixmap);
    void upNextThumbnailReady(int slot, int itemId, QPixmap pixmap);
    void fileMissing(int itemId);

private slots:
    void onFilmstripReady(uint64_t taskId, int itemId, int percent, QPixmap pixmap);
    void onUpNextReady(uint64_t taskId, int slot, int itemId, QPixmap pixmap);

private:
    QString m_rootDir;
    bool m_saveToDisk = true;
    QCache<QString, QPixmap> m_memoryCache;
    std::atomic<uint64_t> m_taskIdCounter{0};
    ThumbnailWorker* m_worker = nullptr;

    QString cacheKey(int id, int percent) const;
    QString diskThumbPath(int id, int percent) const;
};

#endif // THUMBNAILMANAGER_H
