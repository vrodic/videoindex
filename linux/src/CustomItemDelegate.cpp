#include "CustomItemDelegate.h"
#include <QPainter>

CustomItemDelegate::CustomItemDelegate(QObject* parent)
    : QStyledItemDelegate(parent)
{
}

void CustomItemDelegate::paint(QPainter* painter, const QStyleOptionViewItem& option, const QModelIndex& index) const {
    QStyleOptionViewItem opt = option;
    initStyleOption(&opt, index);

    bool isSessionPlayed = index.data(IsSessionPlayedRole).toBool();
    bool isViewed = index.data(IsViewedRole).toBool();
    bool isMissing = index.data(IsMissingFileRole).toBool();

    // Background tinting
    if (!(opt.state & QStyle::State_Selected)) {
        if (isSessionPlayed) {
            // Distinct green tint
            painter->fillRect(opt.rect, QColor(40, 167, 69, 45));
        } else if (isViewed) {
            // Subtle blue tint
            painter->fillRect(opt.rect, QColor(0, 122, 255, 30));
        }
    }

    // Foreground text color
    if (isMissing) {
        opt.palette.setColor(QPalette::Text, QColor(220, 53, 69)); // Dark red
        opt.palette.setColor(QPalette::HighlightedText, QColor(255, 128, 128));
    } else if (index.column() == 3) { // Likes column
        QVariant likeVar = index.data(LikeValueRole);
        if (likeVar.isValid() && !likeVar.isNull()) {
            int like = likeVar.toInt();
            QColor c;
            if (like < 0) {
                c = QColor(220, 53, 69); // Red
            } else if (like == 1) {
                c = QColor(255, 140, 0); // Orange
            } else if (like == 2) {
                c = QColor(204, 163, 0); // Yellow
            } else if (like == 3) {
                c = QColor(40, 167, 69); // Green
            } else if (like == 4) {
                c = QColor(23, 162, 184); // Teal
            } else if (like >= 5) {
                c = QColor(111, 66, 193); // Purple
            } else {
                c = opt.palette.color(QPalette::Text);
            }
            opt.palette.setColor(QPalette::Text, c);
        }
    }

    QStyledItemDelegate::paint(painter, opt, index);
}
