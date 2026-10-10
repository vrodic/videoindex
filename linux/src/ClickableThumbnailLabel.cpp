#include "ClickableThumbnailLabel.h"
#include <QStyle>

ClickableThumbnailLabel::ClickableThumbnailLabel(QWidget* parent)
    : QLabel(parent)
{
    setCursor(Qt::PointingHandCursor);
    setScaledContents(false);
    setAlignment(Qt::AlignCenter);
    setStyleSheet("border: 1px solid #444; background-color: #222; border-radius: 4px;");
}

void ClickableThumbnailLabel::setBorderHighlighted(bool highlight) {
    m_highlighted = highlight;
    if (m_highlighted) {
        setStyleSheet("border: 2px solid #007acc; background-color: #222; border-radius: 4px;");
    } else {
        setStyleSheet("border: 1px solid #444; background-color: #222; border-radius: 4px;");
    }
}

void ClickableThumbnailLabel::setThumbnailPixmap(const QPixmap& pixmap) {
    m_originalPixmap = pixmap;
    updatePixmapDisplay();
}

void ClickableThumbnailLabel::clearThumbnail() {
    m_originalPixmap = QPixmap();
    clear();
}

void ClickableThumbnailLabel::updatePixmapDisplay() {
    if (m_originalPixmap.isNull()) {
        clear();
        return;
    }
    QSize labelSize = size();
    if (labelSize.width() <= 0 || labelSize.height() <= 0) return;
    QPixmap scaled = m_originalPixmap.scaled(labelSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    setPixmap(scaled);
}

void ClickableThumbnailLabel::resizeEvent(QResizeEvent* event) {
    QLabel::resizeEvent(event);
    updatePixmapDisplay();
}

void ClickableThumbnailLabel::mousePressEvent(QMouseEvent* event) {
    if (event->button() == Qt::LeftButton) {
        emit clicked();
    }
    QLabel::mousePressEvent(event);
}
