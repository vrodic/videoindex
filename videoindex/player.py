#!/usr/bin/env python3

import sqlite3
import sys
import os
from PyQt6 import QtCore
from PyQt6.QtCore import Qt, QSortFilterProxyModel
from PyQt6.QtWidgets import (QTableView, QWidget, QLabel, QLineEdit,
                             QTextEdit, QGridLayout, QApplication, QListWidget, QTableWidget, QTableWidgetItem,
                             QAbstractItemView, QHeaderView)
from shlex import quote


class TableModel(QtCore.QAbstractTableModel):
    def __init__(self, data):
        super(TableModel, self).__init__()
        
        self.hheaders = ['id', 'filename', 'views', 'likes', 'size', '', '','']
        self._data = data

    def data(self, index, role):
        if role == Qt.ItemDataRole.DisplayRole:
            # See below for the nested-list data structure.
            # .row() indexes into the outer list,
            # .column() indexes into the sub-list
            return self._data[index.row()][index.column()]

    def rowCount(self, index):
        # The length of the outer list.
        return len(self._data)

    def allData(self):
        return self._data

    def columnCount(self, index):
        # The following takes the first sub-list, and returns
        # the length (only works if all rows are an equal length)
        if len(self._data) == 0:
            return 0 
        return len(self._data[0])

    def headerData(self, section, orientation, role):           # <<<<<<<<<<<<<<< NEW DEF
        # row and column headers
        if role == Qt.ItemDataRole.DisplayRole:
            if orientation == Qt.Orientation.Horizontal:                
                return self.hheaders[section]
        return QtCore.QVariant()                        



class Player(QWidget):

    def __init__(self, root_dir, index_file):
        self.root_dir = root_dir
        self.connection = sqlite3.connect(index_file)
        self.cursor = self.connection.cursor()

        
        self.table = QTableView()
        
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
        self.order = "  and like > 2 ORDER by viewed_time, random()"
        self.condition_expression = self.order
        # self.order = " ORDER by duration DESC"
        
        super().__init__()

        self.init_ui()

    def set_data(self, row, column, value):
        self.items[row] = list(self.items[row])
        self.items[row][column] = value

        index = self.table.model().mapFromSource(self.model.createIndex(row, column))
        self.table.model().dataChanged.emit(index, index)

    def set_model(self):
        self.model = TableModel(self.items)
        proxyModel =  QSortFilterProxyModel(self)
        proxyModel.setSourceModel(self.model)
        proxyModel.setDynamicSortFilter(True);
        self.table.setModel(proxyModel)
   
    def play_video(self):
        self.playing = 1
        current_row = self.table.model().mapToSource(self.table.currentIndex()).row()
        selected_row = self.items[current_row]
        
        media_id = selected_row[0]
        filename = selected_row[1]
        view_count = selected_row[2]

        full_path = self.root_dir + "/" + filename

        os.system('mpv  {} &'.format(quote(full_path)))
                
        

        # pre-caching
        #nextFile = self.table.item(current_row + 1, 1)
        #if nextFile:
        #    os.system('killall cat')
        #    os.system('cat {} >& /dev/null &'.format(quote(self.root_dir + "/" + nextFile.text())))

        if view_count is None:
            view_count = 1
        else:
            view_count = int(view_count) + 1

        self.set_data(current_row, 2, view_count)

        sql_metadata = [view_count, media_id]
        self.cursor.execute("UPDATE media SET view_count=?, viewed_time=datetime('now') "
                            "WHERE id=?"
                            , sql_metadata)
        self.connection.commit()  

    def like(self, amount):        
        current_row = self.table.model().mapToSource(self.table.currentIndex()).row()
        selected_row = self.items[current_row]

        if not selected_row:
            return
        like = selected_row[3]
        if like is None:
            like = amount
        else:
            like = int(like) + amount
        
        self.set_data(current_row, 3, like)

        sql_metadata = [like, selected_row[0]]
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
        current_row = self.table.model().mapToSource(self.table.currentIndex()).row()
        selected_row = self.items[current_row]
        like = selected_row[3]
        
        if self.is_number(like) and int(like) >= -1:
            print("can t delete liked    ")
            return False

        
        media_id = selected_row[0]
        filename = selected_row[1]
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
        del self.items[current_row]


        index = self.table.model().mapFromSource(self.model.createIndex(current_row, 0))
        
        self.table.model().dataChanged.emit(index,
                        self.table.model().createIndex(self.table.model().rowCount(),self.table.model().columnCount()))
        
 
        return True

    def keyPressEvent(self, e):
        key = e.key()

        if key == Qt.Key.Key_Escape:
            self.connection.commit()
            self.close()

        elif key == Qt.Key.Key_Return:

            # print(selectedItems)
            self.play_video()

        elif key == Qt.Key.Key_Down:

            self.select_row(1)

        elif key == Qt.Key.Key_Up:

            self.select_row(-1)

        elif key == Qt.Key.Key_Insert:
            self.like(1)

            self.select_row(1)

        elif key == Qt.Key.Key_Delete:
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
        self.table.setSortingEnabled(False)           
        query = "SELECT id,filename,view_count,like,file_size, viewed_time,width,file_size/(duration*width) FROM media " \
                "WHERE filename LIKE ? " \
                + self.more_conditions + " " + self.deduplicate_by_nb_frames + " "\
                + self.condition_expression
                

        print(query)
        self.cursor.execute(
            query, [self.search_expression]
        )
        self.items = list(self.cursor.fetchall())        
        #self.table.setSortingEnabled(True)
        self.set_model()

        header = table.horizontalHeader()
        header.sortIndicatorOrder()      
        
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)             
        
        self.select_row(0)
        

    def set_search_term(self, term):
        self.search_expression = "%" + term + "%"
        #self.table.setRowCount(0)
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
        
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)             
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
    sys.exit(app.exec())
