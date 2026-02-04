import glob
import os
import re
import sys
import threading
import unittest
import uuid
from decimal import Decimal
from fractions import Fraction

from cysqlite import *


SLOW_TESTS = os.environ.get('SLOW_TESTS')
VAL_TESTS = [
    None,
    1,
    -1,
    2.5,
    1.5e-9,
    2147483647,
    -2147483647,
    2147483648,
    -2147483648,
    2147483999,
    -2147483999,
    992147483999,
    -992147483999,
    9223372036854775807,
    -9223372036854775808,
    b'\xff\x00\xfe',
    b'\x00',
    'a \u1234 unicode \ufe54 string \u0089',
    '\N{MUSICAL SYMBOL G CLEF}',
]
_u = uuid.uuid4()
_buf = bytearray(b'\xff\x00' * 32)
_mv = memoryview(_buf[1:])
VAL_CONVERSION_TESTS = [
    (True, 1),
    (False, 0),
    (datetime.datetime(2026, 1, 2, 3, 4, 5), '2026-01-02 03:04:05'),
    (datetime.date(2026, 2, 3), '2026-02-03'),
    (Decimal('1.23'), 1.23),
    (Fraction(3, 5), 0.6),
    (_mv, bytes(_buf[1:])),
    (_buf, bytes(_buf)),
    (_u, str(_u)),
]


class BaseTestCase(unittest.TestCase):
    filename = '/tmp/cysqlite.db'

    def cleanup(self):
        if self.filename != ':memory:':
            for filename in glob.glob(self.filename + '*'):
                if os.path.isfile(filename):
                    os.unlink(filename)

    def get_connection(self, **kwargs):
        return Connection(self.filename, **kwargs)

    def setUp(self):
        self.db = self.get_connection()
        self.db.connect()

    def tearDown(self):
        if not self.db.is_closed():
            self.db.close()
        self.cleanup()

    def create_table(self):
        self.db.execute('create table "kv" ("id" integer not null primary key,'
                        ' "key" text not null, "value" text not null, "extra" '
                        'integer)')

    def create_rows(self, *rows):
        for row in rows:
            self.db.execute('insert into "kv" ("key", "value", "extra") '
                            'values (?, ?, ?)', row)

    def assertCount(self, n):
        curs = self.db.execute('select count(*) from kv')
        self.assertEqual(curs.value(), n)

    def assertKeys(self, expected):
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([k for k, in curs], expected)


class TestOpenConnection(unittest.TestCase):
    def tearDown(self):
        for filename in glob.glob('/tmp/cysqlite-*'):
            if os.path.isfile(filename):
                os.unlink(filename)

    def assertDB(self, filename, expected):
        conn = Connection(filename)
        with conn:
            row = conn.execute_one('pragma database_list;')
            self.assertEqual(row[2], expected)

    def test_database_filename(self):
        self.assertDB(':memory:', '')
        self.assertDB('/tmp/cysqlite-test.db', '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db', '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db?mode=ro',
                      '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db?mode=ro&cache=private',
                      '/tmp/cysqlite-test.db')

    def test_open_close(self):
        db = Connection(':memory:')
        self.assertTrue(db.is_closed())
        self.assertTrue(db.connect())
        self.assertFalse(db.is_closed())
        self.assertFalse(db.connect())  # Already open.
        self.assertTrue(db.close())
        self.assertTrue(db.is_closed())
        self.assertFalse(db.close())  # Already closed.

        with db:
            self.assertFalse(db.is_closed())
        self.assertTrue(db.is_closed())


class TestCheckConnection(BaseTestCase):
    filename = ':memory:'

    def test_check_connection(self):
        self.assertFalse(self.db.is_closed())
        self.assertEqual(self.db.changes(), 0)
        self.assertEqual(self.db.total_changes(), 0)
        self.assertEqual(self.db.last_insert_rowid(), 0)
        self.assertTrue(self.db.autocommit())
        cursor = self.db.cursor()
        self.assertTrue(isinstance(cursor, Cursor))

        cursor2 = self.db.cursor()
        cursor2.execute('select 1')

        self.db.close()
        self.assertTrue(self.db.is_closed())
        self.assertRaises(OperationalError, self.db.changes)
        self.assertRaises(OperationalError, self.db.total_changes)
        self.assertRaises(OperationalError, self.db.last_insert_rowid)
        self.assertRaises(OperationalError, self.db.autocommit)
        self.assertRaises(OperationalError, self.db.execute, 'select 1')
        self.assertRaises(OperationalError, cursor.execute, 'select 1')
        self.assertRaises(OperationalError, cursor2.fetchone)

        # We can obtain a cursor, but cannot use it.
        cursor = self.db.cursor()
        self.assertTrue(isinstance(cursor, Cursor))
        self.assertRaises(OperationalError, cursor.execute, 'select 1')

        # We cannot reuse the cursor either afterwards.
        self.db.connect()
        self.assertRaises(OperationalError, cursor2.fetchone)

    def test_partial_executions(self):
        self.db.execute('create table k (data integer)')
        self.db.executemany('insert into k (data) values (?)',
                            [(1,), (2,), (3,)])

        curs = self.db.execute('select * from k order by data')
        self.assertEqual(curs.fetchone(), (1,))
        self.db.close()
        self.assertRaises(OperationalError, curs.fetchone)
        self.assertRaises(OperationalError, curs.fetchall)

        self.db.connect()
        self.assertRaises(OperationalError, curs.fetchone)
        self.assertRaises(OperationalError, curs.fetchall)

    def test_multiple_cursors_same_query(self):
        self.db.execute('create table k (data integer)')
        self.db.executemany('insert into k (data) values (?)',
                            [(1,), (2,), (3,)])

        sql = 'select * from k order by data'
        cursors = [self.db.execute(sql) for _ in range(5)]
        for cursor in cursors:
            self.assertEqual(next(cursor), (1,))
        for cursor in cursors:
            self.assertEqual(list(cursor), [(2,), (3,)])

    def test_reexecute_loop(self):
        self.db.execute('create table k (data integer)')
        self.db.executemany('insert into k (data) values (?)',
                            [(1,), (2,), (3,)])
        curs = self.db.execute('select * from k order by data')

        # Cursor is no good. Run twice to ensure state doesn't change on first
        # failure.
        self.assertRaises(OperationalError, curs.execute, 'select 1')
        self.assertRaises(OperationalError, curs.execute, 'select 1')

        # We can close and re-execute, though.
        curs.close()
        self.assertEqual(curs.execute('select 1').value(), 1)


