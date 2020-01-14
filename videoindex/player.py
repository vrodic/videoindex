#!/usr/bin/env python3

import sqlite3
import sys
import os
from PyQt5.QtCore import Qt
from PyQt5.QtWidgets import (QWidget, QLabel, QLineEdit,
                             QTextEdit, QGridLayout, QApplication, QListWidget, QTableWidget, QTableWidgetItem,
                             QAbstractItemView, QHeaderView)
from shlex import quote


class NumericTableWidgetItem(QTableWidgetItem):
    def __lt__(self, other):
        if (isinstance(other, QTableWidgetItem)):
            if self.data(Qt.EditRole) == "None":
                return True
            if other.data(Qt.EditRole) == "None":
                return False

            try:
                my_value = float(self.data(Qt.EditRole))
                other_value = float(other.data(Qt.EditRole))
            except:
                return False

            return my_value < other_value

        return super(NumericTableWidgetItem, self).__lt__(other)


class Player(QWidget):

    def __init__(self, root_dir, index_file):
        self.root_dir = root_dir
        self.connection = sqlite3.connect(index_file)
        self.cursor = self.connection.cursor()
        self.table = QTableWidget()

        self.item_count = 0
        self.search_expression = "%%"
        
        self.playing = 0
        self.more_conditions = \
            " AND filename NOT LIKE '%.jpg' AND codec_name <> 'mjpeg' " \
            " AND filename NOT LIKE '%.unwanted%' AND filename NOT LIKE '%SMP-B9R%' " \
            " AND filename NOT LIKE '%SAMPLE-B9R%'"
        self.deduplicate_by_nb_frames = \
            " AND duration IN (select duration from media where duration > 60 group by 1 having count(*) > 1 ) " \
            " AND nb_frames IN (select nb_frames from media where duration > 60 group by 1 having count(*) > 1 ) "
        self.deduplicate_by_nb_frames = ''
        # self.order = " ORDER by view_count ASC, file_size DESC"
        self.order = " ORDER by view_count ASC, file_size DESC"
        self.order = "  and like > 2 ORDER by random()"
        self.condition_expression = self.order
        # self.order = " ORDER by duration DESC"
        
        super().__init__()

        self.init_ui()

    def play_video(self):
        self.playing = 1
        selected_items = self.table.selectedItems()
        media_id = selected_items[0].text()
        filename = selected_items[1].text()
        view_count = selected_items[2].text()

        full_path = self.root_dir + "/" + filename

        os.system('mpv -fs {} &'.format(quote(full_path)))
        current_row = self.table.selectedIndexes()[0].row()
        nextFile = self.table.item(current_row + 1, 1)

        # pre-caching
        #if nextFile:
        #    os.system('killall cat')
        #    os.system('cat {} >& /dev/null &'.format(quote(self.root_dir + "/" + nextFile.text())))

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
        # self.select_row(1)
        # self.play_video()

    def like(self, amount):
        selected_items = self.table.selectedItems()
        if not selected_items:
            return
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

    def is_number(self, s):
        try:
            int(s)
            return True
        except ValueError:
            return False

    def delete(self):
        selected_items = self.table.selectedItems()
        like = selected_items[3].text()
        
        if self.is_number(like) and int(like) >= -1:
            print("can t delete liked    ")
            return False

        current_row = self.table.selectedIndexes()[0].row()
        media_id = selected_items[0].text()
        filename = selected_items[1].text()
        full_path = self.root_dir + "/" + filename
        print("deleting " + full_path)
        
        try:
            os.remove(full_path)
        except Exception as ex:
            print("no file")

        sql_metadata = [media_id]
        self.cursor.execute("DELETE FROM  media "
                            "WHERE id=?"
                            , sql_metadata)
        # self.connection.commit()
        self.table.removeRow(current_row)
        self.table.selectRow(current_row)
        return True

    def keyPressEvent(self, e):
        key = e.key()

        if key == Qt.Key_Escape:
            self.connection.commit()
            self.close()

        elif key == Qt.Key_Return:

            # print(selectedItems)
            self.play_video()

        elif key == Qt.Key_Down:

            self.select_row(1)

        elif key == Qt.Key_Up:

            self.select_row(-1)

        elif key == Qt.Key_Insert:
            self.like(1)

            self.select_row(1)

        elif key == Qt.Key_Delete:
            self.like(-1)
            if self.delete():
                return
            self.select_row(1)

    def select_row(self, amount):
        try:
            current_row = self.table.selectedIndexes()[0].row()
        except Exception as ex:
            self.table.selectRow(0)
        else:
            self.table.selectRow(current_row + amount)

    def load_items(self, table):
        table.setSortingEnabled(False)
        query = "SELECT id,filename,view_count,like,file_size, creation_time,width,file_size/(duration*width) FROM media " \
                "WHERE filename LIKE ? " \
                + self.more_conditions + " " + self.deduplicate_by_nb_frames + " "\
                + self.condition_expression
                

        print(query)
        self.cursor.execute(
            query, [self.search_expression]
        )
        items = self.cursor.fetchall()
        self.item_count = len(items)
        table.setRowCount(self.item_count)
        row = 0
        for item in items:
            table.setItem(row, 0, NumericTableWidgetItem(str(item[0])))
            table.setItem(row, 1, QTableWidgetItem(item[1]))
            table.setItem(row, 2, NumericTableWidgetItem(str(item[2])))
            table.setItem(row, 3, NumericTableWidgetItem(str(item[3])))
            table.setItem(row, 4, NumericTableWidgetItem(str(round(item[4] / (1024 * 1024)))))
            table.setItem(row, 5, QTableWidgetItem(str(item[5])))
            table.setItem(row, 6, NumericTableWidgetItem(str(item[6])))
            table.setItem(row, 7, NumericTableWidgetItem(str(round(item[7]))))
            row += 1
        table.setSortingEnabled(True)
        self.select_row(0)

    def set_search_term(self, term):
        self.search_expression = "%" + term + "%"
        self.table.setRowCount(0)
        self.load_items(self.table)

    def set_condition_term(self, term):
        self.condition_expression = term        
        try:
            self.load_items(self.table)    
        except:
            return                 

    def init_ui(self):
        table = self.table

        searchEdit = QLineEdit()        
        searchEdit.textChanged.connect(self.set_search_term)

        conditionEdit = QLineEdit() 
        conditionEdit.setText(self.order)
        conditionEdit.textChanged.connect(self.set_condition_term)

        table.setColumnCount(8)
        table.setSelectionBehavior(QAbstractItemView.SelectRows)
        header = table.horizontalHeader()
        header.sortIndicatorOrder()
        header.setSectionResizeMode(1, QHeaderView.Stretch)
        table.setHorizontalHeaderLabels(['id', 'filename', 'views', 'likes', 'size'])

        self.load_items(table)

        grid = QGridLayout()
        grid.setSpacing(10)
        grid.addWidget(searchEdit, 2, 0)

        grid.addWidget(table, 1, 0)
        grid.addWidget(conditionEdit, 3, 0)
        self.setLayout(grid)
        self.setGeometry(0, 0, 1550, 1000)
        self.setWindowTitle('videoindex')
        self.show()


if __name__ == '__main__':
    app = QApplication(sys.argv)

    ex = Player(sys.argv[1], sys.argv[2])
    sys.exit(app.exec_())
