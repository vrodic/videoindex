#!/usr/bin/env python3
import os
import sys
import sqlite3
import pathlib
import shutil
import time


class Backup:
    def __init__(self, root_dir, db_file, backup_dir):
        self.root_dir = root_dir
        self.backup_dir = backup_dir
        self.connection = sqlite3.connect(db_file)
        self.cursor = self.connection.cursor()

    def backup(self):
        query = "SELECT id,filename,file_size,like,view_count,creation_time FROM media " \
                    "WHERE like = 2 ORDER BY like DESC, file_size DESC"                     
                
        print(query)
        self.cursor.execute(
            query
        )
        items = self.cursor.fetchall()
        self.item_count = len(items)
        
        count = 0
        
        totalsize = 0
        for item in items:
            totalsize += int(item[2])
        totalsize_saved = totalsize            

        for item in items:
            filename = item[1]
            likes = item[3]
            count += 1
            
            path = self.backup_dir + "/" + os.path.dirname(filename)
            backup_filename = self.backup_dir + "/" + filename
            full_filename = self.root_dir + "/" + filename            
            if not os.path.exists(path):
                continue
            if os.path.isfile(backup_filename) and os.path.getsize(backup_filename) == os.path.getsize(full_filename):
                os.unlink(backup_filename)
                continue
            


backup = Backup(sys.argv[1], sys.argv[2], sys.argv[3])
backup.backup()