class TestExecute(BaseTestCase):
    filename = ':memory:'

    def test_cursor_attributes(self):
        self.db.execute('create table g (k, v)')
        curs = self.db.execute('insert into g (k, v) values (?, ?), (?, ?)',
                               ('k1', 1, 'k2', 2))
        self.assertEqual(curs.lastrowid, 2)
        self.assertEqual(curs.rowcount, 2)

        curs = self.db.executemany('insert into g (k, v) values (?, ?)',
                                   [('k3', 3), ('k4', 4), ('k5', 5)])
        self.assertEqual(curs.lastrowid, 5)
        self.assertEqual(curs.rowcount, 3)  # Summed by executemany().

        curs = self.db.execute('update g set v = v + ? where v < ?', (10, 3))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 2)

        curs = self.db.execute('update g set v = v + ? where v < ?', (100, 1))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 0)

        curs = self.db.execute('delete from g where v < ?', (6,))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 3)

        curs = self.db.execute('select * from g')
        self.assertTrue(curs.lastrowid is None)  # Read queries don't get this.
        self.assertEqual(curs.rowcount, -1)

    def test_execute(self):
        self.db.execute('create table g (k, v)')
        curs = self.db.execute('insert into g (k, v) values '
                               '(?, ?), (?, ?), (?, ?)',
                               ('k1', 1, 'k2', 2, 'k3', 3))

        curs = self.db.execute('select * from g order by v')
        self.assertEqual(list(curs), [('k1', 1), ('k2', 2), ('k3', 3)])

        row = self.db.execute_one('select * from g where k = ?', ('k2',))
        self.assertEqual(row, ('k2', 2))

        row = self.db.execute_one('select sum(v) from g')
        self.assertEqual(row, (6,))

        curs = self.db.execute('select sum(v) from g')
        self.assertEqual(curs.value(), 6)

    def test_executemany(self):
        self.db.execute('create table g (k, v)')
        curs = self.db.cursor()
        params = [('k%02d' % i, 'v%02d' % i) for i in range(100)]
        curs.executemany('insert into g(k, v) values (?,?)', params)
        self.assertEqual(curs.rowcount, 100)
        self.assertEqual(curs.lastrowid, 100)

        res = curs.execute('select k from g order by k desc').fetchall()
        self.assertEqual(len(res), 100)
        self.assertEqual(res[0], ('k99',))

        self.assertRaises(ValueError, lambda: curs.executemany('select 1'))

        # Read queries not allowed by executemany.
        sql = 'select * from k where id > ?'
        self.assertRaises(OperationalError,
                          lambda: curs.executemany(sql, [(1,), (2,)]))

        # Returning queries not allowed by executemany.
        with self.assertRaises(OperationalError):
            curs.executemany('insert into g(k, v) values (?, ?) returning k',
                             [('kx', 1)])

    def test_execute_wrong_params(self):
        self.db.execute('create table g (k, v)')
        q = 'insert into g (k, v) values (?, ?)'

        curs = self.db.cursor()
        for obj in (self.db, curs):
            self.assertRaises(OperationalError, obj.execute, q)
            self.assertRaises(OperationalError, obj.execute, q, (1,))
            self.assertRaises(OperationalError, obj.execute, q, (1, 2, 3))

            self.assertRaises(ValueError, obj.executemany, q, [])
            self.assertRaises(OperationalError, obj.executemany, q, [(1,)])
            self.assertRaises(OperationalError, obj.executemany, q, [(1, 2, 3)])

    def test_execute_datatypes(self):
        self.db.execute('create table k (id integer not null primary key, '
                        'n, i integer, r real, t text, b blob)')
        data = [(None, 1, 3.5, 'text', b'\x00\xff'),
                ('test', None, None, None, None),
                (b'\x00', -1, -3.5, '2', b'3')]
        self.db.executemany(
            'insert into k (n, i, r, t, b) values (?,?,?,?,?)',
            data)
        curs = self.db.execute('select n,i,r,t,b from k order by id')
        self.assertEqual(curs.fetchall(), data)

    def test_execute_inferred_types(self):
        self.db.execute('create table k (id integer primary key, data)')
        for v in VAL_TESTS:
            self.db.execute('insert into k (data) values (?)', [v])

        res = self.db.execute('select data from k order by id').fetchall()
        self.assertEqual([val for val, in res], VAL_TESTS)

    def test_execute_special_types(self):
        self.db.execute('create table k (id integer primary key, data)')
        for v, _ in VAL_CONVERSION_TESTS:
            self.db.execute('insert into k (data) values (?)', [v])

        res = self.db.execute('select data from k order by id').fetchall()
        self.assertEqual([r for r, in res],
                         [r[1] for r in VAL_CONVERSION_TESTS])


class TestQueryExecution(BaseTestCase):
    filename = ':memory:'
    test_data = [('k1', 'v1x', 10), ('k2', 'v2b', 20), ('k3', 'v3z', 30)]

    def setUp(self):
        super(TestQueryExecution, self).setUp()
        self.create_table()
        self.create_rows(*self.test_data)

    def test_connect_close(self):
        self.assertFalse(self.db.is_closed())
        self.assertFalse(self.db.connect())
        self.assertTrue(self.db.close())
        self.assertFalse(self.db.close())
        self.assertTrue(self.db.is_closed())
        self.assertTrue(self.db.connect())
        self.assertFalse(self.db.is_closed())

    def test_simple_queries(self):
        self.assertEqual(self.db.last_insert_rowid(), 3)
        self.assertEqual(self.db.changes(), 1)
        self.assertEqual(self.db.total_changes(), 3)
        self.assertCount(3)

        with self.db.atomic():
            curs = self.db.execute('select * from kv order by key')
            self.assertEqual([row[1:] for row in curs], self.test_data)

            # Exhausted cursor behavior.
            self.assertEqual(list(curs), [])
            self.assertEqual(curs.fetchall(), [])
            self.assertTrue(curs.fetchone() is None)

    def test_returning(self):
        sql = ('insert into kv (key, value, extra) values (?,?,?), (?,?,?) '
               'returning key')
        # Add two rows - lastrowid is immediately set even though we didn't
        # step over the RETURNING result set.
        curs = self.db.execute(sql, ('k4', 'v4', 4, 'k5', 'v5', 5))
        self.assertEqual(curs.lastrowid, 5)
        self.assertEqual(curs.fetchone(), ('k4',))
        self.assertEqual(curs.fetchone(), ('k5',))

        # We can close the cursor without fully stepping it.
        curs = self.db.execute(sql, ('k6', 'v6', 6, 'k7', 'v7', 7))
        self.assertEqual(curs.lastrowid, 7)
        curs.close()  # Abandon cursor without stepping.

        self.assertCount(7)  # Changes are visible.

        # We can also issue a DELETE / RETURNING and the changes are
        # immediately effective.
        sql = 'delete from kv where key in (?, ?) returning value'
        curs = self.db.execute(sql, ('k5', 'k7'))
        self.assertCount(5)  # Immediately visible.

        self.assertEqual(curs.rowcount, 2)
        self.assertEqual(sorted(curs.fetchall()), [('v5',), ('v7',)])

        # We can close the cursor, as well.
        curs = self.db.execute(sql, ('k4', 'k6'))
        self.assertEqual(curs.rowcount, 2)
        curs.close()

        self.assertCount(3)

        # Same behavior w/UPDATE queries.
        sql = ('update kv set extra = extra + 1 where key in (?, ?) '
               'returning key, extra')
        curs = self.db.execute(sql, ('k1', 'k2'))
        self.assertEqual(curs.rowcount, 2)
        self.assertEqual(sorted(curs.fetchall()), [('k1', 11), ('k2', 21)])

        self.assertEqual(self.db.execute_one('select sum(extra) from kv'),
                         (62,))

        curs = self.db.execute(sql, ('k2', 'k3'))
        self.assertEqual(curs.rowcount, 2)

        # We haven't fully stepped query, but value is correct (11 + 22 + 31).
        self.assertEqual(self.db.execute_one('select sum(extra) from kv'),
                         (64,))

        # Explicit reset of curs. Value still looks good.
        curs.close()
        self.assertEqual(self.db.execute_one('select sum(extra) from kv'),
                         (64,))

    def test_returning_on_conflict(self):
        self.db.execute('create table k (key text not null primary key, '
                        'value text not null)')
        self.db.execute('insert into k (key, value) values (?, ?)',
                        ('k1', 'v1'))

        # This INSERT + ON CONFLICT also uses a RETURNING clause.
        curs = self.db.execute('insert into k (key, value) '
                               'values (?, ?), (?, ?), (?, ?) '
                               'on conflict do update '
                               'set value = value || excluded.value '
                               'returning key, value',
                               ('k1', 'x', 'k2', 'v2', 'k1', 'z'))

        # Query the table *before* stepping the INSERT cursor.
        curs2 = self.db.execute('select key, value from k order by key')
        self.assertEqual(curs2.fetchall(), [('k1', 'v1xz'), ('k2', 'v2')])

        # Stepping the INSERT cursor gives the expected results.
        self.assertEqual(curs.fetchall(), [
            ('k1', 'v1x'),
            ('k2', 'v2'),
            ('k1', 'v1xz')])

        # We will get an IntegrityError for duplicate key violation, which
        # triggers the FAIL logic -- FAIL stops processing but does not remove
        # previously-inserted rows.
        with self.assertRaises(IntegrityError):
            curs = self.db.execute('insert or fail into k (key, value) '
                                   'values (?, ?), (?, ?), (?, ?) '
                                   'returning key, value',
                                   ('k3', 'v3', 'k1', 'v1a', 'k4', 'v4'))

        # Query the table *before* stepping the INSERT cursor.
        curs2 = self.db.execute('select key, value from k order by key')
        self.assertEqual(curs2.fetchall(),
                         [('k1', 'v1xz'), ('k2', 'v2'), ('k3', 'v3')])

        self.assertEqual(curs.rowcount, 1)
        self.assertEqual(list(curs), [])  # No results.

        # Now try an INSERT / ON CONFLICT DO NOTHING.
        curs = self.db.execute('insert into k (key, value) '
                               'values (?, ?), (?, ?) '
                               'on conflict do nothing '
                               'returning key, value',
                               ('k4', 'v4', 'k1', 'v1a'))
        curs2 = self.db.execute('select key, value from k order by key')
        self.assertEqual(curs2.fetchall(), [
            ('k1', 'v1xz'),
            ('k2', 'v2'),
            ('k3', 'v3'),
            ('k4', 'v4')])
        self.assertEqual(list(curs), [('k4', 'v4')])

    def test_nested_iteration(self):
        curs = self.db.execute('select key from kv order by key')
        outer = []
        inner = []
        for key_o, in curs:
            outer.append(key_o)
            for key_i, in curs:
                inner.append(key_i)
        self.assertEqual(outer, ['k1'])
        self.assertEqual(inner, ['k2', 'k3'])



