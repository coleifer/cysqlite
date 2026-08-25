import asyncio
import ctypes
import datetime
import decimal
import gc
import glob
import io
import json
import os
import re
import sys
import threading
import time
import unittest
import uuid
import weakref
from decimal import Decimal
from fractions import Fraction

from cysqlite import *
from cysqlite._cysqlite import Cursor, HAS_DESERIALIZE, HAS_LOAD_EXTENSION
from cysqlite.metadata import Column, ForeignKey, Index


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
    (datetime.datetime(1, 1, 1, 0, 0, 0), '0001-01-01 00:00:00'),
    (datetime.datetime(9999, 12, 31, 23, 59, 59), '9999-12-31 23:59:59'),
    (Decimal('1.23'), 1.23),
    (Fraction(3, 5), 0.6),
    (_mv, bytes(_buf[1:])),
    (_buf, bytes(_buf)),
    (_u, str(_u)),
]


class BaseTestCase(unittest.TestCase):
    filename = '/tmp/cysqlite.db'

    def setUp(self):
        self.db = self.get_connection()
        self.db.connect()

    def tearDown(self):
        if not self.db.is_closed():
            self.db.close()
        self.cleanup()

    def cleanup(self):
        if self.filename != ':memory:':
            for filename in glob.glob(self.filename.replace('.db', '*')):
                if os.path.isfile(filename):
                    os.unlink(filename)

    def get_connection(self, **kwargs):
        return Connection(self.filename, **kwargs)

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
        self.assertEqual(curs.scalar(), n)

    def assertKeys(self, expected):
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([k for k, in curs], expected)

    def assertCallbackError(self, msg, exc_type=None):
        exc = self.db.callback_error
        self.assertTrue(exc is not None)
        if exc_type is not None:
            self.assertTrue(isinstance(exc, exc_type))
        self.assertIn(msg, exc.args[0])

    def assertCausedBy(self, exc, msg, exc_type):
        cause = exc.__cause__
        self.assertIsNotNone(cause, 'expected __cause__, got None')
        self.assertIsInstance(cause, exc_type)
        self.assertIn(msg, cause.args[0])


class TestModule(BaseTestCase):
    def test_module_constants(self):
        import cysqlite
        self.assertEqual(cysqlite.apilevel, '2.0')
        self.assertEqual(cysqlite.paramstyle, 'qmark')
        self.assertTrue(cysqlite.threadsafety in (0, 1, 3))
        self.assertTrue(isinstance(cysqlite.version, str))
        self.assertTrue(isinstance(cysqlite.version_info, tuple))
        self.assertTrue(isinstance(cysqlite.sqlite_version, str))
        self.assertTrue(isinstance(cysqlite.sqlite_version_info, tuple))
        self.assertEqual(cysqlite.SQLITE_OK, 0)
        self.assertEqual(cysqlite.SQLITE_ERROR, 1)

    def test_compile_option(self):
        result = compile_option('threadsafe')
        self.assertIn(result, (0, 1))

        result = compile_option('this_option_does_not_exist')
        self.assertEqual(result, 0)

    def test_complete_statement(self):
        cases = (
            ('select 1', False),
            ('select 1;', True),
            ('select;', True),
            ('select * from;', True),
            ('select * from t', False),
            ('select * from t;', True),
        )
        for sql, expected in cases:
            self.assertEqual(complete_statement(sql), expected, sql)

    def test_vfs_list(self):
        import cysqlite
        vfs_names = cysqlite.vfs_list()
        self.assertTrue(isinstance(vfs_names, list))
        self.assertTrue(len(vfs_names) >= 1)


