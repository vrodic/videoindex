#include "WordCloudDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGuiApplication>
#include <QScreen>
#include <QMouseEvent>
#include <QPainter>
#include <QScrollBar>
#include <cmath>

class ClickableWordLabel : public QLabel {
    Q_OBJECT
public:
    ClickableWordLabel(const QString& text, const QString& word, QWidget* parent = nullptr)
        : QLabel(text, parent), m_word(word)
    {
        setCursor(Qt::PointingHandCursor);
    }

    const QString& word() const { return m_word; }

signals:
    void clickedWord(const QString& word);

protected:
    void mousePressEvent(QMouseEvent* event) override {
        if (event->button() == Qt::LeftButton) {
            emit clickedWord(m_word);
        }
        QLabel::mousePressEvent(event);
    }

private:
    QString m_word;
};

#include "WordCloudDialog.moc"

// MARK: - WordCloudFlowWidget

WordCloudFlowWidget::WordCloudFlowWidget(QWidget* parent)
    : QWidget(parent)
{
}

void WordCloudFlowWidget::setWords(const std::vector<WordFrequency>& words) {
    m_words = words;
    // Clear old child labels
    qDeleteAll(children());
    relayout();
}

QColor WordCloudFlowWidget::colorForRatio(double ratio) const {
    if (ratio > 0.8) return QColor(111, 66, 193);       // Purple
    if (ratio > 0.6) return QColor(220, 53, 69);        // Red
    if (ratio > 0.4) return QColor(255, 140, 0);        // Orange
    if (ratio > 0.25) return QColor(23, 162, 184);      // Teal
    if (ratio > 0.12) return QColor(0, 122, 255);       // Blue
    if (ratio > 0.05) return QColor(40, 167, 69);       // Green
    return QColor(200, 200, 200);                       // Default label color
}

void WordCloudFlowWidget::relayout() {
    if (m_words.empty()) {
        setMinimumHeight(200);
        return;
    }

    int pageMax = m_words.front().count;
    int pageMin = m_words.back().count;

    int paddingX = 12;
    int paddingY = 12;
    int boundsWidth = std::max(width(), 600);

    int currentX = paddingX;
    int currentY = paddingY;
    int rowMaxHeight = 0;

    for (const auto& wf : m_words) {
        double ratio = 0.5;
        double fontSize = 20;
        if (pageMax > pageMin) {
            ratio = static_cast<double>(wf.count - pageMin) / (pageMax - pageMin);
            fontSize = 14.0 + ratio * (44.0 - 14.0);
        }

        QFont font = this->font();
        font.setPointSizeF(fontSize);
        font.setBold(ratio >= 0.5);
        font.setUnderline(true);

        QColor textColor = colorForRatio(ratio);

        auto* label = new ClickableWordLabel(QString("%1 (%2)").arg(wf.word).arg(wf.count), wf.word, this);
        label->setFont(font);

        QPalette pal = label->palette();
        pal.setColor(QPalette::WindowText, textColor);
        label->setPalette(pal);

        connect(label, &ClickableWordLabel::clickedWord, this, &WordCloudFlowWidget::wordSelected);

        label->adjustSize();
        QSize sz = label->size();
        int itemWidth = sz.width() + 12;
        int itemHeight = sz.height() + 8;

        if (currentX + itemWidth + paddingX > boundsWidth && currentX > paddingX) {
            currentX = paddingX;
            currentY += rowMaxHeight + paddingY;
            rowMaxHeight = 0;
        }

        label->setGeometry(currentX, currentY, itemWidth, itemHeight);
        label->show();

        currentX += itemWidth + paddingX;
        rowMaxHeight = std::max(rowMaxHeight, itemHeight);
    }

    int totalHeight = currentY + rowMaxHeight + paddingY;
    setMinimumSize(boundsWidth, std::max(totalHeight, 400));
    resize(boundsWidth, std::max(totalHeight, 400));
}

void WordCloudFlowWidget::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    relayout();
}

// MARK: - WordCloudDialog

