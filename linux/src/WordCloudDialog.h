#ifndef WORDCLOUDDIALOG_H
#define WORDCLOUDDIALOG_H

#include <QDialog>
#include <QPushButton>
#include <QLabel>
#include <QComboBox>
#include <QScrollArea>
#include <vector>
#include "Database.h"

class WordCloudFlowWidget : public QWidget {
    Q_OBJECT
public:
    explicit WordCloudFlowWidget(QWidget* parent = nullptr);

    void setWords(const std::vector<WordFrequency>& words);

signals:
    void wordSelected(const QString& word);

protected:
    void resizeEvent(QResizeEvent* event) override;

private:
    std::vector<WordFrequency> m_words;
    void relayout();
    QColor colorForRatio(double ratio) const;
};

class WordCloudDialog : public QDialog {
    Q_OBJECT
public:
    WordCloudDialog(
        const std::vector<WordFrequency>& wordFrequencies,
        const std::vector<WordFrequency>& nameFrequencies,
        QWidget* parent = nullptr
    );

signals:
    void wordSelected(const QString& word);

private slots:
    void onModeChanged(int index);
    void onPrevPage();
    void onNextPage();

private:
    std::vector<WordFrequency> m_wordFrequencies;
    std::vector<WordFrequency> m_nameFrequencies;

    int m_currentPage = 0;
    const int m_pageSize = 200;

    QComboBox* m_modeCombo = nullptr;
    QScrollArea* m_scrollArea = nullptr;
    WordCloudFlowWidget* m_flowWidget = nullptr;
    QPushButton* m_prevBtn = nullptr;
    QPushButton* m_nextBtn = nullptr;
    QLabel* m_pageLabel = nullptr;

    const std::vector<WordFrequency>& activeWords() const;
    int totalPages() const;
    void updatePage();
};

#endif // WORDCLOUDDIALOG_H