class TestConnection(BaseTestCase):
    def assertDB(self, filename, expected):
        # SQLite reports the resolved path, e.g. /private/tmp on macos.
        if expected:
            expected = os.path.realpath(expected)
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

    def test_connect(self):
        db = connect(':memory:')
        self.assertIsInstance(db, Connection)
        db.close()

        db = connect(':memory:', row_factory=Row, timeout=10.0)
        self.assertEqual(db.row_factory, Row)
        self.assertEqual(db.timeout, 10.0)
        db.close()

        db = connect(':memory:', pragmas={'cache_size': -1000})
        self.assertEqual(db.pragma('cache_size'), -1000)
        db.close()

    def test_journal_mode(self):
        path = '/tmp/cysqlite-jm-test.db'
        for filename in glob.glob(path + '*'):
            os.unlink(filename)
        try:
            db = connect(path, journal_mode='wal')
            self.assertEqual(db.pragma('journal_mode'), 'wal')
            db.close()

            db = connect(path, journal_mode='wal')
            self.assertEqual(db.pragma('journal_mode'), 'wal')
            db.close()

            # An explicit pragma entry wins over the journal_mode shorthand.
            db = connect(path, journal_mode='wal',
                         pragmas={'journal_mode': 'delete'})
            self.assertEqual(db.pragma('journal_mode'), 'delete')
            db.close()

            # The caller's pragmas dict must not be mutated.
            user_pragmas = {'cache_size': -500}
            db = connect(path, journal_mode='wal', pragmas=user_pragmas)
            self.assertEqual(db.pragma('journal_mode'), 'wal')
            self.assertEqual(user_pragmas, {'cache_size': -500})
            db.close()
        finally:
            for filename in glob.glob(path + '*'):
                os.unlink(filename)

    def test_open_close(self):
        db = Connection(':memory:', autoconnect=False)
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

        with self.assertRaises(ValueError):
            with db:
                self.assertFalse(db.is_closed())
                raise ValueError('fail')
        self.assertTrue(db.is_closed())

    def test_error_closing(self):
        db = Connection(':memory:')
        with self.assertRaises(ValueError):
            with db:
                with db.atomic() as txn:
                    raise ValueError('fail')

        self.assertTrue(db.is_closed())

        with self.assertRaises(ValueError) as ctx:
            with db:
                txn = db.transaction()
                txn.__enter__()  # This will cause close() to fail.
                raise ValueError('fail2')

            # Close failed.
            self.assertFalse(db.is_closed())
            txn.__exit__(None, None, None)
            self.assertTrue(db.close())

    def test_in_transaction_on_closed_connection(self):
        db = Connection(':memory:', autoconnect=False)
        self.assertFalse(db.in_transaction)
        db.connect()
        self.assertFalse(db.in_transaction)
        db.begin()
        self.assertTrue(db.in_transaction)
        db.close(force=True)
        self.assertFalse(db.in_transaction)

    def test_force_close(self):
        db = Connection(self.filename)
        db.execute('create table g(k)')
        txn = db.transaction()
        txn.__enter__()
        db.execute('insert into g(k) values (?)', (1,))
        self.assertTrue(db.close(force=True))
        self.assertTrue(db.is_closed())

        with db:
            with db.atomic():
                count = db.execute('select count(*) from g').scalar()
                self.assertEqual(count, 0)

    def test_force_close_within_atomic(self):
        db = Connection(self.filename)
        db.execute('create table g(k)')

        with db:
            with db.atomic() as txn:
                db.execute('insert into g(k) values (?)', (1,))
                self.assertTrue(db.close(force=True))

        self.assertTrue(db.is_closed())

        with db:
            with db.atomic() as txn:
                with db.atomic() as sp:
                    with db.atomic() as sp2:
                        db.execute('insert into g(k) values (?)', (2,))
                        db.close(force=True)

        self.assertTrue(db.is_closed())

        with db:
            with db.atomic():
                count = db.execute('select count(*) from g').scalar()
                self.assertEqual(count, 0)

    def test_limit(self):
        db = Connection(':memory:')
        limit = db.getlimit(SQLITE_LIMIT_LENGTH)
        self.assertTrue(limit > 0)

        db.setlimit(SQLITE_LIMIT_LENGTH, limit - 1)

        limit2 = db.getlimit(SQLITE_LIMIT_LENGTH)
        self.assertEqual(limit2, limit - 1)

        orig = self.db.setlimit(SQLITE_LIMIT_SQL_LENGTH, 200)
        self.assertIsInstance(orig, int)
        current = self.db.getlimit(SQLITE_LIMIT_SQL_LENGTH)
        self.assertEqual(current, 200)
        self.db.setlimit(SQLITE_LIMIT_SQL_LENGTH, orig)

    def test_db_config(self):
        db = Connection(':memory:')
        db.set_foreign_keys_enabled(True)
        self.assertTrue(db.get_foreign_keys_enabled())

        db.set_foreign_keys_enabled(False)
        self.assertFalse(db.get_foreign_keys_enabled())

        self.assertEqual(db.db_config(SQLITE_DBCONFIG_ENABLE_FKEY, -1), 0)
        self.assertEqual(db.db_config(SQLITE_DBCONFIG_ENABLE_FKEY, 1), 1)
        self.assertTrue(db.get_foreign_keys_enabled())

        self.db.set_triggers_enabled(1)
        self.assertEqual(self.db.get_triggers_enabled(), 1)

        self.db.set_triggers_enabled(0)
        self.assertEqual(self.db.get_triggers_enabled(), 0)

    def test_status(self):
        self.db.execute('create table g (k)')
        current, _ = self.db.status(SQLITE_DBSTATUS_CACHE_USED)
        self.assertGreater(current, 0)

        current, _ = self.db.status(SQLITE_DBSTATUS_SCHEMA_USED)
        self.assertGreater(current, 0)

        current, _ = self.db.status(SQLITE_DBSTATUS_STMT_USED)
        self.assertGreater(current, 0)

        current, _ = self.db.status(SQLITE_DBSTATUS_LOOKASIDE_USED)
        self.assertTrue(current >= 0)

        current, _ = status(SQLITE_STATUS_MEMORY_USED)
        self.assertTrue(current >= 0)

        current, _ = status(SQLITE_STATUS_MALLOC_COUNT)
        self.assertTrue(current >= 0)

        current, _ = status(SQLITE_STATUS_PAGECACHE_USED)
        self.assertTrue(current >= 0)

    def test_set_main_db_name(self):
        self.db.set_main_db_name('app')
        dbs = self.db.database_list()
        self.assertEqual(dbs[0][0], 'app')

        self.db.set_main_db_name('main')
        dbs = self.db.database_list()
        self.assertEqual(dbs[0][0], 'main')

    def test_set_main_db_name_ptr(self):
        import gc
        self.db.set_main_db_name('app')
        gc.collect()

        dbs = self.db.database_list()
        self.assertEqual(dbs[0][0], 'app')

    def test_file_control(self):
        result = self.db.file_control(SQLITE_FCNTL_DATA_VERSION, 0)
        self.assertTrue(result >= 0)

    def test_shared_cache(self):
        self.assertEqual(self.db.set_shared_cache(1), 1)
        self.assertEqual(self.db.set_shared_cache(0), 0)

    def test_busy_handler(self):
        self.create_table()
        self.create_rows(('k1', 'v1', 1))

        self.db.set_busy_handler(timeout=5.0)
        self.assertCount(1)

        self.db.set_busy_handler(timeout=1.0)
        self.assertEqual(self.db.timeout, 1.0)

        self.create_rows(('k2', 'v2', 2))
        self.assertCount(2)

    @unittest.skipUnless(SLOW_TESTS, 'set SLOW_TESTS=1 to run')
    def test_busy_handler_contention(self):
        self.db.pragma('journal_mode', 'wal')
        self.db.set_busy_handler(timeout=5.0)
        self.create_table()

        errors = []
        nthreads = 4
        nrows = 50

        def writer(n):
            try:
                conn = self.get_connection()
                conn.set_busy_handler(timeout=5.0)
                for i in range(nrows):
                    with conn.atomic():
                        conn.execute('insert into kv (key, value, extra) '
                                     'values (?, ?, ?)',
                                     (f't{n}_k{i}', 'v', i))
                conn.close()
            except Exception as exc:
                errors.append(exc)

        threads = [threading.Thread(target=writer, args=(n,))
                   for n in range(nthreads)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        self.assertEqual(errors, [], f'Errors during contention: {errors}')
        count = self.db.execute('select count(*) from kv').scalar()
        self.assertEqual(count, nthreads * nrows)

    def test_attach_detach(self):
        path = '/tmp/cysqlite-attach.db'
        other = Connection(path)
        other.execute('create table t (x)')
        other.close()

        self.db.attach(path, 'extra')
        dbs = self.db.database_list()
        names = [d[0] for d in dbs]
        self.assertIn('extra', names)

        self.db.detach('extra')
        dbs = self.db.database_list()
        names = [d[0] for d in dbs]
        self.assertNotIn('extra', names)

        self.db.attach(path, 'ex"tra')
        dbs = self.db.database_list()
        names = [d[0] for d in dbs]
        self.assertIn('ex"tra', names)

        self.db.detach('ex"tra')
        dbs = self.db.database_list()
        names = [d[0] for d in dbs]
        self.assertNotIn('ex"tra', names)

    def test_checkpoint(self):
        self.db.pragma('journal_mode', 'wal')
        self.create_table()
        self.create_rows(('k1', 'v1', 1))

        for kw in ({}, {'full': True}, {'truncate': True}, {'restart': True}):
            pnlog, pnckpt = self.db.checkpoint(**kw)
            self.assertTrue(isinstance(pnlog, int))
            self.assertTrue(isinstance(pnckpt, int))

        self.db.set_autocheckpoint(10)
        self.create_rows(('k2', 'v2', 2))
        self.db.set_autocheckpoint(0)

    def test_optimize(self):
        self.db.execute('create table g(k)')
        self.db.execute('create index i on g(k)')
        self.db.executemany('insert into g(k) values (?)',
                            [(i,) for i in range(100)])

        self.db.optimize(dry_run=True).fetchall()
        self.db.optimize().fetchall()


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
        self.assertRaises(OperationalError, self.db.executescript, 'select 1')
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
        for _ in range(2):
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
        self.assertEqual(self.db.get_stmt_usage(), (2, 1))

        # If execute is called before cursor is consumed, it will reset.
        self.assertEqual(curs.execute('select 1').fetchone(), (1,))
        self.assertEqual(self.db.get_stmt_usage(), (3, 1))

        self.assertEqual(curs.execute('select 2').fetchone(), (2,))
        self.assertEqual(self.db.get_stmt_usage(), (4, 1))

        # We can close and re-execute.
        curs.close()

        self.assertEqual(curs.execute('select 1').scalar(), 1)
        self.assertEqual(self.db.get_stmt_usage(), (5, 0))

        self.assertEqual(curs.execute('select 2').scalar(), 2)
        self.assertEqual(self.db.get_stmt_usage(), (5, 0))


class TestExecute(BaseTestCase):
    filename = ':memory:'

    def test_fetch_rows(self):
        self.db.execute('create table g (k)')

        curs = self.db.execute('select * from g')
        self.assertIsNone(curs.fetchone())

        curs = self.db.execute('select * from g')
        self.assertEqual(curs.fetchmany(10), [])
        self.assertEqual(curs.fetchmany(0), [])

        curs = self.db.execute('select * from g')
        self.assertEqual(curs.fetchall(), [])

        self.db.executemany('insert into g (k) values (?)',
                            [(f'k{i:02d}',) for i in range(10)])

        curs = self.db.execute('select * from g order by k')
        self.assertEqual(curs.fetchone(), ('k00',))
        self.assertEqual(curs.fetchmany(4),
                         [('k01',), ('k02',), ('k03',), ('k04',)])
        self.assertEqual(curs.fetchmany(2), [('k05',), ('k06',)])
        self.assertEqual(curs.fetchone(), ('k07',))
        self.assertEqual(curs.fetchmany(4), [('k08',), ('k09',)])

        self.assertIsNone(curs.fetchone())
        self.assertEqual(curs.fetchmany(10), [])
        self.assertEqual(curs.fetchall(), [])

        curs = self.db.execute('select * from g order by k limit 3')
        self.assertEqual(curs.fetchmany(100), [('k00',), ('k01',), ('k02',)])
        self.assertEqual(curs.fetchmany(100), [])
        self.assertEqual(curs.fetchmany(0), [])

        curs = self.db.execute('select * from g order by k limit 3')
        self.assertEqual(curs.fetchall(), [('k00',), ('k01',), ('k02',)])
        self.assertEqual(curs.fetchall(), [])

    def test_cursor_attributes(self):
        self.db.execute('create table g (k, v)')
        curs = self.db.execute('insert into g (k, v) values (?, ?), (?, ?)',
                               ('k1', 1, 'k2', 2))
        self.assertEqual(curs.lastrowid, 2)
        self.assertEqual(curs.rowcount, 2)
        self.assertTrue(curs.description is None)

        curs = self.db.executemany('insert into g (k, v) values (?, ?)',
                                   [('k3', 3), ('k4', 4), ('k5', 5)])
        self.assertEqual(curs.lastrowid, 5)
        self.assertEqual(curs.rowcount, 3)  # Summed by executemany().
        self.assertTrue(curs.description is None)

        curs = self.db.execute('update g set v = v + ? where v < ?', (10, 3))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 2)
        self.assertTrue(curs.description is None)

        curs = self.db.execute('update g set v = v + ? where v < ?', (100, 1))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 0)
        self.assertTrue(curs.description is None)

        curs = self.db.execute('delete from g where v < ?', (6,))
        self.assertEqual(curs.lastrowid, 5)  # Retained by conn.
        self.assertEqual(curs.rowcount, 3)
        self.assertTrue(curs.description is None)

        curs = self.db.execute('select * from g')
        self.assertTrue(curs.lastrowid is None)  # Read queries don't get this.
        self.assertEqual(curs.rowcount, -1)
        self.assertEqual(curs.description, (('k',), ('v',)))

        curs = self.db.execute('select 1, 2 as two, 3 as "t h.r-e e"')
        self.assertTrue(curs.lastrowid is None)  # Read queries don't get this.
        self.assertEqual(curs.rowcount, -1)
        self.assertEqual(curs.description, (('1',), ('two',), ('t h.r-e e',)))

    def test_cursor_context_manager(self):
        self.db.execute('create table g (k, v)')
        self.db.execute('insert into g (k, v) values (?, ?), (?, ?)',
                        ('k1', 1, 'k2', 2))

        with self.db.cursor() as curs:
            curs.execute('select k, v from g order by k')
            self.assertEqual(curs.fetchall(), [('k1', 1), ('k2', 2)])
            self.assertEqual(self.db.get_stmt_usage(), (3, 0))

        with self.db.cursor() as curs:
            curs.execute('select * from g')
            curs.fetchone()
            self.assertEqual(self.db.get_stmt_usage(), (3, 1))

        self.assertEqual(self.db.get_stmt_usage(), (4, 0))

    def test_execute(self):
        self.db.execute('create table g (k, v)')
        curs = self.db.execute('insert into g (k, v) values '
                               '(?, ?), (?, ?), (?, ?)',
                               ('k1', 1, 'k2', 2, 'k3', 3))

        curs = self.db.execute('select * from g order by v')
        self.assertEqual(list(curs), [('k1', 1), ('k2', 2), ('k3', 3)])

        row = self.db.execute_one('select * from g where k = ?', ('k2',))
        self.assertEqual(row, ('k2', 2))

        row = self.db.execute_one('select * from g where k = :k', {'k': 'k3'})
        self.assertEqual(row, ('k3', 3))

        res = self.db.execute_scalar('select sum(v) from g')
        self.assertEqual(res, 6)

        res = self.db.execute_scalar('select 1 where 1 = 0')
        self.assertTrue(res is None)

        curs = self.db.execute('select sum(v) from g')
        self.assertEqual(curs.scalar(), 6)

        curs = self.db.execute('select 1 where 1 = 0')
        self.assertTrue(curs.scalar() is None)

        curs = self.db.execute('select * from g')
        curs.close()

        # Maybe should raise error here - not sure.
        self.assertTrue(curs.fetchone() is None)
        self.assertEqual(curs.fetchall(), [])
        self.assertEqual(list(curs), [])

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

        # No read queries.
        self.assertRaises(OperationalError, curs.executemany, 'select 1', [()])

        # Read queries not allowed by executemany.
        sql = 'select * from k where id > ?'
        self.assertRaises(OperationalError,
                          lambda: curs.executemany(sql, [(1,), (2,)]))

        # Returning queries not allowed by executemany.
        with self.assertRaises(OperationalError):
            curs.executemany('insert into g(k, v) values (?, ?) returning k',
                             [('kx', 1)])

    def test_executemany_empty_list(self):
        self.create_table()
        curs = self.db.executemany('insert into kv(key, value, extra) '
                                   'values (?, ?, ?)', [])
        self.assertCount(0)

        curs = self.db.executemany('insert into kv(key, value, extra) '
                                   'values (?, ?, ?)', None)
        self.assertCount(0)

    def test_executemany_empty_generator(self):
        self.create_table()
        self.create_rows(('k1', 'v1', 1))

        # An empty generator must not report a stale lastrowid.
        sql = 'insert into kv(key, value, extra) values (?, ?, ?)'
        curs = self.db.executemany(sql, (r for r in []))
        self.assertIsNone(curs.lastrowid)
        self.assertEqual(curs.rowcount, 0)

        curs = self.db.executemany(sql, (r for r in [('k2', 'v2', 2)]))
        self.assertEqual(curs.lastrowid, 2)
        self.assertEqual(curs.rowcount, 1)

    def test_executemany_bind_error(self):
        self.create_table()
        cursor = self.db.cursor()
        _, in_use_before = self.db.get_stmt_usage()

        params = [
            ('a', 'b', 1),
            ('c',),  # Wrong number of params, will fail on bind.
        ]
        with self.assertRaises(OperationalError):
            cursor.executemany(
                'INSERT INTO kv (key, value, extra) VALUES (?, ?, ?)',
                params)

        # Re-execute to trigger overwrite of self.stmt.
        cursor.execute('SELECT 1')
        cursor.close()

        _, in_use_after = self.db.get_stmt_usage()
        self.assertEqual(in_use_after, in_use_before)

    def test_executemany_error_cursor_state(self):
        # A failed executemany() must not leave the cursor in an executing
        # state: a subsequent fetch must not step the broken statement.
        self.db.execute('create table em (a)')
        cursor = self.db.cursor()

        # Compile error: statement never acquired.
        with self.assertRaises(OperationalError):
            cursor.executemany('insert into missing (a) values (?)', [(1,)])
        self.assertIsNone(cursor.fetchone())

        # Bind error: previously left a stale step-status, causing the next
        # fetch to execute the statement with cleared (NULL) bindings.
        cursor.execute('select 1 union select 2')
        with self.assertRaises(OverflowError):
            cursor.executemany('insert into em (a) values (?)', [(2 ** 70,)])
        self.assertIsNone(cursor.fetchone())
        self.assertEqual(self.db.execute('select count(*) from em').scalar(),
                         0)

        # Cursor remains usable.
        self.assertEqual(cursor.execute('select 1').fetchone(), (1,))

    def test_bind_unsupported_type(self):
        class Custom(object): pass
        for value in ([1, 2], {'k': 'v'}, {1, 2}, (1, 2), Custom()):
            with self.assertRaises(TypeError):
                self.db.execute('select ?', (value,))

        # Subclasses of the supported date/datetime types continue to work.
        class DT(datetime.datetime): pass
        class D(datetime.date): pass
        res = self.db.execute_one('select ?, ?, ?', (
            DT(2026, 1, 2, 3, 4, 5), D(2026, 2, 3), uuid.UUID(int=13)))
        self.assertEqual(res, ('2026-01-02 03:04:05', '2026-02-03',
                               '00000000-0000-0000-0000-00000000000d'))

    def test_cursor_columns_no_statement(self):
        cursor = self.db.cursor()
        self.assertEqual(cursor.columns(), [])

        # DML cursors have no active statement once complete.
        curs = self.db.execute('create table cc (a, b)')
        self.assertEqual(curs.columns(), [])

        curs = self.db.execute('select 1 as x, 2 as y')
        self.assertEqual(curs.columns(), ['x', 'y'])

    def test_executescript(self):
        self.db.executescript("""
            BEGIN;
            CREATE TABLE t1 (id integer primary key, c1 text);
            CREATE TABLE t2 (id integer primary key, c2 text);
            CREATE TABLE t3 (id integer primary key, c3 text);
            COMMIT;
        """)
        self.assertEqual(sorted(self.db.get_tables()), ['t1', 't2', 't3'])

        cursor = self.db.cursor()
        cursor.executescript("""
            BEGIN;
            CREATE TABLE t4 (id integer primary key, c4 text);
            DROP TABLE t2;
            CREATE TABLE t5 (id integer primary key, c5 text);
            DROP TABLE t3;
            CREATE TABLE t6 (id integer primary key, c6 text);
            COMMIT;
        """)
        self.assertEqual(sorted(self.db.get_tables()),
                         ['t1', 't4', 't5', 't6'])

        # Ensure cursor is usable.
        self.assertEqual(cursor.execute('select 1').scalar(), 1)

    def test_execute_script_edge_cases(self):
        curs = self.db.cursor()
        curs.executescript('')
        curs.executescript('   \n  \t  ')
        curs.executescript(';;;')
        curs.executescript('-- comment only')
        curs.executescript('/* comment */ ;; -- trailing\n')
        curs.executescript('select 1; ')
        curs.executescript('create table esc (a);\n'
                           '-- comment\n'
                           ';\n'
                           'insert into esc values (1); ')
        self.assertEqual(self.db.execute('select a from esc').fetchall(),
                         [(1,)])

    def test_execute_invalid_sql(self):
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select * from not_exists')

        self.assertTrue('error compiling statement: [select * from not_exists]'
                        in ctx.exception.args[0])

        with self.assertRaises(OperationalError) as ctx:
            self.db.executemany('insert into not_exists (?)',
                                [(1,), (2,)])

        self.assertTrue('error compiling statement: [insert into not_exists (?'
                        in ctx.exception.args[0])

        with self.assertRaises(OperationalError) as ctx:
            self.db.executescript("""
                BEGIN;
                CREATE TABLE t1 (id integer primary key, c1 text);
                SELECT * FROM not_exist;
                COMMIT;
            """)

            # Error occurred while txn is active, tx still active.
            self.assertEqual(sorted(self.db.get_tables()), ['t1'])

        self.assertTrue('SELECT * FROM not_exist' in ctx.exception.args[0])
        self.assertTrue(self.db.in_transaction)
        self.db.rollback()
        self.assertEqual(sorted(self.db.get_tables()), [])

    def test_execute_wrong_params(self):
        self.db.execute('create table g (k, v)')
        q = 'insert into g (k, v) values (?, ?)'

        curs = self.db.cursor()
        for obj in (self.db, curs):
            self.assertRaises(OperationalError, obj.execute, q)
            self.assertRaises(OperationalError, obj.execute, q, (1,))
            self.assertRaises(OperationalError, obj.execute, q, (1, 2, 3))

            self.assertRaises(OperationalError, obj.executemany, q, [()])
            self.assertRaises(OperationalError, obj.executemany, q, [(1,)])
            self.assertRaises(OperationalError, obj.executemany, q, [(1, 2, 3)])

    def test_execute_wrong_params_dict(self):
        self.db.execute('create table g (k, v)')
        q = 'insert into g (k, v) values (:k, :v)'

        curs = self.db.cursor()
        for obj in (self.db, curs):
            self.assertRaises(OperationalError, obj.execute, q)
            self.assertRaises(OperationalError, obj.execute, q, {'k': 'k1'})
            self.assertRaises(OperationalError, obj.execute, q,
                              {'x': 'k1', 'v': 'v1'})

            self.assertRaises(OperationalError, obj.executemany, q, [{}])
            self.assertRaises(OperationalError, obj.executemany, q,
                              [{'k': 'k1'}])
            self.assertRaises(OperationalError, obj.executemany, q,
                              [{'x': 'k1', 'v': 'v1'}])

        self.assertRaises(ProgrammingError,
                          self.db.execute,
                          'select :k, ?', {'k': 'v'})

    def test_execute_many_params(self):
        nparams = 100
        tuple_data = list(range(nparams))
        tuple_params = ', '.join(['?'] * nparams)

        dict_data = {'k%03d' % i: i for i in range(nparams)}
        dict_params = ', '.join(sorted([':%s' % k for k in dict_data]))

        for i in range(10):
            row = self.db.execute_one('select %s' % tuple_params, tuple_data)
            self.assertEqual(row, tuple(range(nparams)))

            row = self.db.execute_one('select %s' % dict_params, dict_data)
            self.assertEqual(row, tuple(range(nparams)))

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

    def test_special_floats(self):
        self.db.execute('create table g (id integer primary key, v real)')
        self.db.execute('insert into g values (?, ?)', (1, float('inf'),))
        self.db.execute('insert into g values (?, ?)', (2, float('nan'),))
        curs = self.db.execute('select v from g order by id')
        v1, = curs.fetchone()
        v2, = curs.fetchone()
        self.assertEqual(v1, float('inf'))
        self.assertTrue(v2 is None)  # NaN doesn't seem to come through.

    def test_execute_special_types(self):
        self.db.execute('create table k (id integer primary key, data)')
        for v, _ in VAL_CONVERSION_TESTS:
            self.db.execute('insert into k (data) values (?)', [v])

        res = self.db.execute('select data from k order by id').fetchall()
        self.assertEqual([r for r, in res],
                         [r[1] for r in VAL_CONVERSION_TESTS])

    def test_execute_bind_sequence(self):
        res = self.db.execute_one('select ?, ?, ?', (1, 2.3, 'test'))
        self.assertEqual(res, (1, 2.3, 'test'))

        res = self.db.execute_one('select ?, ?, ?', [None, False, b'asdf'])
        self.assertEqual(res, (None, 0, b'asdf'))

        res = self.db.execute_one('select ?, ?, ?', range(3))
        self.assertEqual(res, (0, 1, 2))

        res = self.db.execute_one('select 1', ())
        self.assertEqual(res, (1,))

    def test_execute_bind_dict(self):
        res = self.db.execute_one('select :k1, :k2, :k3',
                                  {'k1': 1, 'k2': 2.3, 'k3': 'test'})
        self.assertEqual(res, (1, 2.3, 'test'))

        res = self.db.execute_one('select :k1, :k2, :k3',
                                  {'k1': None, 'k2': False, 'k3': b'asdf'})
        self.assertEqual(res, (None, 0, b'asdf'))

        res = self.db.execute_one('select :k1, :k1, :k1', {'k1': 'ok'})
        self.assertEqual(res, ('ok', 'ok', 'ok'))

        res = self.db.execute_one('select 1', {})
        self.assertEqual(res, (1,))

    def test_empty_query(self):
        self.assertRaises(ProgrammingError, self.db.execute, '')
        self.assertRaises(ProgrammingError, self.db.execute, '    ')

    def test_very_long_query(self):
        columns = ', '.join(['%d as col%d' % (i, i) for i in range(1000)])
        res = self.db.execute('SELECT %s' % columns).fetchone()
        self.assertEqual(len(res), 1000)

    def test_very_long_string(self):
        self.db.execute('CREATE TABLE test (data TEXT)')
        long_string = 'x' * 1000000  # 1MB string
        self.db.execute('INSERT INTO test VALUES (?)', (long_string,))
        res = self.db.execute('SELECT data FROM test').fetchone()
        self.assertEqual(len(res[0]), 1000000)

    def test_special_characters_in_table_name(self):
        self.db.execute('CREATE TABLE "table-with-dashes" (id INTEGER)')
        self.db.execute('INSERT INTO "table-with-dashes" VALUES (1)')
        res, = self.db.execute('SELECT * FROM "table-with-dashes"').fetchone()
        self.assertEqual(res, 1)

    def test_reserved_word_as_column_name(self):
        self.db.execute('CREATE TABLE test ("select" INTEGER)')
        self.db.execute('INSERT INTO test VALUES (1)')
        res, = self.db.execute('SELECT "select" FROM test').fetchone()
        self.assertEqual(res, 1)

    def test_zero_rows(self):
        self.db.execute('CREATE TABLE test (id INTEGER)')
        res = self.db.execute('SELECT * FROM test').fetchone()
        self.assertTrue(res is None)

    def test_null_in_primary_key(self):
        self.db.execute('CREATE TABLE test (id INTEGER PRIMARY KEY)')
        self.db.execute('INSERT INTO test VALUES (NULL)')
        res, = self.db.execute('SELECT id FROM test').fetchone()
        self.assertTrue(res is not None)


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

        curs = self.db.execute(
            'insert into kv (key, value, extra) values (?, ?, ?)',
            ('k4', 'v4', 4))
        self.assertEqual(curs.lastrowid, 4)
        self.assertEqual(curs.rowcount, 1)
        self.assertTrue(curs.description is None)
        self.assertEqual(list(curs), [])

        curs = self.db.execute('update kv set extra = ? where id = ?', (40, 4))
        self.assertEqual(curs.lastrowid, 4)
        self.assertEqual(curs.rowcount, 1)
        self.assertTrue(curs.description is None)
        self.assertEqual(list(curs), [])

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

        self.assertEqual(self.db.execute_scalar('select sum(extra) from kv'),
                         62)

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

        # curs was drained via fetchall above; rowcount now reflects the
        # full 3 rows processed by the INSERT ... ON CONFLICT DO UPDATE.
        self.assertEqual(curs.rowcount, 3)
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


