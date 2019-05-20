import os

from cysqlite import *


conn = Connection(':memory:')
conn.connect()

r = conn.execute('create table kv (id integer not null primary key, key text, '
                 'value text)')
print(r)

r = conn.execute('insert into kv (key, value) values (?, ?), (?, ?), (?, ?)',
                 ('k1', 'v1x', 'k2', 'v2', 'k3', 'v3zzz'))
print(r)
print(conn.last_insert_rowid())

curs = conn.execute('select * from kv order by key desc')
for row in curs:
    print(row)

conn.execute_simple('drop table kv')
conn.close()
