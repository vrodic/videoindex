#include "MainWindow.h"
#include "WordCloudDialog.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QScrollArea>
#include <QMenuBar>
#include <QActionGroup>
#include <QProcess>
#include <QDateTime>
#include <QCloseEvent>
#include <QDir>
#include <QFileInfo>
#include <QDebug>
#include <algorithm>

static QString sqliteNowString() {
    return QDateTime::currentDateTimeUtc().toString("yyyy-MM-dd HH:mm:ss");
}

// MARK: - MediaTableModel

MediaTableModel::MediaTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

void MediaTableModel::setItems(const std::vector<MediaItem>& items) {
    beginResetModel();
    m_items = items;
    endResetModel();
}

const MediaItem* MediaTableModel::itemAt(int row) const {
    if (row >= 0 && row < static_cast<int>(m_items.size())) {
        return &m_items[row];
    }
    return nullptr;
}

void MediaTableModel::updateRow(int row) {
    if (row >= 0 && row < static_cast<int>(m_items.size())) {
        emit dataChanged(index(row, 0), index(row, columnCount() - 1));
    }
}

void MediaTableModel::setSessionPlayedIDs(const std::set<int>& ids) {
    m_sessionPlayedIDs = ids;
    if (!m_items.empty()) {
        emit dataChanged(index(0, 0), index(rowCount() - 1, columnCount() - 1));
    }
}

void MediaTableModel::setMissingFileIDs(const std::set<int>& ids) {
    m_missingFileIDs = ids;
    if (!m_items.empty()) {
        emit dataChanged(index(0, 0), index(rowCount() - 1, columnCount() - 1));
    }
}

int MediaTableModel::rowCount(const QModelIndex& parent) const {
    if (parent.isValid()) return 0;
    return static_cast<int>(m_items.size());
}

int MediaTableModel::columnCount(const QModelIndex& parent) const {
    if (parent.isValid()) return 0;
    return 8;
}

QVariant MediaTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid()) return QVariant();
    int row = index.row();
    int col = index.column();
    if (row < 0 || row >= static_cast<int>(m_items.size())) return QVariant();

    const MediaItem& item = m_items[row];

    if (role == IsSessionPlayedRole) {
        return m_sessionPlayedIDs.count(item.id) > 0;
    }
    if (role == IsViewedRole) {
        return (item.viewCount.value_or(0) > 0) || (!item.viewedTime.isEmpty());
    }
    if (role == IsMissingFileRole) {
        return m_missingFileIDs.count(item.id) > 0;
    }
    if (role == LikeValueRole) {
        return item.like.has_value() ? QVariant(item.like.value()) : QVariant();
    }

    if (role == Qt::DisplayRole) {
        switch (col) {
        case 0: return item.id;
        case 1: return item.filename;
        case 2: return item.viewCount.has_value() ? QVariant(item.viewCount.value()) : QVariant("");
        case 3: return item.like.has_value() ? QVariant(item.like.value()) : QVariant("");
        case 4: return item.fileSizeMB;
        case 5: return item.viewedTime;
        case 6: return item.width.has_value() ? QVariant(item.width.value()) : QVariant("");
        case 7: return item.density.has_value() ? QVariant(item.density.value()) : QVariant("");
        default: return QVariant();
        }
    }

    return QVariant();
}

QVariant MediaTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation == Qt::Horizontal && role == Qt::DisplayRole) {
        switch (section) {
        case 0: return "ID";
        case 1: return "Filename";
        case 2: return "Views";
        case 3: return "Likes";
        case 4: return "Size (MB)";
        case 5: return "Last Viewed";
        case 6: return "Width";
        case 7: return "Density";
        default: return QVariant();
        }
    }
    return QAbstractTableModel::headerData(section, orientation, role);
}