class TestTransactions(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestTransactions, self).setUp()
        self.create_table()

    def test_autocommit(self):
        self.assertTrue(self.db.autocommit())
        with self.db.atomic() as txn:
            self.assertFalse(self.db.autocommit())
            self.create_rows(('k1', 'v1', -10))
            with self.db.atomic() as txn:
                self.create_rows(('k2', 'v2', -20))
                txn.rollback()
            with self.db.atomic() as txn:
                self.create_rows(('k3', 'v3', -30))
                self.assertFalse(self.db.autocommit())
            self.assertFalse(self.db.autocommit())

        self.assertTrue(self.db.autocommit())
        curs = self.db.execute('select key, value, extra from kv order by key')
        self.assertEqual([row for row in curs], [
            ('k1', 'v1', -10),
            ('k3', 'v3', -30)])

    def test_manual_commit(self):
        # Manual transaction mode.
        self.db.begin()
        self.assertFalse(self.db.autocommit())
        self.create_rows(('k1', 'v1', 1))
        self.db.rollback()
        self.assertTrue(self.db.autocommit())

        self.db.begin()
        self.assertFalse(self.db.autocommit())
        self.create_rows(('k2', 'v2', 2))
        self.db.commit()
        self.assertTrue(self.db.autocommit())

        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([row for row, in curs], ['k2'])

    def test_transaction_handling(self):
        with self.db.atomic() as txn:
            self.create_rows(('k1', 'v1', 1))
            # Cannot close when txn is active.
            self.assertRaises(OperationalError, self.db.close)
            with self.db.atomic() as sp:
                self.create_rows(('k2', 'v2', 2))
                self.assertRaises(OperationalError, self.db.close)

            # Still cannot close.
            self.assertRaises(OperationalError, self.db.close)

        self.assertCount(2)
        self.assertTrue(self.db.close())

    def test_exception_rollback(self):
        # Exception in outermost (transaction) block.
        try:
            with self.db.atomic() as txn:
                self.create_rows(('k1', 'v1', 1))
                raise ValueError
        except ValueError:
            pass

        self.assertTrue(self.db.autocommit())
        self.assertCount(0)

        # Exception in inner (savepoint) block.
        with self.db.atomic() as txn:
            self.create_rows(('k1', 'v1', 1))
            try:
                with self.db.atomic() as sp:
                    self.create_rows(('k2', 'v2', 2))
                    raise ValueError
            except ValueError:
                pass
            self.assertCount(1)
            txn.rollback()

            # Transaction begins again since context still active.
            self.assertFalse(self.db.autocommit())

        self.assertTrue(self.db.autocommit())
        self.assertCount(0)

        # Except in inner (savepoint) propagates.
        try:
            with self.db.atomic() as txn:
                self.create_rows(('k1', 'v1', 1))
                with self.db.atomic() as sp:
                    self.create_rows(('k2', 'v2', 2))
                    with self.db.atomic() as sp2:
                        self.create_rows(('k3', 'v3', 3))
                        self.assertCount(3)
                        raise ValueError
        except ValueError:
            pass

        self.assertTrue(self.db.autocommit())
        self.assertCount(0)

    def test_explicit_commit(self):
        # Explicit commit and implicit rollback in outer (transaction) block.
        try:
            with self.db.atomic() as txn:
                self.create_rows(('k1', 'v1', 1))
                txn.commit()
                self.assertFalse(self.db.autocommit())  # Txn begins again.
                self.create_rows(('k2', 'v2', 2))
                raise ValueError
        except ValueError:
            pass

        self.assertTrue(self.db.autocommit())
        self.assertCount(1)
        self.assertEqual(self.db.execute('select key from kv').value(), 'k1')

        # Explicit commit and implicit rollback in inner (savepoint) block.
        with self.db.atomic() as txn:
            self.create_rows(('k2', 'v2', 2))
            try:
                with self.db.atomic() as sp:
                    self.db.execute('delete from kv')
                    self.create_rows(('k3', 'v3', 3))
                    sp.commit()
                    self.create_rows(('k4', 'v4', 4))
                    raise ValueError
            except ValueError:
                pass

        self.assertTrue(self.db.autocommit())
        self.assertCount(1)
        self.assertEqual(self.db.execute('select key from kv').value(), 'k3')

    def test_explicit_rollback(self):
        # Explicit rollback and implicit commit in outer (transaction) block.
        with self.db.atomic() as txn:
            self.create_rows(('k1', 'v1', 1))
            txn.rollback()
            self.assertFalse(self.db.autocommit())  # Txn begins again.
            self.create_rows(('k2', 'v2', 2))

        self.assertTrue(self.db.autocommit())
        self.assertCount(1)
        self.assertEqual(self.db.execute('select key from kv').value(), 'k2')

        # Explicit rollback and implicit commit in inner (savepoint) block.
        with self.db.atomic() as txn:
            self.create_rows(('k2', 'v2', 2))
            with self.db.atomic() as sp:
                self.create_rows(('k3', 'v3', 3))
                sp.rollback()
                self.db.execute('delete from kv')
                self.create_rows(('k4', 'v4', 4))

        self.assertTrue(self.db.autocommit())
        self.assertCount(1)
        self.assertEqual(self.db.execute('select key from kv').value(), 'k4')