class TestReturningRowcount(BaseTestCase):
    filename = ':memory:'

    # Invariant: after a DML+RETURNING cursor is drained, rowcount equals
    # the total affected-row count. The pre-drain value is implementation-
    # defined and intentionally not asserted on.
    def test_returning_description_zero_rows(self):
        # DML+RETURNING exposes a description even when no rows came back.
        self.db.execute('create table k (id integer primary key, v)')
        curs = self.db.execute('delete from k where v > 100 '
                               'returning id, v')
        self.assertEqual(curs.description, (('id',), ('v',)))
        self.assertEqual(curs.fetchall(), [])

        # Plain DML still reports no description.
        curs = self.db.execute('insert into k (v) values (1)')
        self.assertIsNone(curs.description)

    def test_insert_returning_final_after_drain(self):
        self.db.execute('create table k (v)')
        curs = self.db.execute(
            'insert into k (v) values (?), (?), (?) returning v',
            ('a', 'b', 'c'))
        curs.fetchall()
        self.assertEqual(curs.rowcount, 3)

    def test_delete_returning_final_after_drain(self):
        self.db.execute('create table k (id integer primary key, v)')
        self.db.executemany('insert into k(v) values (?)',
                            [('a',), ('b',), ('c',), ('d',)])
        curs = self.db.execute(
            'delete from k where v in (?, ?) returning v', ('b', 'd'))
        curs.fetchall()
        self.assertEqual(curs.rowcount, 2)

    def test_update_returning_final_after_drain(self):
        self.db.execute('create table k (id integer primary key, v integer)')
        self.db.executemany('insert into k(v) values (?)',
                            [(1,), (2,), (3,), (4,), (5,)])
        curs = self.db.execute(
            'update k set v = v * 10 where v > ? returning v', (2,))
        curs.fetchall()
        self.assertEqual(curs.rowcount, 3)  # rows with v in {3,4,5}

    def test_upsert_returning_final_after_drain(self):
        # INSERT ON CONFLICT DO UPDATE RETURNING, rowcount used to read 1
        # instead of 3.
        self.db.execute('create table k (key text primary key, v text)')
        self.db.execute('insert into k values (?, ?)', ('k1', 'v1'))
        curs = self.db.execute(
            'insert into k (key, v) values (?,?), (?,?), (?,?) '
            'on conflict do update set v = v || excluded.v '
            'returning key, v',
            ('k1', 'x', 'k2', 'y', 'k1', 'z'))
        curs.fetchall()
        self.assertEqual(curs.rowcount, 3)

    def test_returning_drain_via_iterator(self):
        # Iteration also finalizes rowcount.
        self.db.execute('create table k (key text primary key, v text)')
        self.db.execute('insert into k values (?, ?)', ('k1', 'v1'))
        curs = self.db.execute(
            'insert into k (key, v) values (?,?), (?,?), (?,?) '
            'on conflict do update set v = v || excluded.v '
            'returning key',
            ('k1', 'x', 'k2', 'y', 'k1', 'z'))
        for _ in curs:
            pass
        self.assertEqual(curs.rowcount, 3)

    def test_returning_drain_via_fetchmany(self):
        self.db.execute('create table k (v)')
        curs = self.db.execute(
            'insert into k (v) values (?),(?),(?),(?),(?) returning v',
            ('a', 'b', 'c', 'd', 'e'))
        while curs.fetchmany(2):
            pass
        self.assertEqual(curs.rowcount, 5)

    # Regression: the patch must not disturb the common non-RETURNING path,
    # where rowcount is captured once at execute() and is already final.
    def test_non_returning_dml_unchanged(self):
        self.db.execute('create table k (v)')

        curs = self.db.execute('insert into k(v) values (?),(?),(?)',
                               ('a', 'b', 'c'))
        self.assertEqual(curs.rowcount, 3)

        curs = self.db.execute('update k set v = v || ?', ('!',))
        self.assertEqual(curs.rowcount, 3)

        curs = self.db.execute('delete from k where v like ?', ('%!',))
        self.assertEqual(curs.rowcount, 3)


class TestQueryTypes(BaseTestCase):
    filename = ':memory:'

    def test_ddl_queries(self):
        e = self.db.execute
        e('create table g (k, v)')
        e('create table if not exists g (k, v)')
        self.assertEqual(self.db.get_tables(), ['g'])

        e('alter table g add column x')
        self.assertEqual([c.name for c in self.db.get_columns('g')],
                         ['k', 'v', 'x'])

        e('create index g_k on g(k)')
        self.assertEqual([i.name for i in self.db.get_indexes('g')], ['g_k'])

        e('drop index g_k')
        e('create unique index ug_k on g(k)')
        self.assertEqual([i.name for i in self.db.get_indexes('g')], ['ug_k'])

        e('create view vs as select v from g')
        self.assertEqual([v.name for v in self.db.get_views()], ['vs'])
        e('drop view vs')
        self.assertEqual([v.name for v in self.db.get_views()], [])

        e('drop table g')
        e('drop table if exists g')
        self.assertEqual(self.db.get_tables(), [])

    def test_dml_queries(self):
        e = self.db.execute
        e('create table g(k, v)')
        e('insert into g(k, v) values (?, ?)', ('k1', 1))
        e('insert into g(k, v) values (?, ?), (?, ?)', ('k2', 2, 'k3', 3))
        e('update g set v = v + 10 where k = ?', ('k1',))
        e('delete from g where v <= ?', (2,))

        curs = e('select * from g order by v')
        self.assertEqual(curs.fetchall(), [('k3', 3), ('k1', 11)])

    def test_constraints(self):
        e = self.db.execute
        e('create table g (id integer not null primary key, '
          'k text not null unique, v integer check(v >= 0))')

        def ins(k, v):
            e('insert into g (k, v) values (?, ?)', (k, v))

        ins('k1', 1)  # OK.

        with self.assertRaises(IntegrityError):  # PK violation.
            e('insert into g (id, k, v) values (?, ?, ?)', (1, 'k2', 2))
        with self.assertRaises(IntegrityError):  # unique violation.
            ins('k1', 2)
        with self.assertRaises(IntegrityError):  # check violation.
            ins('k2', -1)
        with self.assertRaises(IntegrityError):  # not null violation.
            ins(None, 3)


class TestAdapters(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestAdapters, self).setUp()

        @self.db.adapter(datetime.datetime)
        def adapt_datetime(val):
            return val.timestamp()

        @self.db.adapter(datetime.date)
        def adapt_date(val):
            return int(val.strftime('%Y%m%d'))

        self.db.register_adapter(dict, json.dumps)
        self.db.register_adapter(decimal.Decimal, str)

    def test_adapters(self):
        dt = datetime.datetime(2026, 1, 2, 3, 4, 5)
        d = datetime.date(2026, 2, 28)

        vals = [(dt, dt.timestamp()),
                (d, 20260228),
                ({'key': 'value'}, '{"key": "value"}'),
                (decimal.Decimal('1.3'), '1.3')]
        for src, adapted in vals:
            res = self.db.execute_scalar('select ?', (src,))
            self.assertEqual(res, adapted)

        self.db.unregister_adapter(datetime.date)

        vals = [(dt, dt.timestamp()),
                (d, '2026-02-28')]
        for src, adapted in vals:
            res = self.db.execute_scalar('select ?', (src,))
            self.assertEqual(res, adapted)

    def test_adapter_error(self):
        def buggy(val):
            raise ValueError('fail')
        self.db.register_adapter(list, buggy)
        with self.assertRaises(ValueError):
            self.db.execute('select ?', ([1, 2, 3],))

    def test_register_type(self):
        self.db.register_type('json', json.loads, dict, json.dumps)
        row = self.db.execute_one('select ?', ({'key': 'value'},))
        self.assertEqual(row, ('{"key": "value"}',))

        self.db.execute('create table g(data json)')
        self.db.execute('insert into g(data) values (?)', ({'key': 'value'},))
        row = self.db.execute_one('select data from g')
        self.assertEqual(row, ({'key': 'value'},))


class TestConverters(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestConverters, self).setUp()
        self.db.execute('create table conv (id integer not null primary key, '
                        'ts datetime, js json, uu uuid, dec numeric(10), '
                        'ui "unsigned int", data text)')

        @self.db.converter('datetime')
        def convert_datetime(value):
            return datetime.datetime.fromisoformat(value)

        @self.db.converter('numeric')
        def convert_numeric(value):
            return Decimal(value).quantize(Decimal('1.00'))

        self.db.register_converter('Json', json.loads)
        self.db.register_converter('uuid', uuid.UUID)
        self.db.register_converter(
            'unsigned',
            lambda v: ctypes.c_uint16(v).value)

    def _save(self, ts, js, uu, dec, ui, data=None):
        self.db.execute('insert into conv (ts, js, uu, dec, ui, data) '
                        'values (?,?,?,?,?,?)', (ts, js, uu, dec, ui, data))

    def test_converters(self):
        ts = (datetime.datetime(2026, 1, 2, 3, 4, 5)
              .astimezone(datetime.timezone.utc))
        js = {'k1': {'x1': 'y1'}, 'a1': ['i0', 1, 2.0], 'n': None}
        uu = uuid.uuid4()
        dec = decimal.Decimal('1.3')

        self._save(ts, json.dumps(js), uu, dec, -1, 'abc')

        row = self.db.execute_one('select * from conv')
        self.assertEqual(row, (1, ts, js, uu, dec, 65535, 'abc'))

        self.db.unregister_converter('numeric')
        row = self.db.execute_one('select * from conv')
        self.assertEqual(row, (1, ts, js, uu, 1.3, 65535, 'abc'))

    def test_converters_nulls(self):
        self._save(None, None, None, None, None, None)
        row = self.db.execute_one('select * from conv')
        self.assertEqual(row, (1, None, None, None, None, None, None))

    def test_converter_error(self):
        self._save(None, None, None, None, None, None)
        self._save(None, 'bad json', None, None, None, None)
        self._save(None, '{}', None, None, None, None)

        curs = self.db.execute('select * from conv')
        self.assertEqual(curs.fetchone(),
                         (1, None, None, None, None, None, None))

        with self.assertRaises(ValueError) as exc:
            curs.fetchone()

        self.assertIn('Expecting value', str(exc.exception))

        # Cursor is still operable.
        self.assertEqual(curs.fetchone(),
                         (3, None, {}, None, None, None, None))
        self.assertTrue(curs.fetchone() is None)


class TestRowFactory(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestRowFactory, self).setUp()
        self.create_table()
        self.create_rows(('k1', 'v1', 1), ('k2', 'v2', 2), ('k3', 'v3', 3))
        self.r1 = [('id', 1), ('key', 'k1'), ('value', 'v1'), ('extra', 1)]

    def test_default(self):
        curs = self.db.execute('select * from kv')
        self.assertTrue(isinstance(curs.fetchone(), tuple))
        self.assertTrue(isinstance(next(curs), tuple))
        self.assertTrue(isinstance(curs.fetchall()[0], tuple))

    def test_row(self):
        self.db.row_factory = Row
        curs = self.db.execute('select * from kv order by key')
        r1 = curs.fetchone()
        r2 = next(curs)
        r3 = curs.fetchall()[0]

        self.assertTrue(all(isinstance(r, Row) for r in (r1, r2, r3)))

        self.assertEqual(r1.keys(), [k for k, v in self.r1])
        self.assertEqual(r1.values(), [v for k, v in self.r1])
        self.assertEqual(r1.items(), self.r1)
        self.assertEqual(r1.as_dict(), dict(self.r1))
        self.assertEqual(list(r1), [v for k, v in self.r1])

        self.assertEqual(r1.key, 'k1')
        self.assertEqual(r1[1], 'k1')
        self.assertEqual(r1['key'], 'k1')
        self.assertEqual(r1.get('key'), 'k1')

        self.assertRaises(AttributeError, lambda: r1.x)
        self.assertRaises(KeyError, lambda: r1['x'])
        self.assertRaises(TypeError, lambda: r1[None])
        self.assertTrue(r1.get('x') is None)
        self.assertEqual(r1.get('x', 1), 1)

        self.assertTrue('key' in r1)
        self.assertFalse('x' in r1)

        d = {r1: 'r1'}
        self.assertTrue(r1 in d)
        self.assertFalse(r2 in d)

    def test_duplicate_name(self):
        self.db.row_factory = Row
        row = self.db.execute('select 1 as a, 2 as a, 3 as a').fetchone()
        self.assertEqual(row.a, 1)
        self.assertEqual(row[0], 1)
        self.assertEqual(row[1], 2)
        self.assertEqual(row[2], 3)

    def test_custom_factory(self):
        self.db.row_factory = dict_factory
        curs = self.db.execute('select * from kv order by key')
        r1 = curs.fetchone()
        r2 = next(curs)
        r3 = curs.fetchall()[0]

        self.assertTrue(all(isinstance(r, dict) for r in (r1, r2, r3)))

        self.assertEqual(sorted(r1.keys()), sorted([k for k, v in self.r1]))
        self.assertEqual(sorted(r1.items()), sorted(self.r1))
        self.assertEqual(r1, dict(self.r1))

    def test_row_factory_stable(self):
        self.db.row_factory = Row
        curs = self.db.execute('select * from kv limit 1')

        self.db.row_factory = None
        curs2 = self.db.execute('select * from kv limit 1')

        self.db.row_factory = Row
        curs3 = self.db.execute('select * from kv limit 1')

        self.assertTrue(isinstance(curs.fetchone(), Row))
        self.assertTrue(isinstance(curs2.fetchone(), tuple))
        self.assertTrue(isinstance(curs3.fetchone(), Row))

    def test_row_failure(self):
        i = 0
        def error_factory(cursor, row):
            nonlocal i
            if i == 0:
                i = 1
                return row
            raise ValueError

        self.db.row_factory = error_factory
        curs = self.db.execute('select * from kv order by key')
        self.assertEqual(curs.fetchone(), tuple(v for k, v in self.r1))
        self.assertRaises(OperationalError, curs.fetchone)

    def test_row_comparison_with_other_types(self):
        self.db.row_factory = Row
        curs = self.db.execute('select * from kv order by key limit 1')
        row = curs.fetchone()

        # Should return False, not raise NotImplementedError.
        self.assertFalse(row == [1, 'k1', 'v1', 1])
        self.assertTrue(row != [1, 'k1', 'v1', 1])
        self.assertFalse(row == 42)
        self.assertFalse(row == 'hello')
        self.assertFalse(row == None)


