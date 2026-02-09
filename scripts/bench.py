import contextlib
import time

import sqlite3
import cysqlite

sq3_db = sqlite3.connect(':memory:')
cy_db = cysqlite.connect(':memory:')

@contextlib.contextmanager
def measure(db, name):
    s = time.perf_counter()
    yield
    e = time.perf_counter()
    print('%0.2f - %s [%s]' % (e - s, name, db))

def test_bind(db):
    params = [
        'a' * 256,
        b'b' * 256,
        1,
        2.,
        None] * 100
    binds = ', '.join(['?'] * len(params))
    sql = 'select %s' % binds
    params = tuple(params)

    with measure(db, 'bind'):
        for i in range(10000):
            db.execute(sql, params).fetchall()

def test_bind_small(db):
    params = ['a' * 10, 'b' * 10]
    binds = ', '.join(['?'] * len(params))
    sql = 'select %s' % binds
    params = tuple(params)

    with measure(db, 'bind (small)'):
        for i in range(50000):
            db.execute(sql, params).fetchall()

def test_column(db):
    values = list(range(400))
    cols = ', '.join(['col%d' % i for i in range(len(values))])
    db.execute('create table k (%s)' % cols)

    binds = ', '.join(['?'] * len(values))
    db.execute('insert into k values (%s)' % binds, values)

    with measure(db, 'column'):
        for i in range(10000):
            db.execute('select * from k').fetchall()

    db.execute('drop table k')

def test_stmt_overhead(db):
    with measure(db, 'stmt overhead'):
        for i in range(100000):
            db.execute('select 1').fetchall()

def test_stmt_overhead_cursor(db):
    cursor = db.cursor()
    with measure(db, 'stmt overhead (cursor)'):
        for i in range(100000):
            cursor.execute('select 1').fetchall()

def test_iterate(db):
    db.execute('create table k (id integer not null primary key, data text)')
    db.executemany('insert into k (data) values (?)',
                   [('k%06d' % i,) for i in range(10000)])

    with measure(db, 'iterate'):
        for i in range(1000):
            db.execute('select * from k').fetchall()

    db.execute('drop table k')

test_bind(sq3_db)
test_bind(cy_db)

test_bind_small(sq3_db)
test_bind_small(cy_db)

test_column(sq3_db)
test_column(cy_db)

test_iterate(sq3_db)
test_iterate(cy_db)

test_stmt_overhead(sq3_db)
test_stmt_overhead(cy_db)

test_stmt_overhead_cursor(sq3_db)
test_stmt_overhead_cursor(cy_db)