class TestUserDefinedCallbacks(BaseTestCase):
    filename = ':memory:'
    test_data = [('k1', 'v1x', 10), ('k2', 'v2b', 20), ('k3', 'v3z', 30)]

    def setUp(self):
        super(TestUserDefinedCallbacks, self).setUp()
        self.create_table()
        self.create_rows(*self.test_data)

    def test_create_function(self):
        def reverse(s):
            if s is not None:
                return s[::-1]

        self.db.create_function(reverse, 'reverse', 1)
        curs = self.db.execute('select key, reverse(value) from kv '
                               'order by reverse(value)')
        self.assertEqual(list(curs), [
            ('k2', 'b2v'),
            ('k1', 'x1v'),
            ('k3', 'z3v')])

    def test_create_aggregate(self):
        class Sum(object):
            def __init__(self): self.value = 0
            def step(self, value): self.value += (value or 0)
            def finalize(self): return self.value

        self.db.create_aggregate(Sum, 'mysum', 1)
        curs = self.db.execute('select mysum(extra) from kv')
        self.assertEqual(curs.fetchone(), (60,))

    def test_create_window_function(self):
        class Sum(object):
            def __init__(self): self._value = 0
            def step(self, value): self._value += (value or 0)
            def inverse(self, value): self._value -= (value or 0)
            def finalize(self): return self._value
            def value(self): return self._value

        self.db.create_window_function(Sum, 'mysum', 1)

        data = (
            ('k1', '', 1), ('k1', '', 2),
            ('k2', '', 11), ('k2', '', 12),
            ('k3', '', 101), ('k3', '', 102),
            ('k4', '', 1337))
        self.create_rows(*data)

        curs = self.db.execute('select key, extra, mysum(extra) '
                               'over (partition by key) from kv '
                               'order by key, extra')
        self.assertEqual(list(curs), [
            ('k1', 1, 13), ('k1', 2, 13), ('k1', 10, 13),
            ('k2', 11, 43), ('k2', 12, 43), ('k2', 20, 43),
            ('k3', 30, 233), ('k3', 101, 233), ('k3', 102, 233),
            ('k4', 1337, 1337)])

    def test_create_collation(self):
        def case_insensitive(s1, s2):
            s1 = s1.lower()
            s2 = s2.lower()
            return (1 if s1 > s2 else (0 if s1 == s2 else -1))

        self.db.create_collation(case_insensitive, 'cic')

        data = (
            ('K1', 'V1Xx', 0), ('k4', 'V4', 0),
            ('a1', 'va1', 0), ('Z1', 'za1', 0))
        self.create_rows(*data)

        curs = self.db.execute('select key, value from kv order by '
                               'key collate cic, value collate cic')
        self.assertEqual(list(curs), [
            ('a1', 'va1'),
            ('k1', 'v1x'), ('K1', 'V1Xx'),
            ('k2', 'v2b'), ('k3', 'v3z'),
            ('k4', 'V4'), ('Z1', 'za1')])

    def test_commit_hook(self):
        state = [0]
        def on_commit():
            if not state[0]:
                raise ValueError('cancelling transaction')

        self.db.commit_hook(on_commit)
        self.db.begin()
        self.db.execute('delete from kv')
        self.assertCount(0)
        self.assertFalse(self.db.autocommit())
        try:
            self.db.commit()
        except IntegrityError as exc:
            pass

        # Transaction is closed.
        self.assertTrue(self.db.autocommit())
        self.assertCount(3)

        with self.assertRaises(OperationalError):
            with self.db.atomic():
                self.db.execute('delete from kv')
                self.assertCount(0)
        self.assertCount(3)

        state[0] = 1
        with self.db.atomic():
            self.db.execute('delete from kv')
        self.assertCount(0)

        self.assertTrue(self.db.autocommit())
        self.db.commit_hook(None)

    def test_rollback_hook(self):
        state = [0]
        def on_rollback():
            state[0] = state[0] + 1

        self.db.rollback_hook(on_rollback)
        with self.db.atomic() as txn:
            self.db.execute('delete from kv where key = ?', ('k3',))
            txn.rollback()

        self.assertKeys(['k1', 'k2', 'k3'])
        self.assertEqual(state, [1])

        # Rolling back a savepoint (but not the transaction), does not count.
        with self.db.atomic() as txn:
            self.db.execute('delete from kv where key = ?', ('k1',))
            with self.db.atomic() as sp:
                self.db.execute('delete from kv where key = ?', ('k2',))
                sp.rollback()

        self.assertKeys(['k2', 'k3'])
        self.assertEqual(state, [1])

    def test_update_hook(self):
        state = []
        def on_update(query, db, table, rowid):
            state.append((query, db, table, rowid))

        self.db.update_hook(on_update)
        self.create_rows(('k4', 'v4', 40))
        self.assertEqual(state, [('INSERT', 'main', 'kv', 4)])

        self.db.execute('update kv set extra = extra + ? where extra < ?',
                        (1, 30))
        self.db.execute('delete from kv where extra < ?', (30,))
        self.assertEqual(state, [
            ('INSERT', 'main', 'kv', 4),
            ('UPDATE', 'main', 'kv', 1),
            ('UPDATE', 'main', 'kv', 2),
            ('DELETE', 'main', 'kv', 1),
            ('DELETE', 'main', 'kv', 2)])

    def test_authorizer(self):
        ret = [AUTH_OK]
        state = []
        def authorizer(op, p1, p2, p3, p4):
            state.append((op, p1, p2, p3, p4))
            if op == 21:  # SQLITE_SELECT.
                return AUTH_OK
            if op == 20 and p2 != 'key':  # SQLITE_READ.
                return AUTH_OK
            return ret[0]
        self.db.authorizer(authorizer)

        self.db.execute('delete from kv where key = ?', ('k1',))
        self.assertEqual(state, [
            (9, 'kv', None, 'main', None),
            (20, 'kv', 'key', 'main', None)])

        ret = [AUTH_IGNORE]
        curs = self.db.execute('select key, value, extra from kv order by id')
        self.assertEqual(list(curs), [
            (None, 'v2b', 20),
            (None, 'v3z', 30)])

        ret = [AUTH_DENY]
        with self.assertRaises(OperationalError):
            self.db.execute('select * from kv')

        self.db.authorizer(None)

    def test_tracer(self):
        accum = []
        def tracer(code, sid, sql, ns):
            accum.append((code, sql))

        self.db.trace(tracer, TRACE_ROW | TRACE_STMT)
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([k for k, in curs], ['k1', 'k2', 'k3'])

        self.assertEqual(accum, [
            (1, 'select key from kv order by key'),
            (4, None), (4, None), (4, None)])

    def test_progress(self):
        accum = [0]
        def progress():
            accum[0] += 1

        for i in range(100):
            self.db.execute('insert into kv (key,value,extra) values (?,?,?)',
                            ('k%02d' % i, 'v%s' % i, i))

        self.db.progress(progress, 10)
        results = list(self.db.execute('select * from kv order by key'))
        self.assertTrue(accum[0] > 100)

    def test_exec_cb(self):
        accum = []
        def cb(row):
            accum.append(row)

        self.db.execute_simple('select key, value from kv order by key', cb)
        self.assertEqual(accum, [('k1', 'v1x'), ('k2', 'v2b'), ('k3', 'v3z')])

        self.db.execute_simple('delete from kv where extra < 30')
        del accum[:]
        self.db.execute_simple('select key, value from kv order by key', cb)
        self.assertEqual(accum, [('k3', 'v3z')])


