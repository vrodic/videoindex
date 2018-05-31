import sqlite3
import sys
import os
from PyQt5.QtCore import Qt
from PyQt5.QtWidgets import (QWidget, QLabel, QLineEdit,
                             QTextEdit, QGridLayout, QApplication, QListWidget, QTableWidget, QTableWidgetItem,
                             QAbstractItemView, QHeaderView)


class NumericTableWidgetItem(QTableWidgetItem):
    def __lt__(self, other):
        if ( isinstance(other, QTableWidgetItem) ):
            if self.data(Qt.EditRole) == "None":
                return True
            if other.data(Qt.EditRole) == "None":
                return False

            my_value = float(self.data(Qt.EditRole))
            other_value = float(other.data(Qt.EditRole))

            return my_value < other_value

        return super(NumericTableWidgetItem, self).__lt__(other)

class Player(QWidget):

    def __init__(self,root_dir):
        self.root_dir = root_dir
        self.connection = sqlite3.connect(root_dir + '/videoindex.db')
        self.cursor = self.connection.cursor()
        self.table = QTableWidget()

        self.item_count = 0
        self.search_expression = "%%"
        self.playing = 0
        self.more_conditions = " AND filename NOT LIKE '%.jpg' ";

        super().__init__()

        self.initUI()

    def play_video(self):
        self.playing = 1
        selected_items = self.table.selectedItems()
        media_id = selected_items[0].text()
        filename = selected_items[1].text()
        view_count = selected_items[2].text()

        os.system('mpv "' + self.root_dir + "/" + filename + '" ')

        if view_count == 'None':
            view_count = 1
        else:
            view_count = int(view_count) + 1
        self.table.setItem(self.table.selectedIndexes()[0].row(), 2, QTableWidgetItem(str(view_count)))

        sql_metadata = [view_count, media_id]
        self.cursor.execute("UPDATE media SET view_count=?"
                            "WHERE id=?"
                            , sql_metadata)
        self.connection.commit()
        #self.select_row(1)
        #self.play_video()


    def like(self, amount):
        selected_items = self.table.selectedItems()

        like = selected_items[3].text()
        if like == 'None':
            like = amount
        else:
            like = int(like) + amount
        self.table.setItem(self.table.selectedIndexes()[0].row(), 3, QTableWidgetItem(str(like)))

        sql_metadata = [like, selected_items[0].text()]
        self.cursor.execute("UPDATE media SET like=?"
                            "WHERE id=?"
                            , sql_metadata)
        self.connection.commit()

    def keyPressEvent(self, e):
        key = e.key()

        if key == Qt.Key_Escape:
            self.close()

        elif key == Qt.Key_Return:

            # print(selectedItems)
            self.play_video()

        elif key == Qt.Key_Down:

            self.select_row(1)

        elif key == Qt.Key_Up:

            self.select_row(-1)

        elif key == Qt.Key_Shift:
            self.like(1)

            self.select_row(1)


        elif key == Qt.Key_Control:
            self.like(-1)

            self.select_row(1)


    def select_row(self, amount):
        try:
         current_row = self.table.selectedIndexes()[0].row()
        except Exception as ex:
            self.table.selectRow(0)
        else:
            self.table.selectRow(current_row + amount)


    def loadItems(self, table):
        table.setSortingEnabled(False)
        self.cursor.execute("SELECT id,filename,view_count,like,file_size, creation_time FROM media WHERE filename LIKE ? "
                            + self.more_conditions , [self.search_expression])
        items = self.cursor.fetchall()
        self.item_count = len(items)
        table.setRowCount(self.item_count)
        row = 0
        for item in items:
            table.setItem(row, 0, QTableWidgetItem(str(item[0])))
            table.setItem(row, 1, QTableWidgetItem(item[1]))
            table.setItem(row, 2, QTableWidgetItem(str(item[2])))
            table.setItem(row, 3, NumericTableWidgetItem(str(item[3])))
            table.setItem(row, 4, NumericTableWidgetItem(str(item[4]/(1024*1024))))
            table.setItem(row, 5, QTableWidgetItem(str(item[5])))
            row += 1
        table.setSortingEnabled(True)
        self.select_row(0)

    def setSearchTerm(self, term):
        self.search_expression = "%"+term+"%"
        self.table.setRowCount(0)
        self.loadItems(self.table)


    def initUI(self):
        searchEdit = QLineEdit()
        table =  self.table
        searchEdit.textChanged.connect(self.setSearchTerm)

        table.setColumnCount(6)
        table.setSelectionBehavior(QAbstractItemView.SelectRows)
        header = table.horizontalHeader()
        header.sortIndicatorOrder()
        header.setSectionResizeMode(1, QHeaderView.Stretch)
        table.setHorizontalHeaderLabels(['id','filename','views','likes','size'])


        self.loadItems(table)

        grid = QGridLayout()
        grid.setSpacing(10)
        grid.addWidget(searchEdit, 2, 0)
        grid.addWidget(table, 1, 0)

        self.setLayout(grid)
        self.setGeometry(0, 0, 1550, 1000)
        self.setWindowTitle('videoindex')
        self.show()


if __name__ == '__main__':
    app = QApplication(sys.argv)

    ex = Player(sys.argv[1])
    sys.exit(app.exec_())

