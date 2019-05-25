import os

from cysqlite import *

def pd():
    print('-' * 70)

conn = Connection(':memory:')
conn.connect()

r = conn.execute('create table kv (id integer not null primary key, key text, '
                 'value text)')
print(r)

r = conn.execute('insert into kv (key, value) values (?, ?), (?, ?), (?, ?)',
                 ('k1', 'v1x', 'k2', 'v2', 'k3', 'v3zzz'))
print(r)
print(conn.last_insert_rowid())

pd()

curs = conn.execute('select * from kv where key > ? order by key desc', ('k1',))
for row in curs:
    print(row)

with conn.atomic() as txn:
    conn.execute('insert into kv (key, value) values (?, ?)', ('k4', 'v4a'))
    txn.rollback()

with conn.atomic() as txn:
    with conn.atomic() as sp:
        conn.execute('insert into kv (key, value) values (?, ?)', ('k5', 'v5'))
    with conn.atomic() as sp:
        conn.execute('insert into kv (key, value) values (?, ?)', ('k5', 'v5'))
        sp.rollback()
    conn.execute('insert into kv (key, value) values (?, ?)', ('k7', 'v7'))

pd()

curs = conn.execute('select * from kv where key > ? order by key desc', ('k2',))
for row in curs:
    print(row)

conn.execute_simple('drop table kv')
conn.close()

pd()

conn.connect()
conn.execute('create table foo (id integer not null primary key, key text)')
conn.execute('insert into foo (key) values (?), (?), (?), (?)',
             ('k1', 'k2', 'k3', 'k4'))
for row in conn.execute('select * from foo'):
    print(row[0], '->', row[1])

try:
    conn.execute('select * from zoo;')
except Exception as exc:
    print(exc)

conn.execute('delete from foo where id < ?', (3,))
print(conn.changes())

conn.close()

# Test statement cache.
conn = Connection(':memory:', cached_statements=2)
conn.connect()

conn.execute('create table foo (key text, value text)')
with conn.atomic():
    for k, v in zip('abcdefg', 'hijklmno'):
        conn.execute('INSERT INTO foo (key, value) VALUES (?, ?)', (k, v))

    list(conn.execute('select * from foo'))
    list(conn.execute('select * from foo'))

conn.close()

pd()

# Test blob I/O.
conn.connect()
conn.execute('create table register (id integer not null primary key, '
             'data blob not null)')
def make_blob(n):
    conn.execute('insert into register (data) values (zeroblob(?))', (n,))
    return conn.last_insert_rowid()

r1024 = make_blob(1024)
r16 = make_blob(16)
b = Blob(conn, 'register', 'data', r1024)
print('1024? len = ', len(b))
b.write(b'x' * 1022)
b.write(b'zz')
b.seek(1020)
data = b.read(3)
print('xxz? data = ', data)
assert b.read() == b'z'
assert b.read() == b''
b.seek(-10, 2)
assert b.tell() == 1014
assert b.read() == b'xxxxxxxxzz'

b.reopen(r16)
assert b.tell() == 0
assert len(b) == 16
b.write(b'x' * 15)
assert b.tell() == 15
b.close()

for row in conn.execute('select * from register'):
    print(row)

conn.close()

pd()

conn = Connection(':memory:')
conn.connect()
conn.set_busy_handler(4)
conn.execute('create table kv (key text, value text)')
conn.execute('insert into kv (key, value) values (?, ?), (?, ?), (?, ?)',
             ('k1', 'v1', 'k2', 'v2x', 'k3', 'v3-y'))

def my_func(s):
    if s is None:
        return
    return s[::-1].title()

class MySum(object):
    def __init__(self): self.ct = 0
    def step(self, n): self.ct += n
    def inverse(self, n): self.ct -= n
    def value(self): return self.ct
    def finalize(self): return self.ct

conn.create_function(my_func)
conn.create_aggregate(MySum, 'mysum', 1)
conn.create_window_function(MySum, 'mysumw', 1)

for row in conn.execute('select key, my_func(key), my_func(value) from kv'):
    print(row)

conn.execute('create table sample (id integer not null primary key, '
             'category text, value int)')
data = (
    ('a', 10),
    ('a', 20),
    ('b', 1),
    ('b', 2),
    ('c', 100))
for _ in range(10):
    for cat_val in data:
        conn.execute('insert into sample (category, value) values (?, ?)',
                     cat_val)

agg_sql = 'select category, mysum(value) from sample group by category'
for row in conn.execute(agg_sql):
    print(row)

w_sql = ('select category, mysumw(value) over (partition by category) '
         'from sample')
for row in conn.execute(w_sql):
    pass

conn.close()

pd()

def my_collation(s1, s2):
    x1 = s1.lower()[::-1]
    x2 = s2.lower()[::-1]
    return 1 if x1 > x2 else (0 if x1 == x2 else -1)

conn.connect()
conn.create_collation(my_collation, 'rev')

def update_hook(qtype, db, tbl, rowid):
    print(qtype, db, tbl, rowid)
conn.update_hook(update_hook)

conn.execute('create table kv (key text, value text)')
conn.execute('insert into kv (key, value) values (?, ?), (?, ?), (?, ?)',
             ('k1', 'v1x', 'k2', 'v222y', 'k3', 'v3a'))

curs = conn.execute('select * from kv order by value collate rev')
print(curs.description())
print(curs.details())
for row in curs:
    print(row)

pd()

print(sqlite_version)
print(sqlite_version_info)