void MediaTableModel::sort(int column, Qt::SortOrder order) {
    beginResetModel();
    bool asc = (order == Qt::AscendingOrder);

    auto isLessOpt = [](const auto& a, const auto& b) {
        if (!a.has_value() && !b.has_value()) return false;
        if (!a.has_value()) return true;
        if (!b.has_value()) return false;
        return a.value() < b.value();
    };

    std::sort(m_items.begin(), m_items.end(), [column, asc, isLessOpt](const MediaItem& a, const MediaItem& b) {
        bool result = false;
        switch (column) {
        case 0: result = a.id < b.id; break;
        case 1: result = QString::compare(a.filename, b.filename, Qt::CaseInsensitive) < 0; break;
        case 2: result = isLessOpt(a.viewCount, b.viewCount); break;
        case 3: result = isLessOpt(a.like, b.like); break;
        case 4: result = a.fileSizeMB < b.fileSizeMB; break;
        case 5: result = a.viewedTime < b.viewedTime; break;
        case 6: result = isLessOpt(a.width, b.width); break;
        case 7: result = isLessOpt(a.density, b.density); break;
        default: break;
        }
        return asc ? result : !result;
    });
    endResetModel();
}

// MARK: - MainWindow

MainWindow::MainWindow(const QString& rootDir, const QString& indexFile, QWidget* parent)
    : QMainWindow(parent),
      m_rootDir(rootDir),
      m_indexFile(indexFile),
      m_db(indexFile)
{
    setWindowTitle("videoindex");
    resize(1550, 1000);

    m_defaultConditions << "AND like > 2 ORDER BY viewed_time, random() -- (Default: Highly liked, oldest viewed first)"
                        << "ORDER BY view_count ASC, file_size DESC -- (Least viewed first)"
                        << "ORDER BY view_count DESC -- (Most viewed)"
                        << "ORDER BY file_size DESC -- (Largest files)"
                        << "ORDER BY viewed_time DESC -- (Recently viewed)"
                        << "ORDER BY id DESC -- (Recently added)"
                        << "AND (like IS NULL OR like >= 0) ORDER BY random() -- (Unrated & liked, shuffled)"
                        << "AND like > 0 ORDER BY like DESC -- (Liked videos)";

    m_conditionExpression = m_defaultConditions[0];

    m_thumbManager = new ThumbnailManager(m_rootDir, this);

    QSettings settings("VideoIndex", "VideoIndex");
    m_thumbManager->setSaveThumbnailsToDisk(settings.value("SaveThumbnailsToDisk", true).toBool());

    setupUI();
    setupMenuBar();

    connect(m_thumbManager, &ThumbnailManager::filmstripThumbnailReady, this, &MainWindow::onFilmstripReady);
    connect(m_thumbManager, &ThumbnailManager::upNextThumbnailReady, this, &MainWindow::onUpNextReady);
    connect(m_thumbManager, &ThumbnailManager::fileMissing, this, &MainWindow::onFileMissing);

    populateConditionComboBox();

    // Restore geometry and splitter state
    if (settings.contains("geometry")) {
        restoreGeometry(settings.value("geometry").toByteArray());
    }
    if (settings.contains("windowState")) {
        restoreState(settings.value("windowState").toByteArray());
    }
    if (settings.contains("mainSplitter")) {
        m_mainSplitter->restoreState(settings.value("mainSplitter").toByteArray());
    }
    if (settings.contains("tableHeaderState")) {
        m_tableView->horizontalHeader()->restoreState(settings.value("tableHeaderState").toByteArray());
    }

    reloadData();
    m_tableView->setFocus();
}

MainWindow::~MainWindow() {
}

void MainWindow::closeEvent(QCloseEvent* event) {
    QSettings settings("VideoIndex", "VideoIndex");
    settings.setValue("geometry", saveGeometry());
    settings.setValue("windowState", saveState());
    settings.setValue("mainSplitter", m_mainSplitter->saveState());
    settings.setValue("tableHeaderState", m_tableView->horizontalHeader()->saveState());
    settings.setValue("SaveThumbnailsToDisk", m_thumbManager->saveThumbnailsToDisk());

    m_db.commit();
    QMainWindow::closeEvent(event);
}

