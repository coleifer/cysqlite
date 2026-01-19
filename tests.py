import glob
import os
import re
import sys
import unittest

from cysqlite import *


class BaseTestCase(unittest.TestCase):
    filename = '/tmp/cysqlite.db'
    pattern = filename + '*'

    def cleanup(self):
        if self.filename != ':memory:':
            for filename in glob.glob(self.pattern):
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

    def test_database_open(self):
        self.assertDB(':memory:', '')
        self.assertDB('/tmp/cysqlite-test.db', '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db', '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db?mode=ro',
                      '/tmp/cysqlite-test.db')
        self.assertDB('file:///tmp/cysqlite-test.db?mode=ro&cache=private',
                      '/tmp/cysqlite-test.db')


class TestCheckConnection(BaseTestCase):
    filename = ':memory:'

    def test_check_connection(self):
        self.assertFalse(self.db.is_closed())
        self.assertEqual(self.db.changes(), 0)
        self.assertEqual(self.db.total_changes(), 0)
        self.assertEqual(self.db.last_insert_rowid(), 0)
        self.assertTrue(self.db.autocommit())

        self.db.close()
        self.assertTrue(self.db.is_closed())
        self.assertRaises(SqliteError, self.db.changes)
        self.assertRaises(SqliteError, self.db.total_changes)
        self.assertRaises(SqliteError, self.db.last_insert_rowid)
        self.assertRaises(SqliteError, self.db.autocommit)
        self.assertRaises(SqliteError, self.db.execute, 'select 1')


class TestExecute(BaseTestCase):
    filename = ':memory:'

    def test_execute(self):
        self.db.execute('create table g (k, v)')
        self.db.execute('insert into g (k, v) values (?, ?), (?, ?), (?, ?)',
                        ('k1', 1, 'k2', 2, 'k3', 3))
        curs = self.db.execute('select * from g order by v')
        self.assertEqual(list(curs), [('k1', 1), ('k2', 2), ('k3', 3)])

        row = self.db.execute_one('select * from g where k = ?', ('k2',))
        self.assertEqual(row, ('k2', 2))

        row = self.db.execute_one('select sum(v) from g')
        self.assertEqual(row, (6,))


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

        with self.db.atomic():
            curs = self.db.execute('select * from kv order by key')
            self.assertEqual([row[1:] for row in curs], self.test_data)

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

    def test_autocommit(self):
        self.db.execute('delete from kv')
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
        self.create_rows(('k4', 'v4', -40))
        self.db.rollback()
        self.assertTrue(self.db.autocommit())

        self.db.begin()
        self.assertFalse(self.db.autocommit())
        self.create_rows(('k5', 'v5', -50))
        self.db.commit()
        self.assertTrue(self.db.autocommit())

        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([row for row, in curs], ['k1', 'k2', 'k3', 'k5'])

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

    @unittest.skipIf(sys.version_info[0] == 2, 'flaky on py2')
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

    def assertCount(self, n):
        curs = self.db.execute('select count(*) from kv')
        self.assertEqual(curs.value(), n)

    def assertKeys(self, expected):
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([k for k, in curs], expected)

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

    def test_pragmas_settings(self):
        self.db.execute('pragma foreign_keys = 1')
        self.assertEqual(self.db.get_foreign_keys(), 1)
        self.db.execute('pragma foreign_keys = 0')
        self.assertEqual(self.db.get_foreign_keys(), 0)

        self.db.set_foreign_keys(1)
        self.assertEqual(self.db.get_foreign_keys(), 1)
        self.db.set_foreign_keys(0)
        self.assertEqual(self.db.get_foreign_keys(), 0)

    def test_table_column_metadata(self):
        self.assertEqual(self.db.table_column_metadata('kv', 'id'), (
            'kv', 'id', 'INTEGER', 'BINARY', 1, 1, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'key'), (
            'kv', 'key', 'TEXT', 'BINARY', 1, 0, 0))
        self.assertEqual(self.db.table_column_metadata('kv', 'extra'), (
            'kv', 'extra', 'INTEGER', 'BINARY', 0, 0, 0))


class TestSmallCache(BaseTestCase):
    def get_connection(self, **kwargs):
        return Connection(self.filename, cached_statements=3, **kwargs)

    def test_small_cache(self):
        self.create_table()
        for i in range(10):
            self.create_rows(('k%s' % i, 'v%s' % i, i))
            curs = self.db.execute('select * from kv where id > %s' % i)
            self.assertEqual(len(list(curs)), 1)

        curs = self.db.execute('select * from kv order by key')
        self.assertEqual(self.db.get_stmt_cache(), (3, 1))  # avail / in-use.

        self.assertTrue(self.db.close())
        self.assertTrue(self.db.connect())
        self.assertEqual(self.db.get_stmt_cache(), (0, 0))

    def test_cached_statement(self):
        self.create_table()
        self.create_rows(('k1', 'v1', 1))

        curs = self.db.execute('select * from kv')
        curs_id = id(curs)  # Which statement is this?
        self.assertEqual(self.db.get_stmt_cache(), (2, 1))
        self.assertEqual(list(curs), [(1, 'k1', 'v1', 1)])
        self.assertEqual(self.db.get_stmt_cache(), (3, 0))

        curs = self.db.execute('select * from kv')
        self.assertEqual(id(curs), curs_id)  # Same cursor as before.
        self.assertEqual(self.db.get_stmt_cache(), (2, 1))
        self.db.close()

    def test_cache_release(self):
        self.create_table()
        self.assertEqual(self.db.get_stmt_cache(), (1, 0))

        curs = self.db.execute('select count(*) from kv')
        self.assertEqual(self.db.get_stmt_cache(), (1, 1))
        self.assertEqual(curs.value(), 0)  # value() recycles stmt.
        self.assertEqual(self.db.get_stmt_cache(), (2, 0))


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

        with self.assertRaises(SqliteError):
            blob = self.db.blob_open('register', 'data', rowid + 1)

        with self.assertRaises(SqliteError):
            blob = self.db.blob_open('register', 'missing', rowid)

        with self.assertRaises(SqliteError):
            blob = self.db.blob_open('missing', 'data', rowid)

    def test_blob_operating_on_closed(self):
        rowid = self.create_blob_row(4)
        blob = self.db.blob_open('register', 'data', rowid)
        self.assertEqual(len(blob), 4)
        blob.close()

        with self.assertRaises(SqliteError):
            len(blob)

        self.assertRaises(SqliteError, blob.read)
        self.assertRaises(SqliteError, blob.write, b'foo')
        self.assertRaises(SqliteError, blob.seek, 0, 0)
        self.assertRaises(SqliteError, blob.tell)
        self.assertRaises(SqliteError, blob.reopen, rowid)

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


class DataTypes(TableFunction):
    columns = ('key', 'value')
    params = ()
    name = 'data_types'

    def initialize(self):
        self.values = (
            None,
            1,
            2.,
            u'unicode str',
            b'byte str',
            False,
            True)
        self.idx = 0
        self.n = len(self.values)

    def iterate(self, idx):
        if idx < self.n:
            return ('k%s' % idx, self.values[idx])
        raise StopIteration


class TestDataTypesTableFunction(BaseTestCase):
    def test_data_types_table_function(self):
        DataTypes.register(self.db)
        curs = self.db.execute('SELECT key, value FROM data_types() '
                               'ORDER BY key')
        self.assertEqual(list(curs), [
            ('k0', None),
            ('k1', 1),
            ('k2', 2.),
            ('k3', u'unicode str'),
            ('k4', b'byte str'),
            ('k5', 0),
            ('k6', 1),
        ])


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
