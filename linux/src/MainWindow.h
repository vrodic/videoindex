#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QLineEdit>
#include <QComboBox>
#include <QLabel>
#include <QPushButton>
#include <QSplitter>
#include <QMenu>
#include <QAction>
#include <QSettings>
#include <QAbstractTableModel>
#include <set>
#include <vector>
#include <memory>

#include "Database.h"
#include "MediaItem.h"
#include "ThumbnailManager.h"
#include "ShortcutTableView.h"
#include "CustomItemDelegate.h"
#include "ClickableThumbnailLabel.h"

class MediaTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    explicit MediaTableModel(QObject* parent = nullptr);

    void setItems(const std::vector<MediaItem>& items);
    const std::vector<MediaItem>& items() const { return m_items; }
    const MediaItem* itemAt(int row) const;

    void updateRow(int row);

    void setSessionPlayedIDs(const std::set<int>& ids);
    void setMissingFileIDs(const std::set<int>& ids);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    int columnCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;
    void sort(int column, Qt::SortOrder order = Qt::AscendingOrder) override;

private:
    std::vector<MediaItem> m_items;
    std::set<int> m_sessionPlayedIDs;
    std::set<int> m_missingFileIDs;
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    MainWindow(const QString& rootDir, const QString& indexFile, QWidget* parent = nullptr);
    ~MainWindow();

protected:
    void closeEvent(QCloseEvent* event) override;

private slots:
    void onSearchTextChanged(const QString& text);
    void onConditionTextChanged(const QString& text);
    void onConditionComboIndexChanged(int index);
    void onTableSelectionChanged();
    void onHeaderClicked(int logicalIndex);

    // Menu Actions
    void openWordCloud();
    void reloadQuery();
    void focusSearchField();
    void focusConditionField();
    void playSelectedMedia();
    void likeSelectedMedia();
    void deleteOrDislikeSelectedMedia();
    void selectFirstItem();
    void selectLastItem();
    void toggleSaveThumbnailsToDisk();

    // Thumbnail Signals
    void onFilmstripReady(int itemId, int percent, QPixmap pixmap);
    void onUpNextReady(int slot, int itemId, QPixmap pixmap);
    void onFileMissing(int itemId);

private:
    QString m_rootDir;
    QString m_indexFile;
    Database m_db;
    ThumbnailManager* m_thumbManager = nullptr;

    QString m_searchTerm;
    QString m_conditionExpression;

    std::vector<MediaItem> m_items;
    std::set<int> m_sessionPlayedIDs;
    std::set<int> m_missingFileIDs;

    bool m_lastQuerySucceeded = false;
    bool m_hasAddedCurrentConditionToHistory = true;

    // Default presets
    QStringList m_defaultConditions;

    // MPV Options
    bool m_mpvVolumeMax1000 = true;
    QString m_mpvVolume = "33";
    bool m_mpvMute = false;
    bool m_mpvLoop = false;
    bool m_mpvNoAudio = false;
    bool m_mpvKeepOpen = false;
    bool m_mpvOntop = false;
    bool m_mpvHwdec = false;
    QString m_mpvAutofitSize = "75%x75%";
    QString m_mpvSpeed = "1.0";

    // UI Widgets
    QLineEdit* m_searchField = nullptr;
    QPushButton* m_wordCloudButton = nullptr;
    ShortcutTableView* m_tableView = nullptr;
    MediaTableModel* m_tableModel = nullptr;
    CustomItemDelegate* m_itemDelegate = nullptr;
    QComboBox* m_conditionField = nullptr;
    QLabel* m_statusLabel = nullptr;
    QSplitter* m_mainSplitter = nullptr;

    // Right Preview Pane
    QLabel* m_previewTitleLabel = nullptr;
    std::map<int, ClickableThumbnailLabel*> m_previewLabels;
    std::vector<ClickableThumbnailLabel*> m_upNextLabels;
    std::vector<std::optional<int>> m_upNextSlotItemIDs;

    void setupUI();
    void setupMenuBar();
    void populateConditionComboBox();
    void checkAndSaveCustomCondition();
    void reloadData();
    void updateStatusLabel(int itemCount, const QString& errorMessage);
    void refreshThumbnails();

    void playSelected(std::optional<int> startPercent = std::nullopt);
    void adjustLike(int amount);
    bool deleteSelectedIfAllowed();
    int getSelectedRow() const;
    void selectRow(int row);

    QStringList savedCustomConditions() const;
    void addCustomCondition(const QString& cond);
};

#endif // MAINWINDOW_H