void MainWindow::setupUI() {
    auto* centralWidget = new QWidget(this);
    setCentralWidget(centralWidget);

    m_searchField = new QLineEdit(this);
    m_searchField->setPlaceholderText("Search filename…");
    connect(m_searchField, &QLineEdit::textChanged, this, &MainWindow::onSearchTextChanged);

    m_wordCloudButton = new QPushButton("Word Cloud", this);
    connect(m_wordCloudButton, &QPushButton::clicked, this, &MainWindow::openWordCloud);

    auto* topLayout = new QHBoxLayout();
    topLayout->addWidget(m_searchField, 1);
    topLayout->addWidget(m_wordCloudButton, 0);

    // Table View setup
    m_tableView = new ShortcutTableView(this);
    m_tableModel = new MediaTableModel(this);
    m_itemDelegate = new CustomItemDelegate(this);

    m_tableView->setModel(m_tableModel);
    m_tableView->setItemDelegate(m_itemDelegate);
    m_tableView->horizontalHeader()->setStretchLastSection(false);
    m_tableView->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);

    connect(m_tableView->selectionModel(), &QItemSelectionModel::selectionChanged, this, &MainWindow::onTableSelectionChanged);
    connect(m_tableView, &ShortcutTableView::playRequested, this, &MainWindow::playSelectedMedia);
    connect(m_tableView, &ShortcutTableView::likeIncrementRequested, this, &MainWindow::likeSelectedMedia);
    connect(m_tableView, &ShortcutTableView::deleteOrDislikeRequested, this, &MainWindow::deleteOrDislikeSelectedMedia);
    connect(m_tableView, &ShortcutTableView::homeRequested, this, &MainWindow::selectFirstItem);
    connect(m_tableView, &ShortcutTableView::endRequested, this, &MainWindow::selectLastItem);
    connect(m_tableView, &ShortcutTableView::escapeRequested, this, [this]() {
        m_db.commit();
        close();
    });

    // Right Preview Split Pane
    m_previewTitleLabel = new QLabel(this);
    QFont titleFont = m_previewTitleLabel->font();
    titleFont.setBold(true);
    titleFont.setPointSizeF(11);
    m_previewTitleLabel->setFont(titleFont);
    m_previewTitleLabel->setWordWrap(true);

    // Filmstrip column layout
    auto* filmstripLayout = new QVBoxLayout();
    filmstripLayout->addWidget(m_previewTitleLabel);

    static const int filmstripPercents[] = {15, 30, 45, 60, 75, 90};
    for (int p : filmstripPercents) {
        auto* thumbLabel = new ClickableThumbnailLabel(this);
        thumbLabel->setMinimumSize(160, 90);
        connect(thumbLabel, &ClickableThumbnailLabel::clicked, this, [this, p]() {
            playSelected(p);
        });

        auto* captionLabel = new QLabel(QString("%1%").arg(p), this);
        QFont captionFont = captionLabel->font();
        captionFont.setPointSizeF(9);
        captionLabel->setFont(captionFont);
        captionLabel->setAlignment(Qt::AlignLeft);

        filmstripLayout->addWidget(thumbLabel);
        filmstripLayout->addWidget(captionLabel);
        m_previewLabels[p] = thumbLabel;
    }
    filmstripLayout->addStretch(1);

    auto* filmstripWidget = new QWidget(this);
    filmstripWidget->setLayout(filmstripLayout);

    auto* filmstripScroll = new QScrollArea(this);
    filmstripScroll->setWidget(filmstripWidget);
    filmstripScroll->setWidgetResizable(true);

    // Up Next column layout
    auto* upNextHeader = new QLabel("Up Next", this);
    upNextHeader->setFont(titleFont);

    auto* upNextLayout = new QVBoxLayout();
    upNextLayout->addWidget(upNextHeader);

    m_upNextSlotItemIDs.resize(10, std::nullopt);
    for (int i = 0; i < 10; ++i) {
        auto* thumbLabel = new ClickableThumbnailLabel(this);
        thumbLabel->setMinimumSize(160, 90);
        if (i == 0) thumbLabel->setBorderHighlighted(true);

        connect(thumbLabel, &ClickableThumbnailLabel::clicked, this, [this, i]() {
            if (i < static_cast<int>(m_upNextSlotItemIDs.size()) && m_upNextSlotItemIDs[i].has_value()) {
                int itemID = m_upNextSlotItemIDs[i].value();
                const auto& items = m_tableModel->items();
                for (size_t r = 0; r < items.size(); ++r) {
                    if (items[r].id == itemID) {
                        selectRow(static_cast<int>(r));
                        break;
                    }
                }
            }
        });

        upNextLayout->addWidget(thumbLabel);
        m_upNextLabels.push_back(thumbLabel);
    }
    upNextLayout->addStretch(1);

    auto* upNextWidget = new QWidget(this);
    upNextWidget->setLayout(upNextLayout);

    auto* upNextScroll = new QScrollArea(this);
    upNextScroll->setWidget(upNextWidget);
    upNextScroll->setWidgetResizable(true);

    auto* rightPaneLayout = new QHBoxLayout();
    rightPaneLayout->setContentsMargins(4, 4, 4, 4);
    rightPaneLayout->addWidget(filmstripScroll, 1);
    rightPaneLayout->addWidget(upNextScroll, 1);

    auto* rightPaneWidget = new QWidget(this);
    rightPaneWidget->setLayout(rightPaneLayout);

    m_mainSplitter = new QSplitter(Qt::Horizontal, this);
    m_mainSplitter->addWidget(m_tableView);
    m_mainSplitter->addWidget(rightPaneWidget);
    m_mainSplitter->setStretchFactor(0, 3);
    m_mainSplitter->setStretchFactor(1, 1);

    // Bottom Condition & Status Area
    m_conditionField = new QComboBox(this);
    m_conditionField->setEditable(true);
    m_conditionField->setInsertPolicy(QComboBox::NoInsert);

    connect(m_conditionField->lineEdit(), &QLineEdit::textChanged, this, &MainWindow::onConditionTextChanged);
    connect(m_conditionField, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &MainWindow::onConditionComboIndexChanged);

    m_statusLabel = new QLabel(this);
    QFont statusFont = m_statusLabel->font();
    statusFont.setPointSizeF(9);
    m_statusLabel->setFont(statusFont);

    auto* mainLayout = new QVBoxLayout(centralWidget);
    mainLayout->addLayout(topLayout);
    mainLayout->addWidget(m_mainSplitter, 1);
    mainLayout->addWidget(m_conditionField);
    mainLayout->addWidget(m_statusLabel);

    centralWidget->setLayout(mainLayout);
}

