#!/usr/bin/env python3
import os
import sys
import ffmpeg
import sqlite3
import hashlib


skip_ext = [
    '.jpg', '.gif', '.jpeg', '.nfo', '.png', '.srt', '.zip', '.rar', '.vtx', '.parts', '.mp3', '.txt', '.wma',
    '.ogg', '.mp2', '.ini'
]


class Scanner:
    already_scanned = 0
    skipped = 0
    error_probing = 0
    added = 0
    cursor = None
    connection = None

    def sha1file(self, filename):
        buf_size = 1048576  # lets read stuff in 64kb chunks!
        sha1 = hashlib.sha1()
        with open(filename, 'rb') as f:
            while True:
                data = f.read(buf_size)
                if not data:
                    break

                sha1.update(data)
        return sha1.hexdigest()

    def __init__(self,root_dir, db_file):
        self.root_dir = root_dir
        self.connection = sqlite3.connect(db_file)
        self.cursor = self.connection.cursor()
        self.cursor.execute('''CREATE TABLE IF NOT EXISTS media
                             (id INTEGER PRIMARY KEY AUTOINCREMENT, 
                             filename text,
                             duration real,
                             codec_name text,
                             width integer,
                             height integer,
                             nb_frames integer,
                             creation_time datetime,
                             file_size integer,
                             sha1 text,
                             view_count integer,
                             like integer                            
                             )''')
        self.connection.commit()

    def ff_probe(self, fname):
        relative_name = fname[len(self.root_dir):]
        if relative_name[0] == '/':
            relative_name = relative_name[1:]

        _, file_extension = os.path.splitext(fname)
        if file_extension.lower() in skip_ext:
            # print('skipped ' + relative_name)
            self.skipped += 1
            return

        self.cursor.execute('SELECT * FROM media WHERE filename=?', [relative_name])
        item = self.cursor.fetchone()
        if item:
            # print('already scanned ' + relative_name)
            self.already_scanned += 1
            return

        try:
            metadata = ffmpeg.probe(fname)
        except:
            self.error_probing += 1
            return
        else:
            file_size = os.path.getsize(fname)
            try:
                if 'tags' in metadata['streams'][0] and 'creation_time' in metadata['streams'][0]['tags']:
                    creation_time = metadata['streams'][0]['tags']['creation_time'];
                else:
                    creation_time = None
                if 'nb_frames' in metadata['streams'][0]:
                    nb_frames = metadata['streams'][0]['nb_frames']
                else:
                    nb_frames = None

                if 'width' in metadata['streams'][0]:
                    width = metadata['streams'][0]['width']
                    height = metadata['streams'][0]['height']
                elif 'width' in metadata['streams'][1]:
                    width = metadata['streams'][1]['width']
                    height = metadata['streams'][1]['height']
                else:
                    width = None
                    height = None

                sql_metadata = [
                    relative_name,
                    metadata['format']['duration'],
                    metadata['streams'][0]['codec_name'],
                    width,
                    height,
                    nb_frames,
                    creation_time,
                    file_size,
                ]

            except Exception as ex:
                print("Metadata error: " + relative_name)
            else:
                print('.', end='')
                sys.stdout.flush()
                self.cursor.execute("INSERT INTO media "
                                    "(filename,duration,codec_name,width,height,nb_frames,creation_time,file_size) "
                                    "VALUES(?,?,?,?,?,?,?,?)", sql_metadata)
                self.connection.commit()
                self.added += 1

    def scan(self):
        for folder, subs, files in os.walk(self.root_dir, followlinks=True):
            for filename in files:
                fname = os.path.join(folder, filename)
                self.ff_probe(fname)

        print("Files already scanned: " + str(self.already_scanned))
        print("Skipped: " + str(self.skipped))
        print("Added: " + str(self.added))


scanner = Scanner(sys.argv[1], sys.argv[2])
scanner.scan()