WordCloudDialog::WordCloudDialog(
    const std::vector<WordFrequency>& wordFrequencies,
    const std::vector<WordFrequency>& nameFrequencies,
    QWidget* parent
) : QDialog(parent),
    m_wordFrequencies(wordFrequencies),
    m_nameFrequencies(nameFrequencies)
{
    setWindowTitle("Word Cloud Search");
    setMinimumSize(600, 400);

    QScreen* screen = QGuiApplication::primaryScreen();
    if (screen) {
        QRect scrRect = screen->availableGeometry();
        resize(scrRect.width() * 0.9, scrRect.height() * 0.9);
    } else {
        resize(1000, 700);
    }

    m_modeCombo = new QComboBox(this);
    m_modeCombo->addItem("All Words");
    m_modeCombo->addItem("Full Names (first_last)");
    connect(m_modeCombo, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &WordCloudDialog::onModeChanged);

    m_flowWidget = new WordCloudFlowWidget(this);
    connect(m_flowWidget, &WordCloudFlowWidget::wordSelected, this, [this](const QString& word) {
        emit wordSelected(word);
        accept();
    });

    m_scrollArea = new QScrollArea(this);
    m_scrollArea->setWidget(m_flowWidget);
    m_scrollArea->setWidgetResizable(true);

    m_prevBtn = new QPushButton("← Previous", this);
    m_nextBtn = new QPushButton("Next →", this);
    m_pageLabel = new QLabel(this);
    m_pageLabel->setAlignment(Qt::AlignCenter);

    connect(m_prevBtn, &QPushButton::clicked, this, &WordCloudDialog::onPrevPage);
    connect(m_nextBtn, &QPushButton::clicked, this, &WordCloudDialog::onNextPage);

    auto* bottomLayout = new QHBoxLayout();
    bottomLayout->addWidget(m_prevBtn);
    bottomLayout->addWidget(m_pageLabel);
    bottomLayout->addWidget(m_nextBtn);

    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->addWidget(m_modeCombo, 0, Qt::AlignCenter);
    mainLayout->addWidget(m_scrollArea, 1);
    mainLayout->addLayout(bottomLayout);

    setLayout(mainLayout);
    updatePage();
}

const std::vector<WordFrequency>& WordCloudDialog::activeWords() const {
    return (m_modeCombo->currentIndex() == 1) ? m_nameFrequencies : m_wordFrequencies;
}

int WordCloudDialog::totalPages() const {
    const auto& words = activeWords();
    if (words.empty()) return 1;
    return static_cast<int>(std::ceil(static_cast<double>(words.size()) / m_pageSize));
}

void WordCloudDialog::updatePage() {
    const auto& words = activeWords();
    int total = static_cast<int>(words.size());
    int totalP = totalPages();

    if (m_currentPage >= totalP) m_currentPage = std::max(0, totalP - 1);

    int startIdx = m_currentPage * m_pageSize;
    int endIdx = std::min(startIdx + m_pageSize, total);

    std::vector<WordFrequency> pageWords;
    if (startIdx < total) {
        pageWords.assign(words.begin() + startIdx, words.begin() + endIdx);
    }

    m_flowWidget->setWords(pageWords);
    m_scrollArea->verticalScrollBar()->setValue(0);

    m_prevBtn->setEnabled(m_currentPage > 0);
    m_nextBtn->setEnabled(m_currentPage < totalP - 1);

    if (words.empty()) {
        m_pageLabel->setText("No words found");
    } else {
        m_pageLabel->setText(QString("Page %1 of %2 (%3 total)").arg(m_currentPage + 1).arg(totalP).arg(total));
    }
}

void WordCloudDialog::onModeChanged(int index) {
    Q_UNUSED(index);
    m_currentPage = 0;
    updatePage();
}

void WordCloudDialog::onPrevPage() {
    if (m_currentPage > 0) {
        m_currentPage--;
        updatePage();
    }
}

void WordCloudDialog::onNextPage() {
    if (m_currentPage < totalPages() - 1) {
        m_currentPage++;
        updatePage();
    }
}
