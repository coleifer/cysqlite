from cysqlite import *

conn = Connection('/tmp/xx.db')
conn.connect()

conn.execute('drop table if exists "kv"')
conn.execute('create table if not exists "kv" ('
             '"id" integer not null primary key, '
             '"key" text not null, '
             '"value" text not null)')

st = conn.execute_statement(
    'insert into kv (key, value) values (?,?),(?,?),(?,?)',
    ('k1', 'v1x', 'k2', 'v2yy', 'k3', 'v3'))
print(list(st))
print(st.changes())
print(st.last_insert_rowid())

def cb(row):
    print(row)

conn.execute('select * from kv', cb)

st = conn.execute_statement('select * from kv;')
print(list(st))

conn.close()