class TestDatabaseSettings(BaseTestCase):
    filename = ':memory:'
    def setUp(self):
        super(TestDatabaseSettings, self).setUp()
        self.create_table()

    def tearDown(self):
        super(TestDatabaseSettings, self).tearDown()
        for filename in glob.glob('/tmp/cysqlite.db*'):
            os.unlink(filename)

    def test_pragmas_settings(self):
        self.db.execute('pragma foreign_keys = 1')
        self.assertEqual(self.db.get_foreign_keys_enabled(), 1)
        self.db.execute('pragma foreign_keys = 0')
        self.assertEqual(self.db.get_foreign_keys_enabled(), 0)

        self.db.set_foreign_keys_enabled(1)
        self.assertEqual(self.db.get_foreign_keys_enabled(), 1)
        self.db.set_foreign_keys_enabled(0)
        self.assertEqual(self.db.get_foreign_keys_enabled(), 0)

        for value in (1, 0, 1):
            self.db.pragma('foreign_keys', value)
            self.assertEqual(self.db.pragma('foreign_keys'), value)

    def test_table_column_metadata(self):
        self.assertEqual(self.db.table_column_metadata('kv', 'id'), (
            'kv', 'id', 'INTEGER', 'BINARY', 1, 1, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'key'), (
            'kv', 'key', 'TEXT', 'BINARY', 1, 0, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'extra'), (
            'kv', 'extra', 'INTEGER', 'BINARY', 0, 0, 0))

    def test_read_metadata(self):
        self.assertEqual(self.db.get_tables(), ['kv'])
        self.assertEqual(self.db.get_columns('kv'), [
            Column('id', 'INTEGER', False, True, 'kv', None),
            Column('key', 'TEXT', False, False, 'kv', None),
            Column('value', 'TEXT', False, False, 'kv', None),
            Column('extra', 'INTEGER', True, False, 'kv', None)])

        self.db.execute('create unique index kv_key on kv (key desc, value)')
        self.assertEqual(self.db.get_indexes('kv'), [
            Index(
                name='kv_key',
                sql='CREATE UNIQUE INDEX kv_key on kv (key desc, value)',
                columns=['key', 'value'],
                unique=True,
                table='kv')])

        self.db.execute('create table krel (id integer not null primary key, '
                        'kv_id integer not null references kv(id))')
        self.assertEqual(self.db.get_foreign_keys('kv'), [])
        self.assertEqual(self.db.get_foreign_keys('krel'), [
            ForeignKey('kv_id', 'kv', 'id', 'krel')])

    def test_database_list(self):
        self.assertEqual(self.db.database_list(), [('main', '')])

        conn = Connection('/tmp/cysqlite.db')
        conn.connect()
        self.db.attach('/tmp/cysqlite.db', 'addl')

        self.assertEqual(self.db.database_list(), [
            ('main', ''),
            ('addl', '/tmp/cysqlite.db')])

    def test_optimize(self):
        conn = Connection('/tmp/cysqlite.db', autoconnect=True)
        conn.execute('create table k (id integer not null primary key, '
                     'data text not null)')
        conn.execute('create index k_data on k(data)')
        res = conn.optimize(dry_run=True)
        self.assertEqual(list(res), [])

        conn.executemany('insert into k (data) values (?)',
                         [('k%064d' % i,) for i in range(100)])
        res = conn.optimize(dry_run=True)
        self.assertEqual(list(res), [('ANALYZE "main"."k"',)])

        self.assertEqual(list(conn.optimize()), [])

    @unittest.skipUnless(SLOW_TESTS, 'set SLOW_TESTS=1 to run')
    def test_for_leaks(self):
        conn = Connection('/tmp/cysqlite.db', autoconnect=True)
        conn.execute('create table g(k)')
        conn.executemany('insert into g(k) values (?)', [
            (None,),
            (1,),
            (2.5,),
            ('test' * 64,),
            (b'\x00\xff' * 64,),
        ])
        class Agg(object):
            def __init__(self): self._value = 0
            def step(self, value): self._value += (value or 0)
            def inverse(self, value): self._value -= (value or 0)
            def finalize(self): return self._value
            def value(self): return self._value

        for i in range(200):
            conn = Connection('/tmp/cysqlite.db', autoconnect=True)
            conn.create_function(lambda x: x, 'identity%d' % i)
            conn.create_aggregate(Agg, 'agg%d' % i)
            conn.create_window_function(Agg, 'win%d' % i)
            conn.create_collation(lambda a, b: 1, 'coll%d' % i)
            conn.commit_hook(lambda: 0)
            conn.rollback_hook(lambda: 0)
            conn.update_hook(lambda x, y, z, r: 0)
            conn.authorizer(lambda x, y, z, r, w: 0)
            conn.trace(lambda ev, sid, sql, ns: 0)
            for j in range(100):
                conn.execute('select * from g').fetchall()
            conn.close()


class TestBackup(BaseTestCase):
    filename = ':memory:'

    def test_backup(self):
        self.db.execute('create table g (k, v)')
        self.db.executemany('insert into g (k, v) values (?, ?)',
                            [('k%02d' % i, 'v%02d' % i) for i in range(100)])
        curs = self.db.cursor()
        self.assertEqual(curs.execute('select count(*) from g').value(), 100)

        new = Connection(':memory:')
        self.assertRaises(OperationalError, self.db.backup, new)

        new.connect()
        self.db.backup(new)
        self.assertEqual(new.execute('select count(*) from g').value(), 100)


class TestStatementUsage(BaseTestCase):
    def test_reuse(self):
        self.create_table()  # 1 statement.
        for i in range(10):
            self.create_rows(('k%s' % i, 'v%s' % i, i))  # 2nd curs.
            curs = self.db.execute('select * from kv where id > ?', (i,))  # 3.
            self.assertEqual(len(list(curs)), 1)

        self.assertEqual(self.db.get_stmt_usage(), (3, 0))

        curs = self.db.execute('select * from kv order by key')
        self.assertEqual(self.db.get_stmt_usage(), (3, 1))

        self.assertTrue(self.db.close())
        self.assertTrue(self.db.connect())
        self.assertEqual(self.db.get_stmt_usage(), (0, 0))

    def test_cached_statement(self):
        self.create_table()
        self.create_rows(('k1', 'v1', 1))

        curs = self.db.execute('select * from kv')
        self.assertEqual(self.db.get_stmt_usage(), (2, 1))
        self.assertEqual(list(curs), [(1, 'k1', 'v1', 1)])
        self.assertEqual(self.db.get_stmt_usage(), (3, 0))

        curs = self.db.execute('select * from kv')
        self.assertEqual(self.db.get_stmt_usage(), (2, 1))
        self.db.close()

    def test_cache_release(self):
        self.create_table()
        self.assertEqual(self.db.get_stmt_usage(), (1, 0))

        curs = self.db.execute('select count(*) from kv')
        self.assertEqual(self.db.get_stmt_usage(), (1, 1))
        self.assertEqual(curs.value(), 0)  # value() recycles curs.
        self.assertEqual(self.db.get_stmt_usage(), (2, 0))

    def test_statement_reuse(self):
        self.create_table()
        self.assertEqual(self.db.get_stmt_usage(), (1, 0))
        self.create_rows(('k1', 'v1', 1))
        self.create_rows(('k2', 'v2', 2))
        self.assertEqual(self.db.get_stmt_usage(), (2, 0))

        curs = self.db.execute('select "key" from kv order by "key"')
        self.assertEqual([row[0] for row in curs], ['k1', 'k2'])

        # The statement cache now has 3 available queries (create tbl, insert,
        # and the select query, which was fully-consumed, reset and returned to
        # the cache).
        self.assertEqual(self.db.get_stmt_usage(), (3, 0))

        # Iterating a fully-consumed cursor APIs.
        self.assertEqual([row[0] for row in curs], [])
        self.assertTrue(curs.fetchone() is None)

        # Re-executing the statement will pop it from the available list.
        curs = self.db.execute('select "key" from kv order by "key"')
        self.assertEqual(curs.fetchone(), ('k1',))
        self.assertEqual(self.db.get_stmt_usage(), (2, 1))

        # Running the same query again is fine - it will create a new in_use
        # cache entry.
        curs2 = self.db.execute('select "key" from kv order by "key"')
        self.assertEqual(curs2.fetchone(), ('k1',))
        self.assertEqual(self.db.get_stmt_usage(), (2, 2))

        # The next iteration is fine.
        self.assertEqual(curs2.fetchone(), ('k2',))
        self.assertEqual(self.db.get_stmt_usage(), (2, 2))

        # Our original statment is also fine.
        row = curs.fetchone()
        self.assertEqual(row, ('k2',))
        self.assertEqual(self.db.get_stmt_usage(), (2, 2))

        # Now our original statement is consumed - it gets reset and put back
        # in the available cache, but curs2 is still "in use".
        self.assertTrue(curs.fetchone() is None)
        self.assertEqual(self.db.get_stmt_usage(), (3, 1))

        # Now curs2 is consumed, it gets reset and put back in the cache,
        # overwriting the cached curs (since they use the same SQL).
        self.assertTrue(curs2.fetchone() is None)
        self.assertEqual(self.db.get_stmt_usage(), (3, 0))

    def test_statement_after_close(self):
        curs = self.db.execute('select 1')
        self.db.close()
        self.db.connect()
        self.assertRaises(OperationalError, lambda: next(curs))
        self.assertEqual(list(curs.execute('select 1')), [(1,)])

    def test_statement_too_much(self):
        with self.assertRaises(ProgrammingError):
            curs = self.db.execute('select 1; -- test')

        self.assertEqual(list(self.db.execute('select 1; ')), [(1,)])
        self.assertEqual(list(self.db.execute('select 1;;;; ;')), [(1,)])

    def test_broken_sql(self):
        self.assertRaises(OperationalError, self.db.execute, 'select')
        self.assertRaises(OperationalError, self.db.execute, 'bad query')
        self.assertEqual(self.db.get_stmt_usage(), (0, 0))

    def test_evil_stmt(self):
        self.db.execute('create table g (k)')
        self.db.executemany('insert into g (k) values (?)',
                            [('k1',), ('k2',), ('k3',)])

        curs = self.db.execute('select * from g')
        curs.fetchone()

        def evil(val):
            res = curs.fetchone()
            return res[0] if res else None

        self.db.create_function(evil, 'evil')
        curs2 = self.db.execute('select evil(k) from g')
        self.assertEqual(list(curs2), [('k2',), ('k3',), (None,)])


