#ifndef CUSTOMITEMDELEGATE_H
#define CUSTOMITEMDELEGATE_H

#include <QStyledItemDelegate>
#include <set>

enum CustomDataRoles {
    IsSessionPlayedRole = Qt::UserRole + 1,
    IsViewedRole,
    IsMissingFileRole,
    LikeValueRole
};

class CustomItemDelegate : public QStyledItemDelegate {
    Q_OBJECT
public:
    explicit CustomItemDelegate(QObject* parent = nullptr);

    void paint(QPainter* painter, const QStyleOptionViewItem& option, const QModelIndex& index) const override;
};

#endif // CUSTOMITEMDELEGATE_H