class TestTransactions(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestTransactions, self).setUp()
        self.create_table()
        self.db.execute('create table reg (val integer not null)')

    def assertRegister(self, expected):
        cursor = self.db.execute('select val from reg order by val')
        self.assertEqual([row[0] for row in cursor], expected)

    def _save(self, *vals):
        self.db.executemany('insert into reg (val) values (?)',
                            [(v,) for v in vals])

    def test_atomic_after_manual_begin(self):
        # atomic() inside a manually-started transaction uses a savepoint
        # rather than failing with "cannot start a transaction within a
        # transaction".
        self.db.begin()
        with self.db.atomic():
            self._save(1)
        self.assertFalse(self.db.autocommit())  # Outer txn still open.
        self.db.rollback()
        self.assertRegister([])

        self.db.begin()
        with self.db.atomic():
            self._save(2)
        self.db.commit()
        self.assertRegister([2])

        # A failing atomic() block only rolls back the savepoint.
        self.db.begin()
        self._save(3)
        with self.assertRaises(ValueError):
            with self.db.atomic():
                self._save(4)
                raise ValueError('oops')
        self.db.commit()
        self.assertRegister([2, 3])

    def test_close_manual_transaction(self):
        # close() refuses while a manually-started transaction is open, and
        # force-close rolls the manual transaction back.
        filename = '/tmp/cysqlite-manual-txn.db'
        db = Connection(filename)
        try:
            db.execute('create table reg (val integer not null)')
            db.begin()
            db.execute('insert into reg (val) values (1)')
            self.assertRaises(OperationalError, db.close)
            self.assertFalse(db.is_closed())

            self.assertTrue(db.close(force=True))
            db.connect()
            vals = [v for v, in db.execute('select val from reg')]
            self.assertEqual(vals, [])
        finally:
            db.close(force=True)
            if os.path.exists(filename):
                os.unlink(filename)

    def test_simple(self):
        self.assertFalse(self.db.in_transaction)
        with self.db.atomic():
            self.assertTrue(self.db.in_transaction)
            self._save(1)

        self.assertFalse(self.db.in_transaction)
        self.assertRegister([1])

        # Explicit rollback, implicit commit.
        with self.db.atomic() as txn:
            self._save(2)
            txn.rollback()
            self.assertTrue(self.db.in_transaction)
            self._save(3)

        self.assertFalse(self.db.in_transaction)
        self.assertRegister([1, 3])

        # Explicit rollbacks.
        with self.db.atomic() as txn:
            self._save(4)
            txn.rollback()
            self._save(5)
            txn.rollback()

        self.assertRegister([1, 3])

    def test_transactions(self):
        self.assertFalse(self.db.in_transaction)

        with self.db.atomic():
            self.assertTrue(self.db.in_transaction)
            self._save(1)

        self.assertRegister([1])

        with self.db.atomic() as txn:
            self._save(2)
            txn.rollback()
            self._save(3)
            with self.db.atomic() as sp1:
                self._save(4)
                with self.db.atomic() as sp2:
                    self._save(5)
                    sp2.rollback()
                with self.db.atomic() as sp3:
                    self._save(6)
                    with self.db.atomic() as sp4:
                        self._save(7)
                        with self.db.atomic() as sp5:
                            self._save(8)
                        self.assertRegister([1, 3, 4, 6, 7, 8])
                        sp4.rollback()

                    self.assertRegister([1, 3, 4, 6])

        self.assertRegister([1, 3, 4, 6])

    def test_commit_rollback(self):
        with self.db.atomic() as txn:
            self._save(1)
            txn.commit()
            self._save(2)
            txn.rollback()

        self.assertRegister([1])

        with self.db.atomic() as txn:
            self._save(3)
            txn.rollback()
            self._save(4)

        self.assertRegister([1, 4])

    def test_commit_rollback_nested(self):
        with self.db.atomic() as txn:
            self.test_commit_rollback()
            txn.rollback()
        self.assertRegister([])

        with self.db.atomic():
            self.test_commit_rollback()
        self.assertRegister([1, 4])

    def test_atomic_obj_commit_rollback(self):
        # The Atomic object itself exposes commit/rollback, delegating to
        # the wrapped transaction or savepoint.
        a = self.db.atomic()
        with a:
            self._save(1)
            a.commit()
            self._save(2)
            a.rollback()
            self._save(3)

        self.assertRegister([1, 3])

        with self.db.atomic():
            self._save(4)
            a2 = self.db.atomic()
            with a2:
                self._save(5)
                a2.rollback()
                self._save(6)

        self.assertRegister([1, 3, 4, 6])

    def test_nesting_transaction_obj(self):
        self.assertRegister([])

        with self.db.transaction() as txn:
            self._save(1)
            with self.db.transaction() as txn2:
                self._save(2)
                txn2.rollback()  # Actually issues a rollback.
                self.assertRegister([])
            self._save(3)
        self.assertRegister([3])

        with self.db.transaction() as txn:
            self._save(4)
            with self.db.transaction() as txn2:
                with self.db.transaction() as txn3:
                    self._save(5)
                    txn3.commit()  # Actually commits.
            self._save(6)
            txn2.rollback()

        self.assertRegister([3, 4, 5])

        # The inner-most exception triggers a rollback.
        with self.db.transaction() as txn:
            self._save(6)
            try:
                with self.db.transaction() as txn2:
                    self._save(7)
                    raise ValueError
            except ValueError:
                pass

        self.assertRegister([3, 4, 5])
        self.assertFalse(self.db.in_transaction)

    def test_savepoint_commit(self):
        with self.db.atomic() as txn:
            self._save(1)
            txn.rollback()

            self._save(2)
            txn.commit()

            with self.db.atomic() as sp:
                self._save(3)
                sp.rollback()

                self._save(4)
                sp.commit()

        self.assertRegister([2, 4])

    def test_atomic_decorator(self):
        @self.db.atomic()
        def save(i):
            self._save(i)

        save(1)
        self.assertRegister([1])

    def test_atomic_exception(self):
        def will_fail():
            with self.db.atomic():
                self._save(1)
                self._save(None)

        self.assertRaises(IntegrityError, will_fail)
        self.assertRegister([])

        def user_error():
            with self.db.atomic():
                self._save(2)
                raise ValueError

        self.assertRaises(ValueError, user_error)
        self.assertRegister([])

    def test_atomic_commit_failure_raises(self):
        self.db.pragma('foreign_keys', 1)
        self.db.execute('create table p (id integer primary key)')
        self.db.execute('create table c (id integer primary key, '
                        'pid integer references p(id) '
                        'deferrable initially deferred)')

        def fails():
            with self.db.atomic():
                self.db.execute('insert into c (pid) values (1337)')

        self.assertRaises(ForeignKeyIntegrityError, fails)
        self.assertFalse(self.db.in_transaction)
        self.assertEqual(self.db.execute_scalar('select count(*) from c'), 0)

    def test_closing_db_in_transaction(self):
        with self.db.atomic():
            self.assertRaises(OperationalError, self.db.close)

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

        # Cannot begin a transaction within a transaction.
        self.assertRaises(OperationalError, self.db.begin)

        self.assertFalse(self.db.autocommit())
        self.create_rows(('k2', 'v2', 2))
        self.db.commit()
        self.assertTrue(self.db.autocommit())

        # Cannot commit() or rollback() when no transaction is active.
        self.assertRaises(OperationalError, self.db.commit)
        self.assertRaises(OperationalError, self.db.rollback)

        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([row for row, in curs], ['k2'])

    def test_no_nested_transaction(self):
        # Sqlite doesn't allow nested transactions - we check tx depth, though,
        # so we end up doing the right thing.
        with self.db.transaction() as txn:
            with self.db.transaction() as txn2:
                self.create_rows(('k1', 'v1', 1))
            txn.rollback()
        self.assertCount(0)

        with self.db.transaction() as txn:
            with self.db.transaction() as txn2:
                self.create_rows(('k1', 'v1', 1))
                txn2.rollback()
        self.assertCount(0)

        with self.db.transaction() as txn:
            with self.db.transaction() as txn2:
                self.create_rows(('k1', 'v1', 1))
            txn.commit()
        self.assertCount(1)

        with self.db.transaction() as txn:
            with self.db.transaction() as txn2:
                self.create_rows(('k2', 'v2', 2))
                txn2.commit()
            txn.rollback()
        self.assertCount(2)

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
        self.assertEqual(self.db.execute('select key from kv').scalar(), 'k1')

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
        self.assertEqual(self.db.execute('select key from kv').scalar(), 'k3')

    def test_explicit_rollback(self):
        # Explicit rollback and implicit commit in outer (transaction) block.
        with self.db.atomic() as txn:
            self.create_rows(('k1', 'v1', 1))
            txn.rollback()
            self.assertFalse(self.db.autocommit())  # Txn begins again.
            self.create_rows(('k2', 'v2', 2))

        self.assertTrue(self.db.autocommit())
        self.assertCount(1)
        self.assertEqual(self.db.execute('select key from kv').scalar(), 'k2')

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
        self.assertEqual(self.db.execute('select key from kv').scalar(), 'k4')

    def test_savepoint_released_after_rollback(self):
        with self.db.transaction():
            for i in range(100):
                try:
                    with self.db.savepoint():
                        self.db.execute(
                            'INSERT INTO kv (key, value) VALUES (?, ?)',
                            (f'k{i}', f'v{i}'))
                        raise ValueError('force rollback')
                except ValueError:
                    pass

            # Table should be empty - all savepoints rolled back.
            self.assertCount(0)

            # The real test: if savepoints weren't released, SQLite's
            # internal savepoint stack has 50 entries. Verify we can still
            # create and use new savepoints without issue, and that
            # PRAGMA compile-time savepoint limits aren't hit.
            with self.db.savepoint():
                self.db.execute(
                    'INSERT INTO kv (key, value) VALUES (?, ?)', ('ok', 'ok'))
        self.assertCount(1)


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

        curs = self.db.execute('select key, reverse(reverse(value)) from kv '
                               'order by reverse(value)')
        self.assertEqual(list(curs), [
            ('k2', 'v2b'),
            ('k1', 'v1x'),
            ('k3', 'v3z')])

        self.assertTrue(self.db.callback_error is None)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select reverse(1)')

        # Original Python exception is chained as __cause__.
        self.assertCausedBy(ctx.exception, '', TypeError)

        # callback_error was consumed by raise_sqlite_error; reading it
        # here returns None.
        self.assertTrue(self.db.callback_error is None)

    def test_create_function_multiple(self):
        def add(a, b):
            return a + b

        self.db.create_function(add, 'myadd', 2)

        def run(*args):
            params = ', '.join(['?' for _ in args])
            curs = self.db.execute('select myadd(%s)' % params, args)
            return curs.scalar()

        self.assertEqual(run(1, 2), 3)
        self.assertEqual(run('a', 'bc'), 'abc')

        self.assertTrue(self.db.callback_error is None)
        with self.assertRaises(OperationalError) as ctx:
            run(None, 1)
        self.assertTrue(isinstance(ctx.exception.__cause__, TypeError))

        # These are raised by Sqlite since we passed wrong num parameters.
        self.assertRaises(OperationalError, lambda: run(1))
        self.assertRaises(OperationalError, lambda: run(1, 2, 3))

    def test_create_function_overload_arity(self):
        self.db.create_function(lambda a: a + 1, 'ov', 1)
        self.db.create_function(lambda a, b: a + b, 'ov', 2)
        self.db.create_function(lambda a, b, c: a + b + c, 'ov', 3)
        self.assertEqual(self.db.execute_scalar('select ov(10)'), 11)
        self.assertEqual(self.db.execute_scalar('select ov(1, 2)'), 3)
        self.assertEqual(self.db.execute_scalar('select ov(1, 2, 3)'), 6)

    def test_i64_bounds(self):
        self.db.create_function(lambda i: 2 ** 63 - i, 'big')
        with self.assertRaises(OperationalError):
            self.db.execute_scalar('select big()')

        res = self.db.execute_scalar('select big(1)')
        self.assertEqual(res, (2 ** 63) - 1)

    def test_create_function_return_types(self):
        def value_type(i):
            return VAL_TESTS[i]

        self.db.create_function(value_type)

        for i in range(len(VAL_TESTS)):
            val = self.db.execute('select value_type(?)', (i,)).scalar()
            self.assertEqual(val, VAL_TESTS[i])

        def value_conv(i):
            return VAL_CONVERSION_TESTS[i][0]

        self.db.create_function(value_conv)

        for i in range(len(VAL_CONVERSION_TESTS)):
            val = self.db.execute('select value_conv(?)', (i,)).scalar()
            self.assertEqual(val, VAL_CONVERSION_TESTS[i][1])

    def test_function_result_conversion_error(self):
        # An error converting the function result is reported as a query
        # error with the original exception chained as __cause__, rather
        # than silently producing NULL.
        def badbuf():
            return memoryview(b'abcdef')[::2]  # Non-contiguous buffer.
        self.db.create_function(badbuf, 'badbuf', 0)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select badbuf()')
        self.assertIsInstance(ctx.exception.__cause__, BufferError)

        def baddict():
            return {'k': 'v'}
        self.db.create_function(baddict, 'baddict', 0)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select baddict()')
        self.assertIsInstance(ctx.exception.__cause__, TypeError)

        # Connection remains usable.
        self.assertEqual(self.db.execute('select 1').fetchone(), (1,))

    def test_function_invalid_utf8_argument(self):
        # Errors converting function arguments (e.g. TEXT containing invalid
        # UTF-8) are likewise surfaced with the original error as __cause__.
        def fn(s):
            return s
        self.db.create_function(fn, 'fn_utf8', 1)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute("select fn_utf8(CAST(x'ff80' AS TEXT))")
        self.assertIsInstance(ctx.exception.__cause__, UnicodeDecodeError)

    def test_registrations_survive_reconnect(self):
        self.db.create_function(lambda a: a + a, 'dbl', 1)
        self.db.create_function(lambda a, b: a + a + b + b, 'dbl', 2)
        self.db.create_collation(lambda a, b: (a > b) - (a < b), 'col')
        self.assertEqual(self.db.execute_scalar('select dbl(2)'), 4)
        self.assertEqual(self.db.execute_scalar('select dbl(2, 3)'), 10)

        self.db.close()
        self.db.connect()

        self.assertEqual(self.db.execute_scalar('select dbl(3)'), 6)
        self.assertEqual(self.db.execute_scalar('select dbl(3, 4)'), 14)
        self.db.execute('create table g(k)')
        self.db.execute('insert into g(k) values (?), (?), (?)',
                        ('b', 'a', 'c'))
        curs = self.db.execute('select k from g order by k collate col')
        self.assertEqual([k for k, in curs], ['a', 'b', 'c'])

    def test_remove_registrations(self):
        class Sum(object):
            def __init__(self): self.total = 0
            def step(self, value): self.total += (value or 0)
            def inverse(self, value): self.total -= (value or 0)
            def value(self): return self.total
            def finalize(self): return self.total

        self.db.create_function(lambda a: a + a, 'dbl', 1)
        self.db.create_aggregate(Sum, 'mysum', 1)
        self.db.create_window_function(Sum, 'mywin', 1)
        self.db.create_collation(lambda a, b: (a > b) - (a < b), 'col')
        self.assertEqual(self.db.execute_scalar('select dbl(2)'), 4)

        # Removing requires a name. nargs must match the registration.
        self.assertRaises(ValueError, self.db.create_function, None)
        self.assertRaises(ValueError, self.db.create_aggregate, None)
        self.assertRaises(ValueError, self.db.create_window_function, None)
        self.assertRaises(ValueError, self.db.create_collation, None)

        self.db.create_function(None, 'dbl', 1)
        self.db.create_aggregate(None, 'mysum', 1)
        self.db.create_window_function(None, 'mywin', 1)
        self.db.create_collation(None, 'col')

        self.assertRaises(OperationalError, self.db.execute, 'select dbl(2)')
        self.assertRaises(OperationalError, self.db.execute,
                          'select mysum(1)')
        self.assertRaises(OperationalError, self.db.execute,
                          'select mywin(1) over ()')
        self.assertRaises(OperationalError, self.db.execute,
                          'select 1 order by 1 collate col')

        # Removal is durable across a reconnect.
        self.db.close()
        self.db.connect()
        self.assertRaises(OperationalError, self.db.execute, 'select dbl(2)')

        # Removing a nonexistent function is a no-op.
        self.db.create_function(None, 'nothere', 1)

    def test_create_aggregate(self):
        class Sum(object):
            def __init__(self): self.value = 0
            def step(self, value): self.value += (value or 0)
            def finalize(self): return self.value

        self.db.create_aggregate(Sum, 'mysum', 1)
        curs = self.db.execute('select mysum(extra) from kv')
        self.assertEqual(curs.scalar(), 60)

    def test_create_aggregate_return_types(self):
        self.db.print_callback_tracebacks = True
        class ValueType(object):
            def __init__(self): self.idx = 0
            def step(self, value): self.idx = value
            def finalize(self): return VAL_TESTS[self.idx]

        self.db.create_aggregate(ValueType)

        for i in range(len(VAL_TESTS)):
            curs = self.db.execute('select valuetype(?)', (i,))
            self.assertEqual(curs.scalar(), VAL_TESTS[i])

        class ValueConv(object):
            def __init__(self): self.idx = 0
            def step(self, value): self.idx = value
            def finalize(self): return VAL_CONVERSION_TESTS[self.idx][0]

        self.db.create_aggregate(ValueConv)

        for i in range(len(VAL_CONVERSION_TESTS)):
            curs = self.db.execute('select valueconv(?)', (i,))
            self.assertEqual(curs.scalar(), VAL_CONVERSION_TESTS[i][1])

    def test_aggregate_broken_init(self):
        class BrokenInit(object):
            def __init__(self):
                raise ValueError('broken init')

        self.db.create_aggregate(BrokenInit, 'broken_init', 1)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select broken_init(extra) from kv')
        self.assertCausedBy(ctx.exception, 'broken init', ValueError)

    def test_aggregate_broken_step(self):
        class BrokenStep(object):
            def __init__(self): pass
            def step(self, value):
                if value > 10:
                    raise ValueError('broken step')
            def finalize(self):
                return 0

        self.db.create_aggregate(BrokenStep, 'broken_step', 1)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select broken_step(extra) from kv')
        self.assertCausedBy(ctx.exception, 'broken step', ValueError)

    def test_aggregate_broken_finalize(self):
        class BrokenFinalize(object):
            def __init__(self): pass
            def step(self, value): pass
            def finalize(self):
                raise ValueError('broken finalize')
                return 0

        self.db.create_aggregate(BrokenFinalize, 'broken_finalize', 1)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select broken_finalize(extra) from kv')
        self.assertCausedBy(ctx.exception, 'broken finalize', ValueError)

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

        class BrokenInit(Sum):
            def __init__(self): raise ValueError('broken_init')
        class BrokenStep(Sum):
            def step(self, value):
                raise ValueError('broken_step')
        class BrokenInverse(Sum):
            def inverse(self, value):
                raise ValueError('broken_inverse')
        class BrokenValue(Sum):
            def value(self):
                raise ValueError('broken_value')
        class BrokenFinalize(Sum):
            def finalize(self):
                raise ValueError('broken_finalize')

        pairs = (
            (BrokenInit, 'broken_init'),
            (BrokenStep, 'broken_step'),
            (BrokenInverse, 'broken_inverse'),
            (BrokenValue, 'broken_value'),
            # Not sure why this isn't working - it is called but the error
            # value is not reported to Sqlite, which then doesn't report the
            # error to the user.
            #(BrokenFinalize, 'broken_finalize'),
        )
        for agg, name in pairs:
            self.db.create_window_function(agg, name, 1)
            with self.assertRaises(OperationalError) as ctx:
                curs = self.db.execute('select key, extra, %s(extra) over ('
                                       'order by id rows between '
                                       '1 preceding and 1 following) '
                                       'from kv order by key, extra' % name)
                curs.fetchall()

            self.assertCausedBy(ctx.exception, name, ValueError)

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

    def test_broken_collation(self):
        def broken(a, b):
            raise ValueError('broken')

        self.create_rows(('k1', 'v1', 0), ('k2', 'v2', 0))
        self.db.create_collation(broken, 'broken')

        # Collations cannot trigger errors.
        self.db.execute('select * from kv order by key collate broken')

        self.assertCallbackError('broken', ValueError)

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

    def test_commit_hook_return_value(self):
        # A truthy return value converts the COMMIT into a ROLLBACK,
        # matching the stdlib sqlite3 commit-hook contract.
        state = {'abort': True, 'calls': 0}
        def on_commit():
            state['calls'] += 1
            return state['abort']

        self.db.commit_hook(on_commit)
        self.db.begin()
        self.db.execute('delete from kv')
        self.assertCount(0)
        with self.assertRaises(IntegrityError):
            self.db.commit()
        self.assertTrue(self.db.autocommit())
        self.assertCount(3)

        # Falsy return: commit proceeds.
        state['abort'] = False
        self.db.begin()
        self.db.execute('delete from kv')
        self.db.commit()
        self.assertCount(0)
        self.assertEqual(state['calls'], 2)
        self.db.commit_hook(None)

    def test_broken_commit_hook(self):
        def broken():
            raise TypeError('fail')

        self.db.commit_hook(broken)
        self.db.begin()
        self.db.execute('delete from kv')
        self.assertCount(0)
        self.assertFalse(self.db.autocommit())
        with self.assertRaises(IntegrityError) as ctx:
            self.db.commit()

        self.assertCausedBy(ctx.exception, 'fail', TypeError)

        self.assertTrue(self.db.autocommit())
        self.assertCount(3)

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

    def test_broken_rollback_hook(self):
        def broken():
            raise TypeError('rbfail')

        self.db.rollback_hook(broken)
        self.db.begin()
        self.db.execute('delete from kv')
        self.assertCount(0)
        self.assertFalse(self.db.autocommit())
        self.db.rollback()

        self.assertCallbackError('rbfail', TypeError)

        self.assertTrue(self.db.autocommit())
        self.assertCount(3)

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

    def test_broken_update_hook(self):
        def on_update(query, db, table, rowid):
            raise ValueError('fail %s' % rowid)

        self.db.update_hook(on_update)
        self.create_rows(('k4', 'v4', 40))
        self.assertCallbackError('fail 4', ValueError)

        self.db.execute('update kv set extra = extra + ? where extra < ?',
                        (1, 20))
        self.assertCallbackError('fail 1', ValueError)

        self.assertCount(4)  # Everything went through.

    def test_authorizer(self):
        ret = [SQLITE_OK]
        state = []
        def authorizer(op, p1, p2, p3, p4):
            state.append((op, p1, p2, p3, p4))
            if op == 21:  # SQLITE_SELECT.
                return SQLITE_OK
            if op == 20 and p2 != 'key':  # SQLITE_READ.
                return SQLITE_OK
            return ret[0]
        self.db.authorizer(authorizer)

        self.db.execute('delete from kv where key = ?', ('k1',))
        self.assertEqual(state[:2], [
            (9, 'kv', None, 'main', None),
            (20, 'kv', 'key', 'main', None)])

        ret = [SQLITE_IGNORE]
        curs = self.db.execute('select key, value, extra from kv order by id')
        self.assertEqual(list(curs), [
            (None, 'v2b', 20),
            (None, 'v3z', 30)])

        ret = [SQLITE_DENY]
        with self.assertRaises(OperationalError):
            self.db.execute('select * from kv')

        self.db.authorizer(None)

    def test_broken_authorizer(self):
        def authorizer(op, p1, p2, p3, p4):
            raise ValueError('fail')

        self.db.authorizer(authorizer)
        queries = [
            'select * from kv',
            'delete from kv',
            'update kv set extra = extra + 1',
            'insert into kv (key, value, extra) values (1, 1, 1)',
            'create table g (k, v)',
            'drop table kv',
        ]
        for query in queries:
            with self.assertRaises(OperationalError) as ctx:
                self.db.execute(query)

            self.assertCausedBy(ctx.exception, 'fail', ValueError)

        self.db.authorizer(None)  # Clear authorizer to verify no changes.
        self.assertCount(3)
        self.assertEqual(self.db.get_tables(), ['kv'])

    def test_tracer(self):
        accum = []
        def tracer(code, sid, sql, ns):
            accum.append((code, sql))

        self.db.trace(tracer, SQLITE_TRACE_ROW | SQLITE_TRACE_STMT)
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([k for k, in curs], ['k1', 'k2', 'k3'])

        self.assertEqual(accum, [
            (1, 'select key from kv order by key'),
            (4, 'select key from kv order by key'),
            (4, 'select key from kv order by key'),
            (4, 'select key from kv order by key'),
        ])

    def test_trace_sql(self):
        accum = []
        def tracer(code, sid, sql, ns):
            accum.append(sql)

        self.db.trace(tracer)
        self.db.execute('select ?, ?, ?', (1, None, 'test'))
        self.assertEqual(accum, ['select 1, NULL, \'test\''])

        self.db.trace(tracer, expand_sql=False)
        self.db.execute('select ?, ?, ?', (1, None, 'test'))
        self.assertEqual(accum, [
            'select 1, NULL, \'test\'',
            'select ?, ?, ?'])

        self.db.trace(None)

    def test_broken_tracer(self):
        def broken(code, sid, sql, ns):
            raise ValueError('trace fail')
        self.db.trace(broken, SQLITE_TRACE_ROW | SQLITE_TRACE_STMT)
        self.assertCount(3)

        self.assertCallbackError('trace fail', ValueError)

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

    def test_broken_progress(self):
        def broken():
            raise ValueError('progress fail')

        for i in range(100):
            self.db.execute('insert into kv (key,value,extra) values (?,?,?)',
                            ('k%02d' % i, 'v%s' % i, i))

        self.db.progress(broken, 10)
        results = self.db.execute('select * from kv order by key').fetchall()
        self.assertEqual(len(results), 103)

        self.assertCallbackError('progress fail', ValueError)

    def test_progress_interrupt(self):
        # Any truthy return value interrupts the query.
        self.db.progress(lambda: 'stop', 10)
        with self.assertRaises(OperationalError):
            self.db.execute('select * from kv order by key').fetchall()

        self.db.progress(None)
        self.assertCount(3)

    def test_interrupt(self):
        def interrupt():
            self.db.interrupt()

        self.db.progress(interrupt, 10)
        with self.assertRaises(OperationalError):
            self.db.execute(
                'with recursive c(x) as (select 1 union all '
                'select x + 1 from c where x < 1000000) '
                'select count(*) from c').fetchall()

        # Connection remains usable afterwards.
        self.db.progress(None)
        self.assertCount(3)

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

        self.db.execute_simple('select NULL as key, \'asdf\' as value', cb)
        self.assertEqual(accum[-1], (None, 'asdf'))

    def test_exec_no_cb(self):
        self.db.execute_simple("insert into kv (key, value, extra) "
                               "values ('k4', 'v4', 4)")
        self.db.execute_simple('select * from kv')
        self.assertCount(4)

    def test_broken_exec_cb(self):
        def broken(row):
            raise ValueError('broken cb')

        for i in range(10):
            with self.assertRaises(OperationalError) as ctx:
                self.db.execute_simple('select * from kv', broken)
            self.assertCausedBy(ctx.exception, 'broken cb', ValueError)

    def test_exec_error_mapping(self):
        # Errors are mapped to the appropriate exception subclass.
        self.db.execute('create table u (k text unique)')
        self.db.execute_simple("insert into u (k) values ('k1')")
        with self.assertRaises(IntegrityError):
            self.db.execute_simple("insert into u (k) values ('k1')")

    def test_registrations_do_not_leak_connection(self):
        # The callback wrappers reference the connection and are handed to
        # SQLite. Because the connection owns them (SQLite only borrows the
        # pointer), the reference cycle is visible to the GC and dropping an
        # unclosed connection must still free it. Regression test: these all
        # leaked when SQLite owned the only reference to the wrapper.
        class Agg(object):
            def step(self, v): pass
            def inverse(self, v): pass
            def value(self): return 0
            def finalize(self): return 0

        def tf(n):
            for i in range(n):
                yield (i,)

        cases = [
            (lambda c: c.create_function(lambda x: x, 'f', 1),
             'select f(1)'),
            (lambda c: c.create_aggregate(Agg, 'agg', 1),
             'select agg(x) from (select 1 as x)'),
            (lambda c: c.create_window_function(Agg, 'win', 1),
             'select win(x) over () from (select 1 as x)'),
            (lambda c: c.create_collation(lambda a, b: 0, 'coll'),
             "select 'a' order by 1 collate coll"),
            (lambda c: c.create_table_function(tf, 'tf', ['i']),
             'select * from tf(2)'),
        ]
        for register, sql in cases:
            conn = Connection(':memory:')
            canary = conn.row_factory = lambda cursor, row: row
            wr = weakref.ref(canary)
            register(conn)
            conn.execute(sql).fetchall()  # Exercise the registration.
            del conn, canary
            gc.collect()
            self.assertIsNone(wr(), 'connection leaked by: %s' % sql)