void MainWindow::setupMenuBar() {
    QMenuBar* mb = menuBar();

    // File Menu
    QMenu* fileMenu = mb->addMenu("&File");

    QAction* reloadAct = fileMenu->addAction("&Reload");
    reloadAct->setShortcut(QKeySequence("Ctrl+R"));
    connect(reloadAct, &QAction::triggered, this, &MainWindow::reloadQuery);

    QAction* playAct = fileMenu->addAction("&Play Selected");
    playAct->setShortcut(QKeySequence("Return"));
    connect(playAct, &QAction::triggered, this, &MainWindow::playSelectedMedia);

    fileMenu->addSeparator();

    QAction* closeAct = fileMenu->addAction("&Close Window");
    closeAct->setShortcut(QKeySequence("Ctrl+W"));
    connect(closeAct, &QAction::triggered, this, &QWidget::close);

    // Edit Menu
    QMenu* editMenu = mb->addMenu("&Edit");

    QAction* findAct = editMenu->addAction("&Find...");
    findAct->setShortcut(QKeySequence("Ctrl+F"));
    connect(findAct, &QAction::triggered, this, &MainWindow::focusSearchField);

    QAction* wordCloudAct = editMenu->addAction("&Word Cloud Search...");
    wordCloudAct->setShortcut(QKeySequence("Ctrl+K"));
    connect(wordCloudAct, &QAction::triggered, this, &MainWindow::openWordCloud);

    QAction* conditionAct = editMenu->addAction("&Edit Condition...");
    conditionAct->setShortcut(QKeySequence("Ctrl+L"));
    connect(conditionAct, &QAction::triggered, this, &MainWindow::focusConditionField);

    // Controls Menu
    QMenu* controlsMenu = mb->addMenu("&Controls");

    QAction* likeAct = controlsMenu->addAction("&Like (+1)");
    likeAct->setShortcut(QKeySequence("+"));
    connect(likeAct, &QAction::triggered, this, &MainWindow::likeSelectedMedia);

    QAction* dislikeAct = controlsMenu->addAction("&Dislike / Delete");
    dislikeAct->setShortcut(QKeySequence("Delete"));
    connect(dislikeAct, &QAction::triggered, this, &MainWindow::deleteOrDislikeSelectedMedia);

    controlsMenu->addSeparator();

    QAction* firstAct = controlsMenu->addAction("&First Item");
    connect(firstAct, &QAction::triggered, this, &MainWindow::selectFirstItem);

    QAction* lastAct = controlsMenu->addAction("&Last Item");
    connect(lastAct, &QAction::triggered, this, &MainWindow::selectLastItem);

    // Options Menu
    QMenu* optionsMenu = mb->addMenu("&Options");

    QAction* saveThumbsAct = optionsMenu->addAction("Save Thumbnails to Disk");
    saveThumbsAct->setCheckable(true);
    saveThumbsAct->setChecked(m_thumbManager->saveThumbnailsToDisk());
    connect(saveThumbsAct, &QAction::triggered, this, &MainWindow::toggleSaveThumbnailsToDisk);

    // MPV Menu
    QMenu* mpvMenu = mb->addMenu("&MPV");

    QAction* volMaxAct = mpvMenu->addAction("Max Volume 1000 (--volume-max=1000)");
    volMaxAct->setCheckable(true);
    volMaxAct->setChecked(m_mpvVolumeMax1000);
    connect(volMaxAct, &QAction::triggered, this, [this, volMaxAct]() { m_mpvVolumeMax1000 = volMaxAct->isChecked(); });

    QMenu* volSubmenu = mpvMenu->addMenu("Default Volume");
    auto* volGroup = new QActionGroup(this);
    QStringList vols = {"10", "25", "33", "50", "75", "100"};
    for (const QString& v : vols) {
        QAction* act = volSubmenu->addAction(QString("%1%% %2").arg(v, v == "33" ? "(Default)" : ""));
        act->setCheckable(true);
        if (v == m_mpvVolume) act->setChecked(true);
        volGroup->addAction(act);
        connect(act, &QAction::triggered, this, [this, v]() { m_mpvVolume = v; });
    }

    mpvMenu->addSeparator();

    QAction* muteAct = mpvMenu->addAction("Mute (--mute=yes)");
    muteAct->setCheckable(true);
    connect(muteAct, &QAction::triggered, this, [this, muteAct]() { m_mpvMute = muteAct->isChecked(); });

    QAction* loopAct = mpvMenu->addAction("Loop Video (--loop-file=inf)");
    loopAct->setCheckable(true);
    connect(loopAct, &QAction::triggered, this, [this, loopAct]() { m_mpvLoop = loopAct->isChecked(); });

    QAction* noAudioAct = mpvMenu->addAction("No Audio (--no-audio)");
    noAudioAct->setCheckable(true);
    connect(noAudioAct, &QAction::triggered, this, [this, noAudioAct]() { m_mpvNoAudio = noAudioAct->isChecked(); });

    QAction* keepOpenAct = mpvMenu->addAction("Keep Open After Playback (--keep-open=yes)");
    keepOpenAct->setCheckable(true);
    connect(keepOpenAct, &QAction::triggered, this, [this, keepOpenAct]() { m_mpvKeepOpen = keepOpenAct->isChecked(); });

    QAction* ontopAct = mpvMenu->addAction("Always On Top (--ontop)");
    ontopAct->setCheckable(true);
    connect(ontopAct, &QAction::triggered, this, [this, ontopAct]() { m_mpvOntop = ontopAct->isChecked(); });

    QAction* hwdecAct = mpvMenu->addAction("Hardware Decoding (--hwdec=auto)");
    hwdecAct->setCheckable(true);
    connect(hwdecAct, &QAction::triggered, this, [this, hwdecAct]() { m_mpvHwdec = hwdecAct->isChecked(); });

    mpvMenu->addSeparator();

    QMenu* autofitSubmenu = mpvMenu->addMenu("Autofit Window Size");
    auto* autofitGroup = new QActionGroup(this);
    struct AutofitOpt { QString label; QString val; };
    AutofitOpt autofits[] = {
        {"50%", "50%x50%"},
        {"75% (Default)", "75%x75%"},
        {"100%", "100%x100%"},
        {"Fullscreen", "fullscreen"}
    };
    for (const auto& opt : autofits) {
        QAction* act = autofitSubmenu->addAction(opt.label);
        act->setCheckable(true);
        if (opt.val == m_mpvAutofitSize) act->setChecked(true);
        autofitGroup->addAction(act);
        connect(act, &QAction::triggered, this, [this, val = opt.val]() { m_mpvAutofitSize = val; });
    }

    QMenu* speedSubmenu = mpvMenu->addMenu("Playback Speed");
    auto* speedGroup = new QActionGroup(this);
    struct SpeedOpt { QString label; QString val; };
    SpeedOpt speeds[] = {
        {"1.0x (Normal)", "1.0"},
        {"1.25x", "1.25"},
        {"1.5x", "1.5"},
        {"2.0x", "2.0"}
    };
    for (const auto& opt : speeds) {
        QAction* act = speedSubmenu->addAction(opt.label);
        act->setCheckable(true);
        if (opt.val == m_mpvSpeed) act->setChecked(true);
        speedGroup->addAction(act);
        connect(act, &QAction::triggered, this, [this, val = opt.val]() { m_mpvSpeed = val; });
    }
}

