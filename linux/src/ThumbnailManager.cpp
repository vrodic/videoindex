#include "ThumbnailManager.h"
#include <QDir>
#include <QProcess>
#include <QStandardPaths>
#include <QTemporaryFile>
#include <QUuid>
#include <QDebug>
#include <QFileInfo>

// MARK: - ThumbnailWorker

ThumbnailWorker::ThumbnailWorker(
    const QString& rootDir,
    bool saveToDisk,
    const MediaItem& selectedItem,
    const std::vector<MediaItem>& upNextItems,
    const std::optional<MediaItem>& nextItem,
    std::atomic<uint64_t>* currentTaskId,
    uint64_t taskId,
    QObject* parent
) : QThread(parent),
    m_rootDir(rootDir),
    m_saveToDisk(saveToDisk),
    m_selectedItem(selectedItem),
    m_upNextItems(upNextItems),
    m_nextItem(nextItem),
    m_currentTaskId(currentTaskId),
    m_taskId(taskId)
{
}

QString ThumbnailWorker::diskThumbPath(int id, int percent) const {
    QDir thumbsDir(QDir(m_rootDir).filePath("Thumbs"));
    return thumbsDir.filePath(QString("%1_%2.jpg").arg(id).arg(percent));
}

QImage ThumbnailWorker::loadDiskThumb(int id, int percent) const {
    QString path = diskThumbPath(id, percent);
    if (QFileInfo::exists(path)) {
        return QImage(path);
    }
    return QImage();
}

void ThumbnailWorker::saveDiskThumb(const QImage& img, int id, int percent) const {
    if (!m_saveToDisk || img.isNull()) return;
    QDir thumbsDir(QDir(m_rootDir).filePath("Thumbs"));
    if (!thumbsDir.exists()) {
        thumbsDir.mkpath(".");
    }
    QString path = diskThumbPath(id, percent);
    img.save(path, "JPG", 80);
}

double ThumbnailWorker::probeDuration(const QString& filePath) {
    QProcess proc;
    QStringList args;
    args << "-v" << "error"
         << "-show_entries" << "format=duration"
         << "-of" << "default=noprint_wrappers=1:nokey=1"
         << filePath;
    proc.start("ffprobe", args);
    if (!proc.waitForFinished(5000)) {
        proc.kill();
        return -1;
    }
    if (proc.exitCode() != 0) return -1;
    QString out = QString::fromUtf8(proc.readAllStandardOutput()).trimmed();
    bool ok = false;
    double val = out.toDouble(&ok);
    return (ok && val > 0) ? val : -1;
}

QImage ThumbnailWorker::extractFrame(const QString& filePath, double seconds) {
    QTemporaryFile tempFile(QDir::tempPath() + "/videoindex-preview-XXXXXX.png");
    if (!tempFile.open()) return QImage();
    QString tempPath = tempFile.fileName();
    tempFile.close();

    QProcess proc;
    QStringList args;
    args << "-nostdin" << "-loglevel" << "error"
         << "-ss" << QString::number(seconds, 'f', 3)
         << "-i" << filePath
         << "-frames:v" << "1"
         << "-q:v" << "3"
         << "-y" << tempPath;

    proc.start("ffmpeg", args);
    if (!proc.waitForFinished(10000)) {
        proc.kill();
        QFile::remove(tempPath);
        return QImage();
    }

    QImage img;
    if (proc.exitCode() == 0 && QFileInfo::exists(tempPath)) {
        img.load(tempPath);
    }
    QFile::remove(tempPath);
    return img;
}