class TestDatabaseSettings(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestDatabaseSettings, self).setUp()
        self.create_table()

    def tearDown(self):
        super(TestDatabaseSettings, self).tearDown()
        for filename in glob.glob('/tmp/cysqlite.db*'):
            os.unlink(filename)

    def test_pragma(self):
        result = self.db.pragma('journal_mode')
        self.assertEqual(result, 'memory')

        self.db.pragma('cache_size', -123)
        self.assertEqual(self.db.pragma('cache_size'), -123)
        self.db.close()

        self.db.connect()
        self.assertNotEqual(self.db.pragma('cache_size'), -123)
        self.db.close()

        self.db.connect()
        self.db.pragma('cache_size', -234, permanent=True)
        self.assertEqual(self.db.pragma('cache_size'), -234)
        self.db.close()

        self.db.connect()
        self.assertEqual(self.db.pragma('cache_size'), -234)

    def test_pragma_permanent_database(self):
        self.db.attach(':memory:', 'aux1')

        # Database-qualified pragmas work...
        self.db.pragma('cache_size', -4321, database='aux1')
        self.assertEqual(self.db.pragma('cache_size', database='aux1'), -4321)

        # ...but cannot be persisted: attached databases are not restored
        # on reconnect, so the stored pragma could not be replayed.
        with self.assertRaises(ValueError):
            self.db.pragma('cache_size', -4321, database='aux1',
                           permanent=True)
        self.db.detach('aux1')

    def test_pragma_permanent_requires_value(self):
        with self.assertRaises(ValueError):
            self.db.pragma('cache_size', permanent=True)

    def test_metadata_quoted_identifiers(self):
        self.db.execute('create table "we""ird" ("a" integer primary key, '
                        '"b ""x""" text)')
        self.db.execute('create index "id""x" on "we""ird" ("b ""x""")')

        self.assertEqual([c.name for c in self.db.get_columns('we"ird')],
                         ['a', 'b "x"'])
        self.assertEqual(self.db.get_primary_keys('we"ird'), ['a'])
        indexes = self.db.get_indexes('we"ird')
        self.assertEqual([i.name for i in indexes], ['id"x'])
        self.assertEqual(indexes[0].columns, ['b "x"'])

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

        self.db.execute('create table t1 (a)')
        self.db.execute('create table t2 (b)')
        curs = self.db.pragma('table_list', database='main', multi=True)
        self.assertEqual(sorted(row[1] for row in curs),
                         ['kv', 'sqlite_schema', 't1', 't2'])

    def test_table_column_metadata(self):
        self.assertEqual(self.db.table_column_metadata('kv', 'id'), (
            'kv', 'id', 'INTEGER', 'BINARY', 1, 1, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'key'), (
            'kv', 'key', 'TEXT', 'BINARY', 1, 0, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'extra'), (
            'kv', 'extra', 'INTEGER', 'BINARY', 0, 0, 0))

    def test_table_column_metadata_untyped(self):
        # Columns with no declared type report a NULL (None) data-type.
        self.db.execute('create table untyped (a, b INTEGER)')
        self.assertEqual(self.db.table_column_metadata('untyped', 'a'), (
            'untyped', 'a', None, 'BINARY', 0, 0, 0))
        self.assertEqual(self.db.table_column_metadata('untyped', 'b'), (
            'untyped', 'b', 'INTEGER', 'BINARY', 0, 0, 0))

    def test_read_metadata(self):
        self.assertEqual(self.db.get_tables(), ['kv'])
        self.assertEqual(self.db.get_columns('kv'), [
            Column('id', 'INTEGER', False, True, 'kv', None),
            Column('key', 'TEXT', False, False, 'kv', None),
            Column('value', 'TEXT', False, False, 'kv', None),
            Column('extra', 'INTEGER', True, False, 'kv', None)])
        self.assertEqual(self.db.get_primary_keys('kv'), ['id'])

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
            ('addl', os.path.realpath('/tmp/cysqlite.db'))])

    @unittest.skipUnless(HAS_LOAD_EXTENSION,
                         'SQLite built without load-extension support')
    def test_load_extension_sql_disabled_default(self):
        with self.assertRaises(OperationalError) as cm:
            self.db.execute('select load_extension(\'/x/y\')')
        self.assertIn('not authorized', str(cm.exception).lower())

        with self.assertRaises(OperationalError) as cm:
            self.db.load_extension('/x/y')
        self.assertNotIn('not authorized', str(cm.exception).lower())

        self.db.enable_load_extension()
        with self.assertRaises(OperationalError) as cm:
            self.db.execute('select load_extension(\'/x/y\')')
        self.assertNotIn('not authorized', str(cm.exception).lower())

    def test_optimize(self):
        conn = Connection('/tmp/cysqlite.db', autoconnect=True)
        conn.execute('create table k (id integer not null primary key, '
                     'data text not null)')
        conn.execute('create index k_data on k(data)')
        res = conn.optimize(dry_run=True)
        self.assertEqual(list(res), [])

        conn.executemany('insert into k (data) values (?)',
                         [('k%064d' % i,) for i in range(100)])
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

    def setUp(self):
        super(TestBackup, self).setUp()

        self.db.execute('create table g (k, v)')
        self.db.executemany('insert into g (k, v) values (?, ?)',
                            [('k%02d' % i, 'v%02d' % i) for i in range(100)])

    def tearDown(self):
        super(TestBackup, self).tearDown()
        for f in glob.glob('/tmp/cysqlite_backup.db*'):
            os.unlink(f)

    def test_backup(self):
        curs = self.db.cursor()
        self.assertEqual(curs.execute('select count(*) from g').scalar(), 100)

        new = Connection(':memory:', autoconnect=False)
        self.assertRaises(OperationalError, self.db.backup, new)

        new.connect()
        self.db.backup(new)
        self.assertEqual(new.execute('select count(*) from g').scalar(), 100)

    def test_backup_to_file(self):
        self.db.backup_to_file('/tmp/cysqlite_backup.db')
        with Connection('/tmp/cysqlite_backup.db') as dest:
            self.assertEqual(dest.execute('select count(*) from g').scalar(),
                             100)

    def test_backup_schema_names(self):
        # name refers to the source database, dest_name to the destination.
        self.db.attach(':memory:', 'aux1')
        self.db.execute('create table aux1.a (k)')
        self.db.execute("insert into aux1.a (k) values ('x'), ('y')")

        with Connection(':memory:') as dest:
            self.db.backup(dest, name='aux1')
            self.assertEqual(dest.execute('select count(*) from a').scalar(),
                             2)

        # src_name is accepted as a deprecated alias for name.
        with Connection(':memory:') as dest:
            self.db.backup(dest, src_name='aux1')
            self.assertEqual(dest.execute('select count(*) from a').scalar(),
                             2)

        # Backup main into an attached database on the destination.
        with Connection(':memory:') as dest:
            dest.attach(':memory:', 'aux2')
            self.db.backup(dest, dest_name='aux2')
            self.assertEqual(
                dest.execute('select count(*) from aux2.g').scalar(), 100)
            self.assertEqual(dest.get_tables(), [])

    def test_backup_progress(self):
        accum = []

        def progress_cb(remaining, page_count, is_done):
            accum.append((remaining, page_count, is_done))

        with Connection(':memory:') as dest:
            self.db.backup(dest, pages=1, progress=progress_cb)

        self.assertTrue(len(accum) > 0)
        self.assertTrue(accum[-1][2])
        for remaining, page_count, is_done in accum:
            self.assertGreaterEqual(page_count, 0)
            self.assertGreaterEqual(remaining, 0)

    def test_backup_progress_exception(self):
        def broken_progress(remaining, page_count, is_done):
            raise ValueError('fail')

        with Connection(':memory:') as dest:
            with self.assertRaises(ValueError) as ctx:
                self.db.backup(dest, pages=1, progress=broken_progress)

        self.assertIn('fail', str(ctx.exception))


@unittest.skipUnless(HAS_DESERIALIZE,
                     'SQLite built without serialize support')