QStringList MainWindow::savedCustomConditions() const {
    QSettings settings("VideoIndex", "VideoIndex");
    return settings.value("CustomConditions").toStringList();
}

void MainWindow::addCustomCondition(const QString& cond) {
    QString trimmed = cond.trimmed();
    if (trimmed.isEmpty()) return;
    QStringList custom = savedCustomConditions();
    if (!m_defaultConditions.contains(trimmed) && !custom.contains(trimmed)) {
        custom.append(trimmed);
        QSettings settings("VideoIndex", "VideoIndex");
        settings.setValue("CustomConditions", custom);
        populateConditionComboBox();
        m_conditionField->setEditText(trimmed);
    }
}

void MainWindow::populateConditionComboBox() {
    m_conditionField->blockSignals(true);
    m_conditionField->clear();
    m_conditionField->addItems(m_defaultConditions);
    m_conditionField->addItems(savedCustomConditions());
    m_conditionField->setEditText(m_conditionExpression);
    m_conditionField->blockSignals(false);
}

void MainWindow::checkAndSaveCustomCondition() {
    if (m_lastQuerySucceeded && !m_hasAddedCurrentConditionToHistory) {
        addCustomCondition(m_conditionExpression);
        m_hasAddedCurrentConditionToHistory = true;
    }
}