class TestBlob(BaseTestCase):
    def setUp(self):
        super(TestBlob, self).setUp()
        self.db.execute('CREATE TABLE register ('
                        'id INTEGER NOT NULL PRIMARY KEY, '
                        'data BLOB NOT NULL)')

    def create_blob_row(self, nbytes):
        self.db.execute('INSERT INTO register (data) VALUES (zeroblob(?))',
                        (nbytes,))
        return self.db.last_insert_rowid()

    def test_blob(self):
        rowid1024 = self.create_blob_row(1024)
        rowid16 = self.create_blob_row(16)

        blob = Blob(self.db, 'register', 'data', rowid1024)
        self.assertEqual(len(blob), 1024)

        blob.write(b'x' * 1022)
        blob.write(b'zz')
        blob.seek(1020)
        self.assertEqual(blob.tell(), 1020)

        data = blob.read(3)
        self.assertEqual(data, b'xxz')
        self.assertEqual(blob.read(), b'z')
        self.assertEqual(blob.read(), b'')

        blob.seek(-10, 2)
        self.assertEqual(blob.tell(), 1014)
        self.assertEqual(blob.read(), b'xxxxxxxxzz')

        blob.reopen(rowid16)
        self.assertEqual(blob.tell(), 0)
        self.assertEqual(len(blob), 16)

        blob.write(b'x' * 15)
        self.assertEqual(blob.tell(), 15)

    def test_blob_exceed_size(self):
        rowid = self.create_blob_row(16)

        blob = self.db.blob_open('register', 'data', rowid)
        with self.assertRaises(ValueError):
            blob.seek(17, 0)

        with self.assertRaises(ValueError):
            blob.write(b'x' * 17)

        blob.write(b'x' * 16)
        self.assertEqual(blob.tell(), 16)
        blob.seek(0)
        data = blob.read(17)  # Attempting to read more data is OK.
        self.assertEqual(data, b'x' * 16)
        blob.close()

    def test_blob_errors_opening(self):
        rowid = self.create_blob_row(4)

        with self.assertRaises(OperationalError):
            blob = self.db.blob_open('register', 'data', rowid + 1)

        with self.assertRaises(OperationalError):
            blob = self.db.blob_open('register', 'missing', rowid)

        with self.assertRaises(OperationalError):
            blob = self.db.blob_open('missing', 'data', rowid)

    def test_blob_operating_on_closed(self):
        rowid = self.create_blob_row(4)
        blob = self.db.blob_open('register', 'data', rowid)
        self.assertEqual(len(blob), 4)
        blob.close()

        with self.assertRaises(OperationalError):
            len(blob)

        self.assertRaises(OperationalError, blob.read)
        self.assertRaises(OperationalError, blob.write, b'foo')
        self.assertRaises(OperationalError, blob.seek, 0, 0)
        self.assertRaises(OperationalError, blob.tell)
        self.assertRaises(OperationalError, blob.reopen, rowid)

    def test_blob_db_closed(self):
        rowid = self.create_blob_row(4)
        blob = self.db.blob_open('register', 'data', rowid)

        self.db.close()

        for i in range(2):
            if i == 1: self.db.connect()  # Reconnect for 2nd iteration.
            # Cannot operate on the blob - db was closed, even if it was
            # reopened later the handle is invalid.
            self.assertRaises(OperationalError, blob.read)
            self.assertRaises(OperationalError, blob.write, b'foo')
            self.assertRaises(OperationalError, blob.seek, 0, 0)
            self.assertRaises(OperationalError, blob.tell)
            self.assertRaises(OperationalError, blob.reopen, rowid)

    def test_blob_readonly(self):
        rowid = self.create_blob_row(4)
        blob = self.db.blob_open('register', 'data', rowid)
        blob.write(b'huey')
        blob.seek(0)
        self.assertEqual(blob.read(), b'huey')
        blob.close()

        blob = self.db.blob_open('register', 'data', rowid, True)
        self.assertEqual(blob.read(), b'huey')
        blob.seek(0)
        with self.assertRaises(OperationalError):
            blob.write(b'meow')

        # BLOB is read-only.
        self.assertEqual(blob.read(), b'huey')


class TestThreading(BaseTestCase):
    def setUp(self):
        super(TestThreading, self).setUp()
        self.create_table()
        self.create_rows(('k1', 'v1', 1),
                         ('k2', 'v2', 2),
                         ('k3', 'v3', 3))
        self.threads = 8

    def get_connection(self, **kwargs):
        conn = Connection(self.filename, **kwargs)
        conn.connect()
        conn.pragma('journal_mode', 'wal')
        return conn

    def run_concurrent(self, fn, *args):
        threads = [threading.Thread(target=fn, args=args)
                   for _ in range(self.threads)]
        for t in threads: t.start()
        for t in threads: t.join()

    def test_share_connection(self):
        def work():
            for i in range(10):
                self.assertCount(3)
                self.assertKeys(['k1', 'k2', 'k3'])

        self.run_concurrent(work)

    def test_share_cursor(self):
        lock = threading.Lock()

        def work(cursor):
            for i in range(10):
                # Prevent another thread stepping the cursor. We just want to
                # test that a cursor can be shared, not the behavior of
                # multiple threads stepping/overwriting the stmt.
                with lock:
                    accum = [row[0] for row in
                             cursor.execute('select key from kv order by key')]
                    self.assertEqual(accum, ['k1', 'k2', 'k3'])

        cursor = self.db.cursor()
        self.run_concurrent(work, cursor)

    def test_busy_wait(self):
        def work():
            self.create_rows(('k', 'v', 1))

        def work_txn():
            with self.db.atomic('exclusive'):
                self.create_rows(('k', 'v', 1))

        self.run_concurrent(work)
        self.assertCount(self.threads + 3)

        self.run_concurrent(work)
        self.assertCount(self.threads + self.threads + 3)