class TestSerialize(BaseTestCase):
    def test_serialize_deserialize(self):
        with Connection(':memory:') as conn:
            data = conn.serialize()
            self.assertIsInstance(data, bytes)

        with Connection(':memory:') as conn:
            conn.execute('create table g(k)')
            conn.executemany('insert into g(k) values (?)',
                             [(v,) for v in 'abc'])
            data = conn.serialize()
            self.assertTrue(data.startswith(b'SQLite format 3'))

        with Connection(':memory:') as conn:
            conn.deserialize(data)
            curs = conn.execute('select * from g order by k')
            self.assertEqual([r[0] for r in curs], ['a', 'b', 'c'])

            data2 = conn.serialize()

        self.assertEqual(data, data2)

    def test_deserialize_empty(self):
        with Connection(':memory:') as conn:
            self.assertRaises(ValueError, conn.deserialize, b'')

    def test_deserialize_in_transaction(self):
        conn = Connection(':memory:')
        conn.execute('create table t (x)')
        data = conn.serialize()

        conn.begin()
        try:
            with self.assertRaises(OperationalError):
                conn.deserialize(data)
        finally:
            conn.rollback()

    def test_deserialize_unknown_schema(self):
        conn = Connection(':memory:')
        conn.execute('create table t (x)')
        data = conn.serialize()

        with self.assertRaises(OperationalError):
            conn.deserialize(data, name='nonexistent')

    def test_deserialize_preserves_schema(self):
        conn = Connection(':memory:')
        conn.execute('create table original (a)')
        conn.execute('insert into original values (1)')

        other = Connection(':memory:')
        other.execute('create table replacement (b)')
        other.execute('insert into replacement values (?)', ('hello',))
        data = other.serialize()
        other.close()

        conn.deserialize(data)

        # Original table is gone.
        with self.assertRaises(OperationalError):
            conn.execute('select * from original')

        # Replacement table is present.
        rows = list(conn.execute('select * from replacement'))
        self.assertEqual(rows, [('hello',)])

    def test_deserialize_bytearray(self):
        with Connection(':memory:') as src:
            src.execute('create table t (x)')
            src.execute('insert into t values (?)', (42,))
            data = src.serialize()

        for buf in (bytearray(data), memoryview(data)):
            conn = Connection(':memory:')
            conn.deserialize(buf)
            self.assertEqual(conn.execute('select * from t').fetchone(), (42,))

    def test_deserialize_garbage_installs_but_fails_on_read(self):
        conn = Connection(':memory:')
        conn.deserialize(b'not a database' * 1024)
        with self.assertRaises(DatabaseError):
            conn.execute('select 1 from sqlite_master').fetchall()

    def test_deserialize_requires_attached_schema(self):
        # deserialize() requires the target schema to already be attached.
        with Connection(':memory:') as src:
            src.execute('create table t (v)')
            src.execute('insert into t values (?)', ('payload',))
            data = src.serialize()

        conn = Connection(':memory:')

        # Sanity check: 'main' and 'temp' are always attached.
        attached = {row[0] for row in conn.database_list()}
        self.assertIn('main', attached)
        self.assertNotIn('snapshot', attached)

        # Deserializing into a non-attached schema fails.
        with self.assertRaises(OperationalError):
            conn.deserialize(data, name='snapshot')

        # The failed call did not silently create or populate 'snapshot'.
        attached_after = {row[0] for row in conn.database_list()}
        self.assertNotIn('snapshot', attached_after)

        # Attach it properly, then deserialize works.
        conn.execute("attach ':memory:' as snapshot")
        conn.deserialize(data, name='snapshot')

        rows = list(conn.execute('select v from snapshot.t'))
        self.assertEqual(rows, [('payload',)])

        conn.close()

    def test_serialize_ensure_conn(self):
        conn = Connection(':memory:')
        conn.close()
        with self.assertRaises(OperationalError):
            conn.serialize()

        conn = Connection(':memory:')
        data = Connection(':memory:').serialize()
        conn.close()
        with self.assertRaises(OperationalError):
            conn.deserialize(data)


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
        self.assertEqual(curs.scalar(), 0)  # value() recycles curs.
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

    def test_statement_exhaustion(self):
        self.db.cached_statements = 10
        self.create_table()
        self.create_rows(('k1', 'v1', 1), ('k2', 'v2', 2))
        cursors = []
        for i in range(100):
            cursor = self.db.execute('select key from kv order by key')
            cursors.append(cursor)
            self.assertEqual(self.db.get_stmt_usage(), (2, i + 1))

        for cursor in cursors:
            self.assertEqual(cursor.fetchall(), [('k1',), ('k2',)])

        self.assertEqual(self.db.get_stmt_usage(), (3, 0))

    def test_statement_cache_fill(self):
        self.db.cached_statements = 10
        self.db.execute('create table g(k)')
        for i in range(20):
            self.db.execute('insert into g(k) values (%s)' % i)
        self.assertEqual(self.db.get_stmt_usage(), (10, 0))
        self.assertEqual(self.db.execute('select count(*) from g').scalar(), 20)

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

    def test_stmt_leak_on_bind_error(self):
        self.create_table()
        cursor = self.db.cursor()

        cursor.execute('SELECT * FROM kv WHERE id = ?', (1,))
        cursor.close()

        avail_before, in_use_before = self.db.get_stmt_usage()

        cursor = self.db.cursor()
        # bind() will fail due to wrong number of params.
        with self.assertRaises(OperationalError):
            cursor.execute('SELECT * FROM kv WHERE id = ?', (1, 2))

        cursor.execute('SELECT 1')
        cursor.close()

        avail_after, in_use_after = self.db.get_stmt_usage()
        # No leaked statements.
        self.assertEqual(in_use_after, in_use_before,
                         'Statement leaked in stmt_in_use after bind error')

    def test_abort_leaks_stmt_in_use(self):
        self.create_table()
        _, in_use_before = self.db.get_stmt_usage()

        cursor = self.db.cursor()
        # Force a step error: insert a duplicate primary key.
        self.db.execute('INSERT INTO kv (id, key, value) VALUES (1, "a", "b")')
        with self.assertRaises(IntegrityError):
            cursor.execute('INSERT INTO kv (id, key, value) VALUES (1, "c", "d")')

        _, in_use_after = self.db.get_stmt_usage()
        self.assertEqual(in_use_after, in_use_before,
                         'Finalized statement leaked in stmt_in_use after abort')


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

        # Ensure buffer-types are handled properly.
        ba = bytearray(b'y' * 16)
        blob.write(ba)
        self.assertEqual(blob.tell(), 16)

        blob.seek(0)
        ba[0:4] = b'zzzx'
        mv = memoryview(ba[:5])
        blob.write(mv)
        self.assertEqual(blob.tell(), 5)

        blob.seek(0)
        data = blob.read(16)
        self.assertEqual(data, b'zzzxyyyyyyyyyyyy')

        # Strings are utf8-encoded automatically.
        blob.seek(0)
        blob.write('abcd\u2022')
        blob.seek(0)
        self.assertEqual(blob.read(8), b'abcd\xe2\x80\xa2y')

    def test_blob_readall(self):
        rowid = self.create_blob_row(8)
        blob = Blob(self.db, 'register', 'data', rowid)
        blob.write(b'abcdefg')
        blob.seek(0)
        self.assertEqual(blob.readall(), b'abcdefg\x00')
        self.assertEqual(blob.tell(), 8)

        blob.seek(4)
        self.assertEqual(blob.readall(), b'efg\x00')

        blob.close()

    def test_blob_read_clamps_size(self):
        # Oversized read requests are clamped to the remaining bytes, like
        # other file-like objects (no OverflowError for size > INT_MAX).
        rowid = self.create_blob_row(8)
        blob = Blob(self.db, 'register', 'data', rowid)
        blob.write(b'abcdefgh')
        blob.seek(0)
        self.assertEqual(blob.read(2 ** 40), b'abcdefgh')
        self.assertEqual(blob.read(2 ** 40), b'')
        blob.seek(6)
        self.assertEqual(blob.read(100), b'gh')
        self.assertEqual(blob.read(0), b'')
        blob.close()

    def test_blob_iobase_methods(self):
        rowid64 = self.create_blob_row(64)
        blob = Blob(self.db, 'register', 'data', rowid64)

        lines = b'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n'
        blob.write(lines)
        self.assertEqual(blob.tell(), 35)

        blob.seek(0)
        lines = blob.readlines(15)
        self.assertEqual(lines, [
            b'Line 1\n',
            b'Line 2\n',
            b'Line 3\n'])
        self.assertEqual(blob.tell(), 21)

        self.assertEqual(blob.readline(), b'Line 4\n')
        blob.seek(21)

        lines = [b'Line 4x\n', b'Line 5x\n', b'Line 6x\n']
        blob.writelines(lines)
        self.assertEqual(blob.tell(), 45)

        blob.seek(0)
        self.assertEqual(list(blob), [
            b'Line 1\n',
            b'Line 2\n',
            b'Line 3\n',
            b'Line 4x\n',
            b'Line 5x\n',
            b'Line 6x\n',
            b'\x00' * (64 - 45),
        ])

        blob.seek(7)
        buf = bytearray(14)
        n = blob.readinto(buf)
        self.assertEqual(n, 14)
        self.assertEqual(bytes(buf), b'Line 2\nLine 3\n')

        buf = bytearray(0)
        n = blob.readinto(buf)
        self.assertEqual(n, 0)
        self.assertEqual(bytes(buf), b'')

    def test_blob_item_index(self):
        rowid = self.create_blob_row(16)
        blob = Blob(self.db, 'register', 'data', rowid)

        self.assertEqual(blob[0], 0)
        self.assertEqual(blob[15], 0)

        blob.write(b'\x01\x02\x03')
        blob.seek(0)
        self.assertEqual(blob[0], 1)
        self.assertEqual(blob[1], 2)
        self.assertEqual(blob[2], 3)

        blob[-2] = 0xfe
        blob[15] = 0xff

        with self.assertRaises(ValueError):
            blob[14] = 256

        with self.assertRaises(ValueError):
            blob[14] = b'\xaa\xbb'

        with self.assertRaises(IndexError):
            blob[16] = b'\xcc'
        with self.assertRaises(IndexError):
            blob[-17] = b'\xcc'

        self.assertEqual(blob[-1], 0xff)
        self.assertEqual(blob[-2], 0xfe)
        self.assertEqual(blob[-16], 1)
        blob.close()

        blob = Blob(self.db, 'register', 'data', rowid, read_only=True)
        with self.assertRaises(io.UnsupportedOperation):
            blob[0] = 0xff

    def test_blob_item_slice(self):
        rowid = self.create_blob_row(16)
        blob = Blob(self.db, 'register', 'data', rowid)

        data = bytes(range(16))
        blob.write(data)
        self.assertEqual(blob.tell(), 16)
        blob.seek(2)

        self.assertEqual(blob[0:4], b'\x00\x01\x02\x03')
        self.assertEqual(blob[4:8], b'\x04\x05\x06\x07')
        self.assertEqual(blob[14:16], b'\x0e\x0f')

        self.assertEqual(blob[0:0], b'')
        self.assertEqual(blob[4:4], b'')

        self.assertEqual(blob[:100], data)
        self.assertEqual(blob[-100:], data)

        # Our position hasn't changed.
        self.assertEqual(blob.tell(), 2)

        with self.assertRaises(ValueError):
            blob[0:4] = b'\xff\xff'
        with self.assertRaises(ValueError):
            blob[0:4] = b'\xff\xff\xff\xff\xff'

        self.assertEqual(blob[0:4], b'\x00\x01\x02\x03')

        blob[0:4] = b'\xff\xfe\xfd\xfc'
        self.assertEqual(blob[0:4], b'\xff\xfe\xfd\xfc')
        self.assertEqual(blob[4:8], b'\x04\x05\x06\x07')
        blob.close()

        blob = Blob(self.db, 'register', 'data', rowid, read_only=True)
        with self.assertRaises(io.UnsupportedOperation):
            blob[0:2] = b'\xff\xfe'

    def test_blob_exceed_size(self):
        rowid = self.create_blob_row(16)

        blob = self.db.blob_open('register', 'data', rowid)
        with self.assertRaises(ValueError):
            blob.seek(17, 0)

        with self.assertRaises(IndexError):
            blob[16]
        with self.assertRaises(IndexError):
            blob[-17]

        with self.assertRaises(ValueError):
            blob.write(b'x' * 17)

        with self.assertRaises(ValueError):
            blob.write(bytearray(b'x' * 17))

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

        with self.assertRaises(ValueError):
            len(blob)

        self.assertRaises(ValueError, blob.read)
        self.assertRaises(ValueError, blob.write, b'foo')
        self.assertRaises(ValueError, blob.seek, 0, 0)
        self.assertRaises(ValueError, blob.tell)
        self.assertRaises(ValueError, blob.reopen, rowid)

    def test_blob_db_closed(self):
        rowid = self.create_blob_row(4)
        blob = self.db.blob_open('register', 'data', rowid)

        self.db.close()

        for i in range(2):
            if i == 1: self.db.connect()  # Reconnect for 2nd iteration.
            # Cannot operate on the blob - db was closed, even if it was
            # reopened later the handle is invalid.
            self.assertRaises(ValueError, blob.read)
            self.assertRaises(ValueError, blob.write, b'foo')
            self.assertRaises(ValueError, blob.seek, 0, 0)
            self.assertRaises(ValueError, blob.tell)
            self.assertRaises(ValueError, blob.reopen, rowid)

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
        with self.assertRaises(io.UnsupportedOperation):
            blob.write(b'meow')
        with self.assertRaises(io.UnsupportedOperation):
            blob.writelines([b'meow\n'])

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


class TestLargeValues(BaseTestCase):
    filename = ':memory:'

    def setUp(self):
        super(TestLargeValues, self).setUp()
        self.db.execute('create table g (id integer not null primary key, '
                        'value text not null)')

    def assertCount(self, ct):
        self.assertEqual(self.db.execute('select count(*) from g').scalar(), ct)

    def test_large_insert_select(self):
        data = [(i, 'v%08d' % i) for i in range(10000)]
        self.db.executemany('insert into g (id, value) values (?, ?)', data)
        self.assertCount(10000)

        params = ', '.join(['(?, ?)'] * 100)
        data = []
        for i in range(10000, 10100):
            data.extend((i, 'v%08d' % i))
        self.db.execute('insert into g values %s' % params, data)
        self.assertCount(10100)

        res = self.db.execute('select * from g').fetchall()
        self.assertEqual(len(res), 10100)

    def test_large_column_list(self):
        columns = ', '.join(['col%d' % i for i in range(100)])
        self.db.execute(f'CREATE TABLE test (%s)' % columns)

        params = ', '.join(['?' for _ in range(100)])
        self.db.execute('INSERT INTO test VALUES (%s)' % params,
                        list(range(100)))

        curs = self.db.execute('SELECT * FROM test')
        self.assertEqual(len(curs.fetchone()), 100)
        self.assertEqual(curs.description,
                         tuple(('col%d' % i,) for i in range(100)))

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
        self.stop = stop if stop is not None else float('inf')
        self.step = step
        self.curr = self.start

    def iterate(self, idx):
        if ((self.step > 0 and self.curr > self.stop) or
            (self.step < 0 and self.curr < self.stop)):
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

class MemStore(TableFunction):
    name = 'memstore'
    columns = [
        ('id', 'INTEGER'),
        ('key', 'TEXT'),
        ('value', 'TEXT')]
    params = []
    with_rowid = True

    _data = {}
    _next_id = 1

    def initialize(self, **filters):
        pass

    def iterate(self, idx):
        keys = sorted(self._data.keys())
        if idx >= len(keys):
            raise StopIteration

        rowid = keys[idx]
        row = self._data[rowid]
        return (rowid, (row['id'], row['key'], row['value']))

    def insert(self, rowid, values):
        # rowid might be None, so we auto-generate
        if rowid is None:
            rowid = self._next_id
            MemStore._next_id += 1
        else:
            rowid = int(rowid)
            if rowid >= MemStore._next_id:
                MemStore._next_id = rowid + 1

        if len(values) < 3:
            raise ValueError('Expected 3 values, got %s' % len(values))

        u_rowid, key, value = values
        self._data[rowid] = {
            'id': int(u_rowid) if u_rowid is not None else rowid,
            'key': str(key) if key is not None else key,
            'value': str(value) if value is not None else value,
        }

        return rowid

    def update(self, old_rowid, new_rowid, values):
        old_rowid = int(old_rowid)
        new_rowid = int(new_rowid)

        if old_rowid not in self._data:
            raise ValueError('Row %s not found' % old_rowid)

        if len(values) < 3:
            raise ValueError('Expected 3 values, got %s' % len(values))

        uid, key, value = values
        if uid:
            new_rowid = uid

        if old_rowid != new_rowid:
            self._data[new_rowid] = self._data.pop(old_rowid)
            rowid = new_rowid
        else:
            rowid = old_rowid

        if uid:
            self._data[rowid]['id'] = int(uid)
        if key is not None:
            self._data[rowid]['key'] = key
        if value is not None:
            self._data[rowid]['value'] = value

    def delete(self, rowid):
        rowid = int(rowid)
        if rowid not in self._data:
            raise ValueError('Row %s not found' % rowid)
        del self._data[rowid]


