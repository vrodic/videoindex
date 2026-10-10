#include "ShortcutTableView.h"

ShortcutTableView::ShortcutTableView(QWidget* parent)
    : QTableView(parent)
{
    setSelectionBehavior(QAbstractItemView::SelectRows);
    setSelectionMode(QAbstractItemView::SingleSelection);
    setAlternatingRowColors(true);
    setSortingEnabled(true);
}

void ShortcutTableView::keyPressEvent(QKeyEvent* event) {
    int key = event->key();

    if (key == Qt::Key_Escape) {
        emit escapeRequested();
    } else if (key == Qt::Key_Return || key == Qt::Key_Enter) {
        emit playRequested();
    } else if (key == Qt::Key_Delete || key == Qt::Key_Backspace) {
        emit deleteOrDislikeRequested();
    } else if (key == Qt::Key_Home) {
        emit homeRequested();
    } else if (key == Qt::Key_End) {
        emit endRequested();
    } else if (key == Qt::Key_Insert || key == Qt::Key_Plus || key == Qt::Key_Equal) {
        emit likeIncrementRequested();
    } else {
        QTableView::keyPressEvent(event);
    }
}