void MainWindow::reloadData() {
    LoadResult res = m_db.loadItems(m_searchTerm, m_conditionExpression);
    m_items = res.items;
    m_lastQuerySucceeded = res.errorMessage.isEmpty();

    m_tableModel->setItems(m_items);
    m_tableModel->setSessionPlayedIDs(m_sessionPlayedIDs);
    m_tableModel->setMissingFileIDs(m_missingFileIDs);

    updateStatusLabel(static_cast<int>(m_items.size()), res.errorMessage);

    if (m_items.size() > 0 && getSelectedRow() < 0) {
        selectRow(0);
    } else {
        refreshThumbnails();
    }
}

void MainWindow::updateStatusLabel(int itemCount, const QString& errorMessage) {
    if (!errorMessage.isEmpty()) {
        m_statusLabel->setStyleSheet("color: #dc3545;");
        m_statusLabel->setText(QString("Query error: %1").arg(errorMessage));
    } else {
        m_statusLabel->setStyleSheet("color: #aaa;");
        m_statusLabel->setText(itemCount == 1 ? "1 item" : QString("%1 items").arg(itemCount));
    }
}

int MainWindow::getSelectedRow() const {
    QModelIndexList selected = m_tableView->selectionModel()->selectedRows();
    if (selected.isEmpty()) return -1;
    return selected.first().row();
}

void MainWindow::selectRow(int row) {
    if (row >= 0 && row < m_tableModel->rowCount()) {
        m_tableView->selectRow(row);
        m_tableView->scrollTo(m_tableModel->index(row, 0));
    }
}

void MainWindow::onSearchTextChanged(const QString& text) {
    m_searchTerm = text;
    reloadData();
}

void MainWindow::onConditionTextChanged(const QString& text) {
    m_conditionExpression = text;
    m_hasAddedCurrentConditionToHistory = false;
    reloadData();
}

void MainWindow::onConditionComboIndexChanged(int index) {
    if (index >= 0) {
        m_conditionExpression = m_conditionField->itemText(index);
        m_hasAddedCurrentConditionToHistory = true;
        reloadData();
    }
}

