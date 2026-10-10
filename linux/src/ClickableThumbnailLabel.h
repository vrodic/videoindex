#ifndef CLICKABLETHUMBNAILLABEL_H
#define CLICKABLETHUMBNAILLABEL_H

#include <QLabel>
#include <QMouseEvent>

class ClickableThumbnailLabel : public QLabel {
    Q_OBJECT
public:
    explicit ClickableThumbnailLabel(QWidget* parent = nullptr);

    void setBorderHighlighted(bool highlight);
    void setThumbnailPixmap(const QPixmap& pixmap);
    void clearThumbnail();

signals:
    void clicked();

protected:
    void mousePressEvent(QMouseEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    QPixmap m_originalPixmap;
    bool m_highlighted = false;

    void updatePixmapDisplay();
};

#endif // CLICKABLETHUMBNAILLABEL_H
