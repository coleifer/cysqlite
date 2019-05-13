from cysqlite import *

conn = Connection('/tmp/xx.db')
conn.connect()

def cb(row):
    print(row)

conn.execute('select * from kv', cb)

st = Statement(conn, "select * from kv")
print(st.execute())

conn.close()