class TestTableFunction(BaseTestCase):
    def execute(self, sql, params=None):
        return self.db.execute(sql, params or ())

    def test_split(self):
        Split.register(self.db)
        curs = self.execute('select part from str_split(?) order by part '
                            'limit 3', ('well hello huey and zaizee',))
        self.assertEqual([row for row, in curs],
                         ['and', 'hello', 'huey'])

    def test_table_function_survives_reconnect(self):
        Series.register(self.db)
        curs = self.execute('select * from series(0, 2)')
        self.assertEqual(list(curs), [(0,), (1,), (2,)])

        self.db.close()
        self.db.connect()

        curs = self.execute('select * from series(0, 2)')
        self.assertEqual(list(curs), [(0,), (1,), (2,)])

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

    def test_readonly_behavior(self):
        Split.register(self.db)
        with self.assertRaises(OperationalError):
            self.execute('insert into str_split (part) values (?)', ('k1',))
        with self.assertRaises(OperationalError):
            self.execute('update str_split set part = ?', ('k1',))
        with self.assertRaises(OperationalError):
            self.execute('delete from str_split')

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

    def test_series_partial_params(self):
        # Only a subset of the params is constrained: the partially-
        # constrained plan is used and missing params fall back to the
        # initialize() defaults.
        Series.register(self.db)
        curs = self.db.execute('SELECT value FROM series '
                               'WHERE start = 2 AND step = 3 LIMIT 3')
        self.assertEqual([v for v, in curs], [2, 5, 8])

        curs = self.db.execute('SELECT value FROM series '
                               'WHERE start = 2 AND stop = 4')
        self.assertEqual([v for v, in curs], [2, 3, 4])

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
        # The table function cursor is re-filtered once per outer row, and each
        # filter pass restarts iteration (and thus the implicit per-scan rowid)
        # at 1.
        self.assertEqual(list(curs), [
            (1, 1, 'foo@example.fap'),
            (1, 2, 'nuggie@example.fap'),
            (2, 1, 'baz@example.com'),
            (2, 2, 'charlie@crappyblog.com'),
            (2, 3, 'huey@example.com'),
        ])

    def test_writeable(self):
        MemStore.register(self.db)
        curs = self.db.execute('insert into memstore (id, key, value) '
                               'values (?, ?, ?)', (1, 'k1', 'v1'))
        self.assertEqual(curs.lastrowid, 1)
        self.assertEqual(self.db.last_insert_rowid(), 1)

        curs = self.db.execute('insert into memstore (key, value) '
                               'values (?, ?), (?, ?)',
                               ('k2', 'v2', 'k3', 'v3'))
        self.assertEqual(curs.lastrowid, 3)
        self.assertEqual(self.db.last_insert_rowid(), 3)

        def assertValues(*expected):
            res = self.db.execute('select * from memstore order by key')
            self.assertEqual(res.fetchall(), list(expected))

        assertValues((1, 'k1', 'v1'), (2, 'k2', 'v2'), (3, 'k3', 'v3'))

        curs = self.db.execute('update memstore set value = ? '
                               'where key = ?', ('v2y', 'k2'))
        assertValues((1, 'k1', 'v1'), (2, 'k2', 'v2y'), (3, 'k3', 'v3'))

        self.db.execute('update memstore set value = value || ?', ('zz',))
        self.db.execute('update memstore set value = NULL where key = ?',
                        ('xyz',))
        assertValues((1, 'k1', 'v1zz'), (2, 'k2', 'v2yzz'), (3, 'k3', 'v3zz'))

        self.db.execute('update memstore set id = ? where id = ?',
                        (4, 3))
        assertValues((1, 'k1', 'v1zz'), (2, 'k2', 'v2yzz'), (4, 'k3', 'v3zz'))

        self.assertEqual(MemStore._data, {
            1: {'id': 1, 'key': 'k1', 'value': 'v1zz'},
            2: {'id': 2, 'key': 'k2', 'value': 'v2yzz'},
            4: {'id': 4, 'key': 'k3', 'value': 'v3zz'},
        })

        self.db.execute('delete from memstore where key = ?', ('k2',))
        assertValues((1, 'k1', 'v1zz'), (4, 'k3', 'v3zz'))

        self.assertEqual(MemStore._data, {
            1: {'id': 1, 'key': 'k1', 'value': 'v1zz'},
            4: {'id': 4, 'key': 'k3', 'value': 'v3zz'},
        })

        self.db.execute('delete from memstore where key = ?', ('k2',))
        assertValues((1, 'k1', 'v1zz'), (4, 'k3', 'v3zz'))

        self.db.execute('update memstore set value = ? where id = ?',
                        ('v3', 4))
        assertValues((1, 'k1', 'v1zz'), (4, 'k3', 'v3'))

        res = self.db.execute('select rowid, id, key from memstore '
                              'order by id').fetchall()
        self.assertEqual(res, [(1, 1, 'k1'), (4, 4, 'k3')])

        self.db.execute('delete from memstore')
        assertValues()

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

        for i in range(10):
            curs = self.execute('SELECT * FROM somewhat_broken(5, 8)')
            self.assertEqual(curs.fetchone(), (5,))
            self.assertRaises(OperationalError, lambda: list(curs))

        curs = self.execute('SELECT * FROM somewhat_broken(0, 2)')
        self.assertEqual(list(curs), [(0,), (1,), (2,)])

    def test_table_func_impl_released_on_close(self):
        import gc
        import weakref

        db = connect(':memory:')

        # Create the class dynamically so we control all references to it.
        MyFunc = type('MyFunc', (TableFunction,), {
            'columns': [('val', 'TEXT')],
            'params': ['seed'],
            'name': 'my_leak_test',
            'initialize': lambda self, seed=None: setattr(self, '_v', seed),
            'iterate': lambda self, idx: (_ for _ in ()).throw(StopIteration)
                       if idx > 0 else (self._v,),
        })

        MyFunc.register(db)
        ref = weakref.ref(MyFunc)

        # Drop reference to the class.
        del MyFunc
        gc.collect()

        # Class must still be alive as the module is in use.
        self.assertIsNotNone(ref())

        # Closing fires xDestroy, which DECREFs the _TableFunctionImpl. The
        # class is still retained by db.registrations for replay on
        # reconnect, so the connection itself must go away too.
        db.close()
        del db
        gc.collect()

        # Reference should be dead since the module is no longer alive.
        self.assertIsNone(ref(),
                          '_TableFunctionImpl leaked: table function class '
                          'still alive after connection closed')

    def test_vtab_refilter_no_leak(self):
        Series.register(self.db)

        self.db.execute('create table t (n integer)')
        self.db.executemany('insert into t values (?)',
                            [(i,) for i in range(5)])

        # A correlated subquery forces SQLite to call xFilter on the
        # inner cursor once per outer row, re-filtering the same cursor.
        rows = list(self.db.execute(
            'select t.n, s.value from t, series(0, t.n, 1) as s'))

        expected = []
        for n in range(5):
            for v in range(n + 1):
                expected.append((n, v))
        self.assertEqual(sorted(rows), sorted(expected))

    def test_column_conversion_error(self):
        # A column value that cannot be converted to a SQLite value raises,
        # chaining the conversion error as __cause__.
        class BadValue(TableFunction):
            columns = ['v']
            params = []
            name = 'badvalue'
            def initialize(self): pass
            def iterate(self, idx):
                if idx > 0:
                    raise StopIteration
                return ({'not': 'supported'},)

        BadValue.register(self.db)
        with self.assertRaises(OperationalError) as ctx:
            self.db.execute('select v from badvalue()').fetchall()
        self.assertIsInstance(ctx.exception.__cause__, TypeError)


class TestTableFunctionRefactor(BaseTestCase):
    filename = ':memory:'

    def test_columns_required_at_definition_time(self):
        # Subclasses that set columns to garbage should fail at the
        # class statement, not later at register() time.
        with self.assertRaises(ProgrammingError):
            class Bad1(TableFunction):
                columns = [123]  # not a string and not a 2-tuple
                def initialize(self): pass
                def iterate(self, idx): raise StopIteration

        with self.assertRaises(ProgrammingError):
            class Bad2(TableFunction):
                columns = [('a', 'INTEGER', 'extra')]  # 3-tuple
                def initialize(self): pass
                def iterate(self, idx): raise StopIteration

        with self.assertRaises(ProgrammingError):
            class Bad3(TableFunction):
                columns = 'a,b,c'  # not a list/tuple
                def initialize(self): pass
                def iterate(self, idx): raise StopIteration

    def test_params_must_be_sequence(self):
        with self.assertRaises(ProgrammingError):
            class Bad(TableFunction):
                columns = ['a']
                params = 'not-a-list'

    def test_register_without_columns_raises(self):
        class NoCols(TableFunction):
            # columns intentionally unset on the subclass
            pass
        with self.assertRaises(ProgrammingError):
            NoCols.register(self.db)

    def test_register_does_not_mutate_class(self):
        # The class's `name` attribute must remain None when not set;
        # the impl resolves the default name without writing it back.
        class Anon(TableFunction):
            columns = ['v']
            def initialize(self): pass
            def iterate(self, idx): raise StopIteration

        self.assertIsNone(Anon.name)
        Anon.register(self.db)
        self.assertIsNone(Anon.name)
        # The function is reachable under its class name.
        list(self.db.execute('select * from Anon'))

    def assertChainCause(self, tbl_func, exc_type, err_msg):
        tbl_func.register(self.db)
        with self.assertRaises(OperationalError) as cm:
            list(self.db.execute('select * from %s' % tbl_func.name))

        self.assertIsInstance(cm.exception.__cause__, exc_type)
        if err_msg is not None:
            self.assertEqual(str(cm.exception.__cause__), err_msg)

    def test_iterate_exception_chains_as_cause(self):
        class Boom(TableFunction):
            name = 'boom'
            columns = ['v']
            def initialize(self): self.i = 0
            def iterate(self, idx):
                if self.i == 0:
                    self.i += 1
                    return (1,)
                raise RuntimeError('boom from iterate')

        self.assertChainCause(Boom, RuntimeError, 'boom from iterate')

    def test_initialize_exception_chains_as_cause(self):
        class BadInit(TableFunction):
            name = 'bad_init'
            columns = ['v']
            def initialize(self): raise ValueError('init fail')
            def iterate(self, idx): raise StopIteration

        self.assertChainCause(BadInit, ValueError, 'init fail')

    def test_iterate_wrong_shape_chains_as_cause(self):
        # iterate() returning the wrong number of values should now
        # produce a clear ValueError chained as __cause__, not a silent
        # SQLITE_ERROR.
        class WrongShape(TableFunction):
            name = 'wrong_shape'
            columns = ['a', 'b']  # 2 columns expected
            def initialize(self): pass
            def iterate(self, idx):
                return (1, 2, 3)  # 3 values

        self.assertChainCause(WrongShape, ValueError, None)

    def test_iterate_non_tuple_chains_as_cause(self):
        class BareValue(TableFunction):
            name = 'bare_value'
            columns = ['a']
            def initialize(self): self.done = False
            def iterate(self, idx):
                if self.done: raise StopIteration
                self.done = True
                return 42  # Forgot the trailing comma.

        self.assertChainCause(BareValue, TypeError, None)

    def test_with_rowid_validates_shape(self):
        class BadRowid(TableFunction):
            name = 'bad_rowid'
            columns = ['a']
            with_rowid = True
            def initialize(self): pass
            def iterate(self, idx):
                return (42,)  # not a (rowid, tuple) pair

        self.assertChainCause(BadRowid, ValueError, None)

    def test_idx_driven_function_in_join(self):
        # SQLite reuses one cursor across xFilter calls when a table function
        # is on the inner side of a join. Regression: cyFilter did not reset
        # the iteration index, so an idx-driven function returned only its
        # first row on every filter pass after the first.
        class IdxCounter(TableFunction):
            name = 'idx_counter'
            columns = ['value']
            params = ['n']
            def initialize(self, n=0):
                self.n = n
            def iterate(self, idx):
                if idx >= self.n:
                    raise StopIteration
                return (idx,)

        IdxCounter.register(self.db)
        self.db.execute('create table t (x)')
        self.db.executemany('insert into t values (?)', [(1,), (2,), (3,)])
        got = sorted(self.db.execute(
            'select t.x, c.value from t, idx_counter(t.x) as c').fetchall())
        self.assertEqual(got, [(1, 0), (2, 0), (2, 1),
                               (3, 0), (3, 1), (3, 2)])


class TestCreateTableFunction(BaseTestCase):
    filename = ':memory:'

    def values(self, sql, params=None):
        return [row for row, in self.db.execute(sql, params)]

    def test_generator_positional_args(self):
        def series(start, stop, step=1):
            i = start
            while i < stop:
                yield (i,)
                i += step

        self.db.create_table_function(series, columns=['value'])
        self.assertEqual(self.values('select value from series(0, 5, 1)'),
                         [0, 1, 2, 3, 4])
        self.assertEqual(self.values('select value from series(0, 10, 2)'),
                         [0, 2, 4, 6, 8])

    def test_optional_param_uses_default(self):
        def series(start, stop, step=1):
            i = start
            while i < stop:
                yield (i,)
                i += step

        self.db.create_table_function(series, columns=['value'])
        # step omitted -> falls back to the signature default of 1.
        self.assertEqual(self.values('select value from series(1, 4)'),
                         [1, 2, 3])

    def test_all_optional_zero_arg_call(self):
        # Every param has a default, so the function may be called with no
        # args at all (cyBestIndex treats defaulted params as optional).
        def nums(start=0, stop=3):
            for i in range(start, stop):
                yield (i,)

        self.db.create_table_function(nums, columns=['value'])
        self.assertEqual(self.values('select value from nums()'), [0, 1, 2])
        self.assertEqual(self.values('select value from nums(2, 6)'),
                         [2, 3, 4, 5])

    def test_required_param_missing_errors(self):
        def series(start, stop, step=1):
            i = start
            while i < stop:
                yield (i,)
                i += step

        self.db.create_table_function(series, columns=['value'])
        # `start`/`stop` have no default -> calling with none of them errors.
        with self.assertRaises(OperationalError):
            list(self.db.execute('select value from series()'))

    def test_explicit_null_vs_omitted(self):
        # An omitted optional param uses the Python default; an explicit NULL
        # is passed through as None and overrides it. (Column names must differ
        # from the param/hidden-column names a/b.)
        def f(a, b='dflt'):
            yield (a, b)

        self.db.create_table_function(f, columns=['col_a', 'col_b'])
        self.assertEqual(list(self.db.execute('select col_a, col_b from f(1)')),
                         [(1, 'dflt')])
        self.assertEqual(
            list(self.db.execute('select col_a, col_b from f(1, ?)', (None,))),
            [(1, None)])

    def test_function_returning_list_and_list_rows(self):
        def pairs():
            return [[1, 'a'], [2, 'b']]  # returns a list, rows are lists

        self.db.create_table_function(pairs, columns=['k', 'v'])
        self.assertEqual(list(self.db.execute('select * from pairs()')),
                         [(1, 'a'), (2, 'b')])

    def test_name_override(self):
        def gen():
            yield ('x',)
        self.db.create_table_function(gen, name='renamed', columns=['v'])
        self.assertEqual(self.values('select v from renamed()'), ['x'])

    def test_decorator_registers_and_returns_callable(self):
        @self.db.table_function(columns=['value'])
        def series(start, stop):
            i = start
            while i < stop:
                yield (i,)
                i += 1

        self.assertEqual(self.values('select value from series(0, 3)'),
                         [0, 1, 2])
        # The decorator returns the original callable unchanged.
        self.assertEqual([row for row, in series(0, 2)], [0, 1])

    def test_columns_fallback_to_fn_attribute(self):
        def gen():
            yield ('a', 1)
        gen.columns = ['name', 'n']
        self.db.create_table_function(gen)  # no columns arg
        self.assertEqual(list(self.db.execute('select * from gen()')),
                         [('a', 1)])

    def test_missing_columns_raises(self):
        def gen():
            yield (1,)
        with self.assertRaises(ProgrammingError):
            self.db.create_table_function(gen)

    def test_iterate_exception_chains_as_cause(self):
        def boom(n):
            for i in range(n):
                if i == 2:
                    raise RuntimeError('kaboom')
                yield (i,)

        self.db.create_table_function(boom, columns=['value'])
        with self.assertRaises(OperationalError) as cm:
            list(self.db.execute('select value from boom(5)'))
        self.assertIsInstance(cm.exception.__cause__, RuntimeError)
        self.assertEqual(str(cm.exception.__cause__), 'kaboom')

    def test_from_function_registers_per_connection(self):
        def series(start, stop, step=1):
            i = start
            while i < stop:
                yield (i,)
                i += step

        # Building the class requires no connection.
        cls = TableFunction.from_function(series, columns=['value'])
        self.assertTrue(issubclass(cls, TableFunction))
        self.assertEqual((cls.name, cls.params), ('series',
                                                  ['start', 'stop', 'step']))

        cls.register(self.db)
        self.assertEqual(self.values('select value from series(0, 3)'),
                         [0, 1, 2])

        db2 = Connection(':memory:')
        try:
            cls.register(db2)
            self.assertEqual(
                [r for r, in db2.execute('select value from series(2, 5)')],
                [2, 3, 4])
        finally:
            db2.close()


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

    def test_dlevdist_adjacent_start(self):
        self.assertDLev('ba', 'ab', 1)
        self.assertDLev('ab', 'ba', 1)
        self.assertDLev('ca', 'ac', 1)
        self.assertDLev('21', '12', 1)
        self.assertDLev('bac', 'abc', 1)
        self.assertDLev('abc', 'bac', 1)
        self.assertDLev('bacd', 'abcd', 1)
        self.assertDLev('abcd', 'bacd', 1)

        # Single-char strings - no transposition possible.
        self.assertDLev('a', 'b', 1)

        # Two-char string, no transposition (different chars).
        self.assertDLev('ab', 'cd', 2)

    def test_dlevdist_empty_string(self):
        self.assertDLev('', '', 0)
        self.assertDLev('a', '', 1)
        self.assertDLev('', 'a', 1)
        self.assertDLev('ab', '', 2)
        self.assertDLev('', 'ab', 2)


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
        res = self.db.execute_scalar('select median(x) from g')
        self.assertEqual(res, expected)

    def test_median_aggregate(self):
        self.assertMedian(None)
        self.store(1)
        self.assertMedian(1)
        self.store(3, 1, 6, 6, 6, 7, 7, 7, 7, 12, 12, 17)
        self.assertMedian(7)
        self.store(9, 2, 2, 3, 3, 1)
        self.assertMedian(2.5)
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
            ('k1', 3, 7),   ('k1', 6, 7),   ('k1', 6, 7),   ('k1', 7, 7),
            ('k1', 7, 7),   ('k1', 7, 7),   ('k1', 17, 7),
            ('k2', 9, 2.5), ('k2', 2, 2.5), ('k2', 3, 2.5), ('k2', 1, 2.5),
            ('k3', 4, 4),   ('k3', 4, 4),   ('k3', 8, 4),   ('k3', 2, 4),
            ('k3', 2, 4),   ('k3', 8, 4),   ('k3', 1, 4),
            ('k4', 1, 10),  ('k4', 10000, 10), ('k4', 10, 10)])

    def test_median_window_null(self):
        # NULLs are ignored by step() and inverse() alike. The moving frame
        # exercises inverse() as NULL rows leave the window.
        self.db.execute('insert into g(x, k) values (1, 1), (2, NULL), '
                        '(3, 3), (4, 4)')
        curs = self.db.execute(
            'select median(k) over (order by id rows between 1 preceding '
            'and current row) from g')
        self.assertEqual(list(curs), [(1,), (1,), (3,), (3.5,)])


#
# Utils.
#
from cysqlite.utils import Pool


class TestPool(unittest.TestCase):
    filename = '/tmp/cysqlite.db'

    def setUp(self):
        self.pool = Pool(
            self.filename,
            pragmas={'cache_size': -4000})

    def tearDown(self):
        self.pool.close()
        self.cleanup()

    def cleanup(self):
        for filename in glob.glob(self.filename.replace('.db', '*')):
            if os.path.isfile(filename):
                os.unlink(filename)

    def test_pool_pragmas(self):
        for factory in (self.pool.reader, self.pool.writer):
            with factory() as conn:
                self.assertEqual(conn.database, self.filename)
                self.assertEqual(conn.pragma('cache_size'), -4000)
                self.assertEqual(conn.pragma('journal_mode'), 'wal')

    def test_pool_does_not_mutate_pragmas(self):
        pragmas = {'cache_size': -8000}
        pool = Pool(self.filename, readers=1, pragmas=pragmas)
        try:
            with pool.reader() as conn:
                self.assertEqual(conn.pragma('cache_size'), -8000)
                self.assertEqual(conn.pragma('journal_mode'), 'wal')
        finally:
            pool.close()

        # The caller's dict is left untouched by the default pragmas.
        self.assertEqual(pragmas, {'cache_size': -8000})

    def test_reader_read_only(self):
        with self.pool.reader() as conn:
            self.assertEqual(conn.execute_scalar('select 1'), 1)
            with self.assertRaises(OperationalError):
                conn.pragma('application_id', 1337)
            with self.assertRaises(OperationalError):
                conn.execute('create table g(k)')

    def test_reader_resets_tx(self):
        with self.pool.reader() as conn:
            conn.begin()
            self.assertTrue(conn.in_transaction)
        with self.pool.reader() as conn:
            self.assertFalse(conn.in_transaction)

    def test_writer(self):
        with self.pool.writer() as conn:
            conn.execute('create table g(k)')
            conn.execute('insert into g(k) values (?), (?)', ('k1', 'k2'))
            res = conn.execute('select * from g order by k')
            self.assertEqual(res.fetchall(), [('k1',), ('k2',)])

    def test_writer_lock(self):
        with self.pool.writer() as conn:
            conn.execute('create table g(k)')
        def t(n):
            with self.pool.writer() as conn:
                with conn.atomic() as tx:
                    for i in range(n):
                        conn.execute('insert into g(k) values(?)', (i,))
        ts = [threading.Thread(target=t, args=(10,)) for _ in range(8)]
        for t in ts: t.start()
        for t in ts: t.join()
        with self.pool.reader() as conn:
            self.assertEqual(conn.execute_scalar('select count(*) from g'), 80)

    def test_closed(self):
        self.pool.close()
        with self.assertRaises(InterfaceError):
            with self.pool.reader() as conn:
                pass
        with self.assertRaises(InterfaceError):
            with self.pool.writer() as conn:
                pass

    def test_no_writer(self):
        pool = Pool(':memory:', writer=False)
        with self.assertRaises(InterfaceError):
            with pool.writer() as conn:
                pass
        pool.close()


