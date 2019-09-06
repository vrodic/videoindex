#!/usr/bin/env python3
import os
import sys
import sqlite3
import pathlib
import shutil

class Backup:
    def __init__(self, root_dir, db_file, backup_dir):
        self.root_dir = root_dir
        self.backup_dir = backup_dir
        self.connection = sqlite3.connect(db_file)
        self.cursor = self.connection.cursor()

    def backup(self):
        query = "SELECT id,filename,file_size,view_count,like,creation_time FROM media " \
                    "WHERE like > 1 ORDER BY like DESC"                     
                
        print(query)
        self.cursor.execute(
            query
        )
        items = self.cursor.fetchall()
        self.item_count = len(items)
        
        count = 0
        
        for item in items:
            filename = item[1]
            count += 1
            
            path = self.backup_dir + "/" + os.path.dirname(filename)
            backup_filename = self.backup_dir + "/" + filename
            full_filename = self.root_dir + "/" + filename
            if not os.path.exists(path):
                pathlib.Path(path).mkdir(parents=True, exist_ok=True)
            if os.path.isfile(backup_filename) and os.path.getsize(backup_filename) == os.path.getsize(full_filename):
                continue
            print("Copying " + str(count) + " " + full_filename + " to " + backup_filename)
            shutil.copy2(full_filename, backup_filename)
            

backup = Backup(sys.argv[1], sys.argv[2], sys.argv[3])
backup.backup()