void MainWindow::onTableSelectionChanged() {
    checkAndSaveCustomCondition();
    refreshThumbnails();
}

void MainWindow::onHeaderClicked(int logicalIndex) {
    Q_UNUSED(logicalIndex);
    refreshThumbnails();
}

void MainWindow::refreshThumbnails() {
    int row = getSelectedRow();
    const MediaItem* selItem = m_tableModel->itemAt(row);

    if (!selItem) {
        m_previewTitleLabel->clear();
        for (auto& pair : m_previewLabels) {
            pair.second->clearThumbnail();
        }
        for (auto* label : m_upNextLabels) {
            label->clearThumbnail();
        }
        std::fill(m_upNextSlotItemIDs.begin(), m_upNextSlotItemIDs.end(), std::nullopt);
        return;
    }

    m_previewTitleLabel->setText(selItem->filename);

    static const int filmstripPercents[] = {15, 30, 45, 60, 75, 90};
    for (int p : filmstripPercents) {
        QPixmap cached = m_thumbManager->getCachedThumbnail(selItem->id, p);
        if (!cached.isNull()) {
            m_previewLabels[p]->setThumbnailPixmap(cached);
        } else {
            m_previewLabels[p]->clearThumbnail();
        }
    }

    const auto& items = m_tableModel->items();
    std::vector<MediaItem> upNextItems;
    for (int slot = 0; slot < 10; ++slot) {
        int idx = row + slot;
        if (idx < static_cast<int>(items.size())) {
            upNextItems.push_back(items[idx]);
            m_upNextSlotItemIDs[slot] = items[idx].id;
            m_upNextLabels[slot]->setToolTip(items[idx].filename);

            QPixmap cached = m_thumbManager->getCachedThumbnail(items[idx].id, 45);
            if (!cached.isNull()) {
                m_upNextLabels[slot]->setThumbnailPixmap(cached);
            } else {
                m_upNextLabels[slot]->clearThumbnail();
            }
        } else {
            m_upNextSlotItemIDs[slot] = std::nullopt;
            m_upNextLabels[slot]->clearThumbnail();
            m_upNextLabels[slot]->setToolTip("");
        }
    }

    std::optional<MediaItem> nextItem;
    if (row + 1 < static_cast<int>(items.size())) {
        nextItem = items[row + 1];
    }

    m_thumbManager->requestThumbnails(*selItem, upNextItems, nextItem);
}

void MainWindow::onFilmstripReady(int itemId, int percent, QPixmap pixmap) {
    int row = getSelectedRow();
    const MediaItem* selItem = m_tableModel->itemAt(row);
    if (selItem && selItem->id == itemId) {
        if (m_previewLabels.count(percent)) {
            m_previewLabels[percent]->setThumbnailPixmap(pixmap);
        }
    }
}

void MainWindow::onUpNextReady(int slot, int itemId, QPixmap pixmap) {
    if (slot >= 0 && slot < static_cast<int>(m_upNextSlotItemIDs.size())) {
        if (m_upNextSlotItemIDs[slot].has_value() && m_upNextSlotItemIDs[slot].value() == itemId) {
            m_upNextLabels[slot]->setThumbnailPixmap(pixmap);
        }
    }
}

void MainWindow::onFileMissing(int itemId) {
    if (!m_missingFileIDs.count(itemId)) {
        m_missingFileIDs.insert(itemId);
        m_tableModel->setMissingFileIDs(m_missingFileIDs);
    }
}