from cysqlite.aio import connect as aconnect
from cysqlite.aio import Pool as APool


class TestAIOConnection(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.db = aconnect(':memory:')

    async def asyncTearDown(self):
        await self.db.close()

    async def create_data(self, nrows):
        await self.db.execute('create table if not exists t(k, v)')
        rows = [(f'k{i:03d}', f'v{i:03d}') for i in range(nrows)]
        await self.db.executemany('insert into t (k, v) values (?, ?)', rows)
        return rows

    async def insert(self, k, v=None):
        await self.db.execute('insert into t (k, v) values (?, ?)', (k, v))

    async def assertT(self, expected):
        curs = await self.db.execute('select k from t order by k')
        ks = [k for k, in await curs.fetchall()]
        self.assertEqual(ks, expected)

    async def test_connect(self):
        db = aconnect(':memory:')
        self.assertIsInstance(db.conn, Connection)
        self.assertTrue(db._thread.is_alive())
        await db.close()

        db = aconnect(':memory:', row_factory=Row, timeout=10.0)
        self.assertEqual(db.conn.row_factory, Row)
        self.assertEqual(db.conn.timeout, 10.0)
        await db.close()

        db = aconnect(':memory:', pragmas={'cache_size': -1000})
        self.assertEqual(await db.pragma('cache_size'), -1000)
        await db.close()

    async def test_connect_context(self):
        async with aconnect(':memory:') as db:
            await db.execute('select 1')
            self.assertFalse(db.conn.is_closed())
        self.assertTrue(db.conn.is_closed())

    async def test_del_shuts_down_worker(self):
        # Simulate GC of an unclosed connection: the worker thread must be
        # told to close the connection and shut down.
        db = aconnect(':memory:')
        await db.execute('select 1')
        thread, conn = db._thread, db.conn
        db.__del__()
        await asyncio.get_running_loop().run_in_executor(
            None, thread.join, 5.0)
        self.assertFalse(thread.is_alive())
        self.assertTrue(conn.is_closed())

        with self.assertRaises(ValueError):
            async with aconnect(':memory:') as db:
                await db.execute('select 1')
                self.assertFalse(db.conn.is_closed())
                raise ValueError
        self.assertTrue(db.conn.is_closed())

    async def test_close_thread_shutdown(self):
        db = aconnect(':memory:')
        self.assertTrue(db._thread.is_alive())
        await db.close()
        db._thread.join(timeout=2.0)
        self.assertFalse(db._thread.is_alive())

    async def test_double_close(self):
        db = aconnect(':memory:')
        self.assertTrue(await db.close())
        await asyncio.wait_for(db.close(), timeout=1.0)
        self.assertFalse(await db.close())

    async def test_close_open_transaction(self):
        # A failed close leaves the worker alive so the caller can recover.
        db = aconnect(':memory:')
        await db.begin()
        with self.assertRaises(OperationalError):
            await db.close()

        self.assertTrue(db._thread.is_alive())
        await db.rollback()
        self.assertTrue(await asyncio.wait_for(db.close(), timeout=2.0))
        self.assertFalse(db._thread.is_alive())

    async def test_execute(self):
        curs = await self.db.execute('select 1')
        self.assertEqual(await curs.fetchall(), [(1,)])

        curs = await self.db.execute('select 2')
        self.assertEqual(await curs.fetchone(), (2,))

        curs = await self.db.execute('select 3 where 0 = 1')
        self.assertEqual(await curs.fetchall(), [])

        curs = await self.db.execute('select 3 where 0 = 1')
        self.assertIsNone(await curs.fetchone())

        self.assertEqual(await self.db.execute_one('select 1'), (1,))
        self.assertIsNone(await self.db.execute_one('select 1 where 0=1'))
        self.assertEqual(await self.db.execute_scalar('select 1'), 1)
        self.assertIsNone(await self.db.execute_scalar('select 1 where 0=1'))

    async def test_execute_table(self):
        await self.create_data(0)

        curs = await self.db.execute('select * from t')
        self.assertEqual(await curs.fetchall(), [])
        self.assertEqual(await curs.fetchmany(10), [])
        self.assertIsNone(await curs.fetchone())

        rows = await self.create_data(101)

        curs = await self.db.execute('select * from t order by k')
        self.assertEqual(await curs.fetchall(), rows)
        self.assertEqual(await curs.fetchall(), [])
        self.assertIsNone(await curs.fetchone())

        curs = await self.db.execute('select * from t order by k')
        self.assertEqual(await curs.fetchone(), rows[0])
        self.assertEqual(await curs.fetchmany(10), rows[1:11])
        self.assertEqual(await curs.fetchmany(10), rows[11:21])
        self.assertEqual(await curs.fetchone(), rows[21])
        self.assertEqual(await curs.fetchall(), rows[22:])
        self.assertIsNone(await curs.fetchone())
        self.assertEqual(await curs.fetchall(), [])
        self.assertEqual(await curs.fetchmany(10), [])

    async def test_execute_helpers(self):
        await self.db.executescript('begin; create table t(k, v); commit;')
        await self.db.executemany('insert into t(k, v) values (?, ?)',
                                  [('k0', 'v0'), ('k1', 'v1')])
        self.assertEqual(await self.db.last_insert_rowid(), 2)
        self.assertEqual(
            await self.db.execute_scalar('select count(*) from t'), 2)

        row = await self.db.execute_one('select * from t order by k')
        self.assertEqual(row, ('k0', 'v0'))

    async def test_execute_errors(self):
        with self.assertRaises(OperationalError):
            await self.db.execute('invalid sql')

        with self.assertRaises(OperationalError):
            await self.db.executemany('invalid sql', [()])

        with self.assertRaises(OperationalError):
            await self.db.executescript('select 1; invalid sql;')

    async def test_iteration(self):
        await self.create_data(250)

        curs = await self.db.execute('select k from t order by k')
        accum = []
        async for row in curs:
            accum.append(row)

        self.assertEqual(len(accum), 250)
        self.assertEqual(accum[0], ('k000',))
        self.assertEqual(accum[249], ('k249',))

        curs = await self.db.execute('select k from t where k is null')
        accum = []
        async for row in curs:
            accum.append(row)
        self.assertEqual(accum, [])

        curs = await self.db.execute('select k from t where k = ?', ('k100',))
        accum = []
        async for row in curs:
            accum.append(row)
        self.assertEqual(accum, [('k100',)])

        curs = await self.db.execute('select k from t order by k')
        self.assertEqual(await curs.fetchone(), ('k000',))
        self.assertEqual(await curs.fetchmany(2), [('k001',), ('k002',)])
        accum = [row async for row in curs]
        self.assertEqual(accum[0], ('k003',))
        self.assertEqual(accum[-1], ('k249',))

    async def test_cursor_close(self):
        await self.create_data(250)

        curs = await self.db.execute('select k from t order by k')
        res = await curs.fetchmany(10)
        self.assertEqual(len(res), 10)

        # Create & Insert + our SELECT.
        self.assertEqual(self.db.conn.get_stmt_usage(), (2, 1))
        await curs.close()

        self.assertEqual(self.db.conn.get_stmt_usage(), (3, 0))

        curs = await self.db.execute('select k from t order by k')
        self.assertEqual(self.db.conn.get_stmt_usage(), (2, 1))
        self.assertEqual(len(await curs.fetchall()), 250)

        self.assertEqual(self.db.conn.get_stmt_usage(), (3, 0))

    async def test_cursor_attributes(self):
        await self.db.execute('create table t(alpha, beta, gamma)')
        curs = await self.db.execute('select alpha, gamma from t')
        names = [col[0] for col in curs.description]
        self.assertEqual(names, ['alpha', 'gamma'])

        curs = await self.db.execute('insert into t (alpha) values (?)', (10,))
        self.assertEqual(curs.lastrowid, 1)
        self.assertEqual(curs.rowcount, 1)
        curs = await self.db.execute('insert into t (alpha) values (?)', (20,))
        self.assertEqual(curs.lastrowid, 2)
        self.assertEqual(curs.rowcount, 1)

        curs = await self.db.execute('insert into t (alpha) values '
                                     '(?), (?), (?)', (30, 40, 50))
        self.assertEqual(curs.lastrowid, 5)
        self.assertEqual(curs.rowcount, 3)

        curs = await self.db.execute('delete from t where alpha > ?', (30,))
        self.assertEqual(curs.rowcount, 2)

        curs = await self.db.execute('update t set alpha = alpha + ?', (1,))
        self.assertEqual(curs.rowcount, 3)

        curs = await self.db.execute('select 2')
        self.assertEqual(await curs.scalar(), 2)

        curs = await self.db.execute('select 1 where 1 = 0')
        self.assertIsNone(await curs.scalar())

    async def test_transaction_methods(self):
        await self.create_data(0)

        await self.db.begin()
        with self.assertRaises(OperationalError):
            await self.db.begin()

        await self.insert(1)
        await self.db.rollback()

        with self.assertRaises(OperationalError):
            await self.db.rollback()

        await self.db.begin()
        await self.insert(2)
        await self.db.commit()

        with self.assertRaises(OperationalError):
            await self.db.commit()

        self.assertFalse(self.db.in_transaction)
        await self.assertT([2])

    async def test_transaction_implicit(self):
        await self.create_data(0)
        async with self.db.transaction():
            await self.insert(1)
            await self.insert(2)
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 2])

        with self.assertRaises(ValueError):
            async with self.db.transaction():
                await self.insert(3)
                raise ValueError

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 2])

    async def test_transaction_explicit(self):
        await self.create_data(0)
        async with self.db.transaction() as txn:
            await self.insert(1)
            await txn.commit()
            await self.insert(2)
            await txn.rollback()
            await self.insert(3)
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 3])

    async def test_savepoint_implicit(self):
        await self.create_data(0)
        async with self.db.transaction():
            await self.insert(1)
            async with self.db.savepoint():
                await self.insert(2)
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 2])

        async with self.db.transaction():
            await self.insert(3)
            with self.assertRaises(ValueError):
                async with self.db.savepoint():
                    await self.insert(4)
                    await self.assertT([1, 2, 3, 4])
                    raise ValueError
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 2, 3])

    async def test_savepoint_explicit(self):
        await self.create_data(0)
        async with self.db.transaction() as txn:
            await self.insert(1)
            await txn.commit()
            async with self.db.savepoint() as sp:
                await self.insert(2)
                await sp.rollback()
                await self.insert(3)
                await sp.commit()
                await self.insert(4)
                await sp.rollback()
            await self.insert(5)
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1, 3, 5])

    async def test_atomic(self):
        await self.create_data(0)
        self.assertFalse(self.db.in_transaction)

        async with self.db.atomic() as tx:
            await self.insert(1)
            self.assertTrue(self.db.in_transaction)
            await tx.commit()
            self.assertTrue(self.db.in_transaction)
            await self.insert(2)
            await tx.rollback()
            self.assertTrue(self.db.in_transaction)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([1])

        async with self.db.atomic() as tx:
            await self.insert(2)
            async with self.db.atomic() as sp:
                await self.insert(3)
                async with self.db.atomic() as sp2:
                    await self.insert(4)
                    await sp2.rollback()
                    await self.insert(5)
                await self.assertT([1, 2, 3, 5])
                await sp.rollback()
                await self.assertT([1, 2])
                await self.insert(6)

            await self.assertT([1, 2, 6])
            await self.insert(7)
            await tx.commit()
            await self.insert(8)
            await tx.rollback()
            await self.insert(9)

        await self.assertT([1, 2, 6, 7, 9])

    async def test_atomic_exceptions(self):
        await self.create_data(0)
        await self.db.execute('create unique index t_k on t(k)')
        self.assertFalse(self.db.in_transaction)

        with self.assertRaises(IntegrityError):
            async with self.db.atomic() as tx:
                await self.insert(1)
                await self.insert(1)

        self.assertFalse(self.db.in_transaction)
        await self.assertT([])

        async with self.db.atomic() as tx:
            await self.insert(2)
            async with self.db.atomic() as sp:
                await self.insert(3)
                with self.assertRaises(IntegrityError):
                    async with self.db.atomic() as sp2:
                        await self.insert(4)
                        await self.insert(4)
                await self.assertT([2, 3])

            await self.assertT([2, 3])

        await self.assertT([2, 3])

    async def test_pragma(self):
        result = await self.db.pragma('journal_mode')
        self.assertEqual(result, 'memory')

        await self.db.pragma('cache_size', -4000)
        result = await self.db.pragma('cache_size')
        self.assertEqual(result, -4000)

    async def test_row_factory(self):
        db = aconnect(':memory:', row_factory=Row)
        await db.execute('create table t(k, v)')
        await db.execute('insert into t(k, v) values (?, ?)', ('k1', 'v1'))

        row = await db.execute_one('select * from t')
        self.assertIsInstance(row, Row)
        self.assertEqual(row.k, 'k1')
        self.assertEqual(row['v'], 'v1')

        curs = await db.execute('select * from t')
        async for row in curs:
            self.assertEqual(row.k, 'k1')
            self.assertEqual(row['v'], 'v1')

        await db.close()

    async def test_backup(self):
        await self.create_data(100)
        dest = aconnect(':memory:')
        try:
            await self.db.backup(dest)
            count = await dest.execute_scalar('select count(*) from t')
            self.assertEqual(count, 100)
        finally:
            await dest.close()

    async def test_concurrency(self):
        await self.create_data(0)
        async def insert(i):
            await self.db.execute('insert into t(k) values(?)', (i,))

        await asyncio.gather(*[insert(i) for i in range(100)])
        ct = await self.db.execute_scalar('select count(*) from t')
        self.assertEqual(ct, 100)

        async def read(i):
            return await self.db.execute_scalar('select k from t where k = ?',
                                                (i,))
        results = await asyncio.gather(*[read(i) for i in range(100)])
        self.assertEqual(results, list(range(100)))


class TestAIOPool(unittest.IsolatedAsyncioTestCase):
    filename = '/tmp/cysqlite.db'

    async def asyncSetUp(self):
        self.pool = APool('/tmp/cysqlite.db', pragmas={'cache_size': -4000})

    async def asyncTearDown(self):
        await self.pool.close()
        self.cleanup()

    def cleanup(self):
        for filename in glob.glob(self.filename.replace('.db', '*')):
            if os.path.isfile(filename):
                os.unlink(filename)

    async def test_pool_pragmas(self):
        for factory in (self.pool.reader, self.pool.writer):
            async with factory() as conn:
                self.assertEqual(conn.conn.database, self.filename)
                self.assertEqual(await conn.pragma('cache_size'), -4000)
                self.assertEqual(await conn.pragma('journal_mode'), 'wal')

    async def test_reader_read_only(self):
        async with self.pool.reader() as conn:
            self.assertEqual(await conn.execute_scalar('select 1'), 1)
            with self.assertRaises(OperationalError):
                await conn.pragma('application_id', 1337)
            with self.assertRaises(OperationalError):
                await conn.execute('create table g(k)')

    async def test_writer(self):
        async with self.pool.writer() as conn:
            await conn.execute('create table g(k)')
            await conn.execute('insert into g(k) values (?), (?)',
                               ('k1', 'k2'))
            res = await conn.execute('select * from g order by k')
            self.assertEqual(await res.fetchall(), [('k1',), ('k2',)])

    async def test_writer_lock(self):
        async with self.pool.writer() as conn:
            await conn.execute('create table g(k)')
        async def t(n):
            async with self.pool.writer() as conn:
                async with conn.atomic() as tx:
                    for i in range(n):
                        await conn.execute('insert into g(k) values(?)', (i,))

        await asyncio.gather(*[t(10) for i in range(8)])

        async with self.pool.reader() as conn:
            count = await conn.execute_scalar('select count(*) from g')
            self.assertEqual(count, 80)

    async def test_closed(self):
        await self.pool.close()
        with self.assertRaises(InterfaceError):
            async with self.pool.reader() as conn:
                pass
        with self.assertRaises(InterfaceError):
            async with self.pool.writer() as conn:
                pass

    async def test_no_writer(self):
        pool = APool(':memory:', writer=False)
        with self.assertRaises(InterfaceError):
            async with pool.writer() as conn:
                pass

        await pool.close()


if __name__ == '__main__':
    unittest.main(argv=sys.argv)