void ThumbnailWorker::run() {
    struct PendingSave {
        QImage img;
        int id;
        int percent;
    };
    std::vector<PendingSave> pendingSaves;

    static const int filmstripPercents[] = {15, 30, 45, 60, 75, 90};

    // 1. Filmstrip thumbnails for selected item
    QString selPath = m_selectedItem.fullPath(m_rootDir);
    if (!QFileInfo::exists(selPath)) {
        emit fileMissing(m_selectedItem.id);
    } else {
        double duration = probeDuration(selPath);
        if (duration > 0) {
            for (int p : filmstripPercents) {
                if (isCancelled()) return;
                QImage img = loadDiskThumb(m_selectedItem.id, p);
                if (img.isNull()) {
                    double sec = duration * p / 100.0;
                    img = extractFrame(selPath, sec);
                    if (!img.isNull()) {
                        pendingSaves.push_back({img, m_selectedItem.id, p});
                    }
                }
                if (!img.isNull()) {
                    QPixmap pm = QPixmap::fromImage(img);
                    emit filmstripThumbnailReady(m_taskId, m_selectedItem.id, p, pm);
                }
            }
        }
    }

    // 2. Up Next thumbnails (45% duration)
    for (size_t slot = 0; slot < m_upNextItems.size(); ++slot) {
        if (isCancelled()) return;
        const auto& item = m_upNextItems[slot];
        QString path = item.fullPath(m_rootDir);
        if (!QFileInfo::exists(path)) {
            emit fileMissing(item.id);
            continue;
        }

        QImage img = loadDiskThumb(item.id, 45);
        if (img.isNull()) {
            double duration = probeDuration(path);
            if (duration > 0) {
                double sec = duration * 45 / 100.0;
                img = extractFrame(path, sec);
                if (!img.isNull()) {
                    pendingSaves.push_back({img, item.id, 45});
                }
            }
        }

        if (!img.isNull()) {
            QPixmap pm = QPixmap::fromImage(img);
            emit upNextThumbnailReady(m_taskId, static_cast<int>(slot), item.id, pm);
        }
    }

    // 3. Pre-cache filmstrip for immediately next item
    if (m_nextItem.has_value()) {
        const auto& nextItem = m_nextItem.value();
        if (!isCancelled()) {
            QString path = nextItem.fullPath(m_rootDir);
            if (QFileInfo::exists(path)) {
                double duration = probeDuration(path);
                if (duration > 0) {
                    for (int p : filmstripPercents) {
                        if (isCancelled()) return;
                        QImage img = loadDiskThumb(nextItem.id, p);
                        if (img.isNull()) {
                            double sec = duration * p / 100.0;
                            img = extractFrame(path, sec);
                            if (!img.isNull()) {
                                pendingSaves.push_back({img, nextItem.id, p});
                            }
                        }
                    }
                }
            } else {
                emit fileMissing(nextItem.id);
            }
        }
    }

    // 4. Save to disk after generation finishes
    for (const auto& save : pendingSaves) {
        if (isCancelled()) return;
        saveDiskThumb(save.img, save.id, save.percent);
    }
}

// MARK: - ThumbnailManager

ThumbnailManager::ThumbnailManager(const QString& rootDir, QObject* parent)
    : QObject(parent), m_rootDir(rootDir)
{
    m_memoryCache.setMaxCost(500); // Up to 500 cached pixmaps
}

ThumbnailManager::~ThumbnailManager() {
    m_taskIdCounter.fetch_add(1);
    if (m_worker) {
        m_worker->wait();
        delete m_worker;
        m_worker = nullptr;
    }
}

QString ThumbnailManager::cacheKey(int id, int percent) const {
    return QString("%1-%2").arg(id).arg(percent);
}

QString ThumbnailManager::diskThumbPath(int id, int percent) const {
    QDir thumbsDir(QDir(m_rootDir).filePath("Thumbs"));
    return thumbsDir.filePath(QString("%1_%2.jpg").arg(id).arg(percent));
}

QPixmap ThumbnailManager::getCachedThumbnail(int id, int percent) {
    QString key = cacheKey(id, percent);
    if (QPixmap* pm = m_memoryCache.object(key)) {
        return *pm;
    }

    QString path = diskThumbPath(id, percent);
    if (QFileInfo::exists(path)) {
        QPixmap pm(path);
        if (!pm.isNull()) {
            m_memoryCache.insert(key, new QPixmap(pm));
            return pm;
        }
    }
    return QPixmap();
}

void ThumbnailManager::requestThumbnails(
    const MediaItem& selectedItem,
    const std::vector<MediaItem>& upNextItems,
    const std::optional<MediaItem>& nextItem
) {
    uint64_t taskId = ++m_taskIdCounter;

    if (m_worker) {
        m_worker->wait();
        delete m_worker;
        m_worker = nullptr;
    }

    m_worker = new ThumbnailWorker(
        m_rootDir,
        m_saveToDisk,
        selectedItem,
        upNextItems,
        nextItem,
        &m_taskIdCounter,
        taskId,
        this
    );

    connect(m_worker, &ThumbnailWorker::filmstripThumbnailReady, this, &ThumbnailManager::onFilmstripReady);
    connect(m_worker, &ThumbnailWorker::upNextThumbnailReady, this, &ThumbnailManager::onUpNextReady);
    connect(m_worker, &ThumbnailWorker::fileMissing, this, &ThumbnailManager::fileMissing);

    m_worker->start();
}

void ThumbnailManager::onFilmstripReady(uint64_t taskId, int itemId, int percent, QPixmap pixmap) {
    if (taskId != m_taskIdCounter.load()) return;
    QString key = cacheKey(itemId, percent);
    if (!m_memoryCache.contains(key)) {
        m_memoryCache.insert(key, new QPixmap(pixmap));
    }
    emit filmstripThumbnailReady(itemId, percent, pixmap);
}

void ThumbnailManager::onUpNextReady(uint64_t taskId, int slot, int itemId, QPixmap pixmap) {
    if (taskId != m_taskIdCounter.load()) return;
    QString key = cacheKey(itemId, 45);
    if (!m_memoryCache.contains(key)) {
        m_memoryCache.insert(key, new QPixmap(pixmap));
    }
    emit upNextThumbnailReady(slot, itemId, pixmap);
}