void MainWindow::playSelected(std::optional<int> startPercent) {
    int row = getSelectedRow();
    const MediaItem* itemPtr = m_tableModel->itemAt(row);
    if (!itemPtr) return;

    MediaItem item = *itemPtr;
    QString fullPath = item.fullPath(m_rootDir);

    QStringList args;
    if (startPercent.has_value()) {
        args << QString("--start=%1%").arg(startPercent.value());
    }
    if (m_mpvVolumeMax1000) {
        args << "--volume-max=1000";
    }
    args << QString("--volume=%1").arg(m_mpvVolume);
    if (m_mpvMute) args << "--mute=yes";
    if (m_mpvLoop) args << "--loop-file=inf";
    if (m_mpvNoAudio) args << "--no-audio";
    if (m_mpvKeepOpen) args << "--keep-open=yes";
    if (m_mpvOntop) args << "--ontop";
    if (m_mpvHwdec) args << "--hwdec=auto";

    if (m_mpvAutofitSize == "fullscreen") {
        args << "--fullscreen";
    } else {
        args << QString("--autofit=%1").arg(m_mpvAutofitSize);
    }

    if (m_mpvSpeed != "1.0") {
        args << QString("--speed=%1").arg(m_mpvSpeed);
    }

    args << fullPath;

    QProcess::startDetached("mpv", args);

    m_sessionPlayedIDs.insert(item.id);
    m_tableModel->setSessionPlayedIDs(m_sessionPlayedIDs);

    int newCount = item.viewCount.value_or(0) + 1;
    item.viewCount = newCount;
    item.viewedTime = sqliteNowString();

    m_db.updateViewCount(item.id, newCount);

    // Update item in list
    auto& itemsRef = const_cast<std::vector<MediaItem>&>(m_tableModel->items());
    if (row < static_cast<int>(itemsRef.size())) {
        itemsRef[row] = item;
        m_tableModel->updateRow(row);
    }
}

void MainWindow::adjustLike(int amount) {
    int row = getSelectedRow();
    const MediaItem* itemPtr = m_tableModel->itemAt(row);
    if (!itemPtr) return;

    MediaItem item = *itemPtr;
    int currentLike = item.like.value_or(0);
    int newLike = item.like.has_value() ? currentLike + amount : amount;

    item.like = newLike;
    m_db.updateLike(item.id, newLike);

    auto& itemsRef = const_cast<std::vector<MediaItem>&>(m_tableModel->items());
    if (row < static_cast<int>(itemsRef.size())) {
        itemsRef[row] = item;
        m_tableModel->updateRow(row);
    }
}

bool MainWindow::deleteSelectedIfAllowed() {
    int row = getSelectedRow();
    const MediaItem* itemPtr = m_tableModel->itemAt(row);
    if (!itemPtr) return false;

    if (itemPtr->like.has_value() && itemPtr->like.value() >= -1) {
        qDebug() << "can't delete liked item";
        return false;
    }

    QString fullPath = itemPtr->fullPath(m_rootDir);
    QFile::remove(fullPath);

    int id = itemPtr->id;
    m_db.deleteMedia(id);

    reloadData();
    selectRow(std::min(row, m_tableModel->rowCount() - 1));
    return true;
}

// Menu Slots
void MainWindow::openWordCloud() {
    auto wordFreqs = m_db.fetchWordFrequencies();
    auto nameFreqs = m_db.fetchNameFrequencies();

    WordCloudDialog dlg(wordFreqs, nameFreqs, this);
    connect(&dlg, &WordCloudDialog::wordSelected, this, [this](const QString& word) {
        m_searchField->setText(word);
        m_searchTerm = word;
        reloadData();
    });
    dlg.exec();
}

void MainWindow::reloadQuery() {
    m_tableView->sortByColumn(-1, Qt::AscendingOrder);
    reloadData();
}

void MainWindow::focusSearchField() {
    m_searchField->setFocus();
    m_searchField->selectAll();
}

void MainWindow::focusConditionField() {
    m_conditionField->setFocus();
    m_conditionField->lineEdit()->selectAll();
}

void MainWindow::playSelectedMedia() {
    playSelected();
}

void MainWindow::likeSelectedMedia() {
    adjustLike(1);
    selectRow(getSelectedRow() + 1);
}

void MainWindow::deleteOrDislikeSelectedMedia() {
    adjustLike(-1);
    if (!deleteSelectedIfAllowed()) {
        selectRow(getSelectedRow() + 1);
    }
}

void MainWindow::selectFirstItem() {
    if (m_tableModel->rowCount() > 0) {
        selectRow(0);
    }
}

void MainWindow::selectLastItem() {
    int count = m_tableModel->rowCount();
    if (count > 0) {
        selectRow(count - 1);
    }
}

void MainWindow::toggleSaveThumbnailsToDisk() {
    bool current = m_thumbManager->saveThumbnailsToDisk();
    m_thumbManager->setSaveThumbnailsToDisk(!current);
}
