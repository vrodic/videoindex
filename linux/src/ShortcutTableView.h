#ifndef SHORTCUTTABLEVIEW_H
#define SHORTCUTTABLEVIEW_H

#include <QTableView>
#include <QKeyEvent>

class ShortcutTableView : public QTableView {
    Q_OBJECT
public:
    explicit ShortcutTableView(QWidget* parent = nullptr);

signals:
    void playRequested();
    void likeIncrementRequested();
    void deleteOrDislikeRequested();
    void homeRequested();
    void endRequested();
    void escapeRequested();

protected:
    void keyPressEvent(QKeyEvent* event) override;
};

#endif // SHORTCUTTABLEVIEW_H