#
# Helpers, addons, etc.
#

class DataTypes(TableFunction):
    columns = ('key', 'value')
    params = ()
    name = 'data_types'

    def initialize(self):
        self.values = VAL_TESTS + [v[0] for v in VAL_CONVERSION_TESTS]
        self.idx = 0
        self.n = len(self.values)

    def iterate(self, idx):
        if idx < self.n:
            return ('k%02d' % idx, self.values[idx])
        raise StopIteration


class TestDataTypesTableFunction(BaseTestCase):
    def test_data_types_table_function(self):
        DataTypes.register(self.db)
        curs = self.db.execute('SELECT value FROM data_types() '
                               'ORDER BY key')
        expected = VAL_TESTS + [v[1] for v in VAL_CONVERSION_TESTS]
        self.assertEqual([r for r, in curs], expected)


class Series(TableFunction):
    columns = ['value']
    params = ['start', 'stop', 'step']
    name = 'series'

    def initialize(self, start=0, stop=None, step=1):
        self.start = start
        self.stop = stop or float('inf')
        self.step = step
        self.curr = self.start

    def iterate(self, idx):
        if self.curr > self.stop:
            raise StopIteration

        ret = self.curr
        self.curr += self.step
        return (ret,)

class RegexSearch(TableFunction):
    columns = ['match']
    params = ['regex', 'search_string']
    name = 'regex_search'

    def initialize(self, regex=None, search_string=None):
        if regex and search_string:
            self._iter = re.finditer(regex, search_string)
        else:
            self._iter = None

    def iterate(self, idx):
        # We do not need `idx`, so just ignore it.
        if self._iter is None:
            raise StopIteration
        else:
            return (next(self._iter).group(0),)

class Split(TableFunction):
    params = ['data']
    columns = ['part']
    name = 'str_split'

    def initialize(self, data=None):
        self._parts = data.split()
        self._idx = 0

    def iterate(self, idx):
        if self._idx < len(self._parts):
            result = (self._parts[self._idx],)
            self._idx += 1
            return result
        raise StopIteration


class TestTableFunction(BaseTestCase):
    def execute(self, sql, params=None):
        return self.db.execute(sql, params or ())

    def test_split(self):
        Split.register(self.db)
        curs = self.execute('select part from str_split(?) order by part '
                            'limit 3', ('well hello huey and zaizee',))
        self.assertEqual([row for row, in curs],
                         ['and', 'hello', 'huey'])

    def test_split_tbl(self):
        Split.register(self.db)
        self.execute('create table post (content TEXT);')
        self.execute('insert into post (content) values (?), (?), (?)',
                     ('huey secret post',
                      'mickey message',
                      'zaizee diary'))
        curs = self.execute('SELECT * FROM post, str_split(post.content)')
        self.assertEqual(list(curs), [
            ('huey secret post', 'huey'),
            ('huey secret post', 'secret'),
            ('huey secret post', 'post'),
            ('mickey message', 'mickey'),
            ('mickey message', 'message'),
            ('zaizee diary', 'zaizee'),
            ('zaizee diary', 'diary'),
        ])

    def test_series(self):
        Series.register(self.db)

        def assertSeries(params, values, extra_sql=''):
            param_sql = ', '.join('?' * len(params))
            sql = 'SELECT * FROM series(%s)' % param_sql
            if extra_sql:
                sql = ' '.join((sql, extra_sql))
            curs = self.execute(sql, params)
            self.assertEqual([row for row, in curs], values)

        assertSeries((0, 10, 2), [0, 2, 4, 6, 8, 10])
        assertSeries((5, None, 20), [5, 25, 45, 65, 85], 'LIMIT 5')
        assertSeries((4, 0, -1), [4, 3, 2], 'LIMIT 3')
        assertSeries((3, 5, 3), [3])
        assertSeries((3, 3, 1), [3])

    def test_series_tbl(self):
        Series.register(self.db)
        self.execute('CREATE TABLE nums (id INTEGER PRIMARY KEY)')
        self.execute('INSERT INTO nums DEFAULT VALUES;')
        self.execute('INSERT INTO nums DEFAULT VALUES;')
        curs = self.execute('SELECT * FROM nums, series(nums.id, nums.id + 2)')
        self.assertEqual(list(curs), [
            (1, 1), (1, 2), (1, 3),
            (2, 2), (2, 3), (2, 4)])

        curs = self.execute('SELECT * FROM nums, series(nums.id) LIMIT 3')
        self.assertEqual(list(curs), [(1, 1), (1, 2), (1, 3)])

    def test_regex(self):
        RegexSearch.register(self.db)

        def assertResults(regex, search_string, values):
            sql = 'SELECT * FROM regex_search(?, ?)'
            curs = self.execute(sql, (regex, search_string))
            self.assertEqual([row for row, in curs], values)

        assertResults(
            r'[0-9]+',
            'foo 123 45 bar 678 nuggie 9.0',
            ['123', '45', '678', '9', '0'])
        assertResults(
            r'[\w]+@[\w]+\.[\w]{2,3}',
            ('Dear charlie@example.com, this is nug@baz.com. I am writing on '
             'behalf of zaizee@foo.io. He dislikes your blog.'),
            ['charlie@example.com', 'nug@baz.com', 'zaizee@foo.io'])
        assertResults(
            r'[a-z]+',
            '123.pDDFeewXee',
            ['p', 'eew', 'ee'])
        assertResults(
            r'[0-9]+',
            'hello',
            [])

    def test_regex_tbl(self):
        messages = (
            'hello foo@example.fap, this is nuggie@example.fap. How are you?',
            'baz@example.com wishes to let charlie@crappyblog.com know that '
            'huey@example.com hates his blog',
            'testing no emails.',
            '')
        RegexSearch.register(self.db)

        self.execute('create table posts (id integer primary key, msg)')
        self.execute('insert into posts (msg) values (?), (?), (?), (?)',
                     messages)
        curs = self.execute('select posts.id, regex_search.rowid, '
                            'regex_search.match '
                            'FROM posts, regex_search(?, posts.msg)',
                            (r'[\w]+@[\w]+\.\w{2,3}',))
        self.assertEqual(list(curs), [
            (1, 1, 'foo@example.fap'),
            (1, 2, 'nuggie@example.fap'),
            (2, 3, 'baz@example.com'),
            (2, 4, 'charlie@crappyblog.com'),
            (2, 5, 'huey@example.com'),
        ])

    def test_error_instantiate(self):
        class BrokenInstantiate(Series):
            name = 'broken_instantiate'
            print_tracebacks = False

            def __init__(self, *args, **kwargs):
                super(BrokenInstantiate, self).__init__(*args, **kwargs)
                raise ValueError('broken instantiate')

        BrokenInstantiate.register(self.db)
        self.assertRaises(OperationalError, self.execute,
                          'SELECT * FROM broken_instantiate(1, 10)')

    def test_error_init(self):
        class BrokenInit(Series):
            name = 'broken_init'
            print_tracebacks = False

            def initialize(self, start=0, stop=None, step=1):
                raise ValueError('broken init')

        BrokenInit.register(self.db)
        self.assertRaises(OperationalError, self.execute,
                          'SELECT * FROM broken_init(1, 10)')
        self.assertRaises(OperationalError, self.execute,
                          'SELECT * FROM broken_init(0, 1)')

    def test_error_iterate(self):
        class BrokenIterate(Series):
            name = 'broken_iterate'
            print_tracebacks = False

            def iterate(self, idx):
                raise ValueError('broken iterate')

        BrokenIterate.register(self.db)
        self.assertRaises(OperationalError, self.execute,
                          'SELECT * FROM broken_iterate(1, 10)')
        self.assertRaises(OperationalError, self.execute,
                          'SELECT * FROM broken_iterate(0, 1)')

    def test_error_iterate_delayed(self):
        # Only raises an exception if the value 7 comes up.
        class SomewhatBroken(Series):
            name = 'somewhat_broken'
            print_tracebacks = False

            def iterate(self, idx):
                ret = super(SomewhatBroken, self).iterate(idx)
                if ret == (7,):
                    raise ValueError('somewhat broken')
                else:
                    return ret

        SomewhatBroken.register(self.db)
        curs = self.execute('SELECT * FROM somewhat_broken(0, 3)')
        self.assertEqual(list(curs), [(0,), (1,), (2,), (3,)])

        curs = self.execute('SELECT * FROM somewhat_broken(5, 8)')
        self.assertEqual(curs.fetchone(), (5,))
        self.assertRaises(OperationalError, lambda: list(curs))

        curs = self.execute('SELECT * FROM somewhat_broken(0, 2)')
        self.assertEqual(list(curs), [(0,), (1,), (2,)])


