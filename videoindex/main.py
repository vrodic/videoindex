import os
import sys
import glob
import ffmpeg
import sqlite3
import hashlib
import signal

root_dir = sys.argv[1]

conn = sqlite3.connect(root_dir+'/videoindex.db')
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS media
             (id INTEGER PRIMARY KEY AUTOINCREMENT, 
             filename text,
             duration real,
             codec_name text,
             width integer,
             height integer,
             nb_frames integer,
             creation_time datetime,
             file_size integer,
             sha1 text
             )''')
conn.commit()


skipexts = ['.jpg', '.gif', '.jpeg', '.nfo', '.png', '.srt', '.zip']


def sha1file(filename):
    buf_size = 1048576   # lets read stuff in 64kb chunks!
    sha1 = hashlib.sha1()
    with open(filename, 'rb') as f:
        while True:
            data = f.read(buf_size)
            if not data:
                break

            sha1.update(data)
    return sha1.hexdigest()


for folder, subs, files in os.walk(root_dir, followlinks=True):
    for filename in files:
        fname = os.path.join(folder, filename)
        fn1, file_extension = os.path.splitext(fname)

        if file_extension.lower() in skipexts:
            break
        c.execute('SELECT * FROM media WHERE filename=?', [fname])
        item = c.fetchone()
        if (item):
            print("Already scanned " + fname)
            break
        try:
            metadata = ffmpeg.probe(fname)
        except:
            print('error probing ' + fname)
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


                sql_metadata = [fname,
                                 metadata['format']['duration'],
                                 metadata['streams'][0]['codec_name'],
                                 width,
                                 height,
                                 nb_frames,
                                 creation_time,
                                 file_size,
                                 ]
            except:
                print ("Metadata error: " + fname)
            else:
                print('.', end='')
                sys.stdout.flush()
                c.execute("INSERT INTO media (filename,duration,codec_name,width,height,nb_frames,creation_time,file_size) VALUES(?,?,?,?,?,?,?,?)", sql_metadata)
                conn.commit()