class TestRankUDFs(BaseTestCase):
    filename = ':memory:'
    test_data = (
        ('A faith is a necessity to a man. Woe to him who believes in '
         'nothing.'),
        ('All who call on God in true faith, earnestly from the heart, will '
         'certainly be heard, and will receive what they have asked and '
         'desired.'),
        ('Be faithful in small things because it is in them that your '
         'strength lies.'),
        ('Faith consists in believing when it is beyond the power of reason '
         'to believe.'),
        ('Faith has to do with things that are not seen and hope with things '
         'that are not at hand.'))

    def setUp(self):
        super(TestRankUDFs, self).setUp()
        self.db.execute('create virtual table search using fts4 (content, '
                        'prefix=\'2,3\', tokenize="porter")')
        for i, s in enumerate(self.test_data):
            self.db.execute('insert into search (docid, content) values (?,?)',
                            (i + 1, s))
        self.db.create_function(rank_bm25, 'rank_bm25')
        self.db.create_function(rank_lucene, 'rank_lucene')

    def assertSearch(self, q, expected, fn='rank_bm25'):
        curs = self.db.execute('select docid, '
                               '%s(matchinfo(search, ?), 1) AS r '
                               'from search where search match ? '
                               'order by r' % fn, ('pcnalx', q))
        results = [(docid, round(score, 3)) for docid, score in curs]
        self.assertEqual(results, expected)

    def test_scoring(self):
        self.assertSearch('things', [(5, -0.448), (3, -0.363)])
        self.assertSearch('believe', [(4, -0.487), (1, -0.353)])
        self.assertSearch('god faith', [(2, -0.921)])
        self.assertSearch('"it is"', [(3, -0.363), (4, -0.363)])

        self.assertSearch('things', [(5, -0.166), (3, -0.137)], 'rank_lucene')
        self.assertSearch('believe', [(4, -0.193), (1, -0.132)], 'rank_lucene')
        self.assertSearch('god faith', [(2, -0.147)], 'rank_lucene')
        self.assertSearch('"it is"', [(3, -0.137), (4, -0.137)], 'rank_lucene')
        self.assertSearch('faith', [
            (2, 0.036), (5, 0.042), (1, 0.047), (3, 0.049), (4, 0.049)],
            'rank_lucene')


class TestStringDistanceUDFs(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestStringDistanceUDFs, self).setUp()
        self.db.create_function(levenshtein_dist, 'levdist')
        self.db.create_function(damerau_levenshtein_dist, 'dlevdist')

    def _assertLev(self, f, s1, s2, n):
        curs = self.db.execute('select %s(?, ?)' % f, (s1, s2))
        score, = next(curs)
        self.assertEqual(score, n, '(%s, %s) %s != %s' % (s1, s2, n, score))

    def assertLev(self, s1, s2, n):
        self._assertLev('levdist', s1, s2, n)

    def assertDLev(self, s1, s2, n):
        self._assertLev('dlevdist', s1, s2, n)

    def test_levdist(self):
        cases = (
            ('abc', 'abc', 0),
            ('abc', 'abcd', 1),
            ('abc', 'acb', 2),
            ('aabc', 'acab', 2),
            ('abc', 'cba', 2),
            ('abc', 'bca', 2),
            ('abc', 'def', 3),
            ('abc', '', 3),
            ('abc', 'deabcfg', 4),
        )
        for s1, s2, n in cases:
            self.assertLev(s1, s2, n)
            self.assertLev(s2, s1, n)

    def test_dlevdist(self):
        cases = (
            ('abc', 'abc', 0),
            ('abc', 'abcd', 1),
            ('abc', 'acb', 1),  # Transpositions.
            ('aabc', 'acab', 2),
            ('abc', 'cba', 2),
            ('abc', 'bca', 2),
            ('abc', 'def', 3),
            ('abc', '', 3),
            ('abc', 'deabcfg', 4),
            ('abced', 'abcde', 1),  # Adjacent transposition.
            ('abcde', 'abdec', 2),
        )
        for s1, s2, n in cases:
            self.assertDLev(s1, s2, n)
            self.assertDLev(s2, s1, n)


class TestMedianUDF(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestMedianUDF, self).setUp()
        self.db.execute('create table g(id integer not null primary key, '
                        'x not null, k)')
        self.db.create_aggregate(median, 'median', 1)
        self.db.create_window_function(median, 'median', 1)

    def store(self, *values):
        self.db.execute('delete from g')
        expr = ', '.join('(?)' for _ in values)
        self.db.execute('insert into g(x) values %s' % expr, values)

    def assertMedian(self, expected):
        row = self.db.execute_one('select median(x) from g')
        self.assertEqual(row[0], expected)

    def test_median_aggregate(self):
        self.assertMedian(None)
        self.store(1)
        self.assertMedian(1)
        self.store(3, 1, 6, 6, 6, 7, 7, 7, 7, 12, 12, 17)
        self.assertMedian(7)
        self.store(9, 2, 2, 3, 3, 1)
        self.assertMedian(3)
        self.store(4, 4, 1, 8, 2, 2, 5, 8, 1)
        self.assertMedian(4)
        self.store(1, 10000, 10)
        self.assertMedian(10)

    def storek(self, data):
        self.db.execute('delete from g')
        expr = []
        values = []
        for key, vals in data.items():
            for val in vals:
                expr.append('(?, ?)')
                values.extend((key, val))

        self.db.execute('insert into g(k, x) values %s' % ', '.join(expr),
                        values)

    def assertMedianW(self, expected):
        curs = self.db.execute('select k, x, median(x) over (partition by k) '
                               'from g order by k, id')
        self.assertEqual(list(curs), expected)

    def test_median_window(self):
        self.assertMedianW([])
        self.storek({'k1': [1]})
        self.assertMedianW([('k1', 1, 1)])

        self.storek({
            'k1': [3, 6, 6, 7, 7, 7, 17],
            'k2': [9, 2, 3, 1],
            'k3': [4, 4, 8, 2, 2, 8, 1],
            'k4': [1, 10000, 10]})
        self.assertMedianW([
            ('k1', 3, 7), ('k1', 6, 7), ('k1', 6, 7), ('k1', 7, 7),
            ('k1', 7, 7), ('k1', 7, 7), ('k1', 17, 7),
            ('k2', 9, 3), ('k2', 2, 3), ('k2', 3, 3), ('k2', 1, 3),
            ('k3', 4, 4), ('k3', 4, 4), ('k3', 8, 4), ('k3', 2, 4),
            ('k3', 2, 4), ('k3', 8, 4), ('k3', 1, 4),
            ('k4', 1, 10), ('k4', 10000, 10), ('k4', 10, 10)])


if __name__ == '__main__':
    unittest.main(argv=sys.argv)
