# cython: language_level=3
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_DecodeUTF8


from collections import namedtuple
import traceback
import uuid

from src.cysqlite cimport *

include "./sqlite3.pxi"


class SqliteError(Exception):
    pass


# Forward references.
cdef class Statement(object)
#cdef class Transaction(object)
#cdef class Savepoint(object)
#cdef class Blob(object)
#cdef class Backup(object)


cdef raise_sqlite_error(sqlite3 *db):
    errmsg = sqlite3_errmsg(db)
    raise SqliteError(decode(errmsg))


cdef class _callable_context_manager(object):
    def __call__(self, fn):
        def inner(*args, **kwargs):
            with self:
                return fn(*args, **kwargs)
        return inner


cdef class Connection(_callable_context_manager):
    cdef:
        sqlite3 *db
        public int cached_statements
        public int flags
        public int timeout
        public str database
        public str vfs
        # List of statements?
        # List of transactions / savepoints?
        # List of blob handles?
        # List of backup handles?
        dict stmt_available  # sql -> Statement.
        dict stmt_in_use  # id(stmt) -> Statement.
        int _transaction_depth

    def __init__(self, database, flags=None, timeout=5000, vfs=None,
                 cached_statements=100):
        self.database = database
        self.flags = flags or 0
        self.timeout = timeout
        self.vfs = vfs
        self.cached_statements = cached_statements
        self.db = NULL
        self.stmt_available = {}
        self.stmt_in_use = {}
        self._transaction_depth = 0

    def __dealloc__(self):
        if self.db:
            sqlite3_close_v2(self.db)

    def close(self):
        if not self.db:
            return False

        # When the statements are deallocated, they will be finalized.
        self.stmt_available = {}
        self.stmt_in_use = {}

        cdef int rc = sqlite3_close_v2(self.db)
        if rc != SQLITE_OK:
            raise Exception('error closing database: %s' % rc)
        self.db = NULL
        return True

    def connect(self):
        cdef:
            bytes bdatabase = encode(self.database)
            bytes bvfs
            const char *zdatabase = PyBytes_AsString(bdatabase)
            const char *zvfs = NULL
            int flags = self.flags or (SQLITE_OPEN_READWRITE |
                                       SQLITE_OPEN_CREATE)
            int rc

        if self.vfs is not None:
            bvfs = encode(self.vfs)
            zvfs = PyBytes_AsString(bvfs)

        rc = sqlite3_open_v2(zdatabase, &self.db, flags, zvfs)
        if rc != SQLITE_OK:
            self.db = NULL
            raise Exception('failed to connect: %s.' % rc)

        rc = sqlite3_busy_timeout(self.db, self.timeout)
        if rc != SQLITE_OK:
            self.close()
            raise Exception('error setting busy timeout.')

        return True

    def __enter__(self):
        if not self.db:
            self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    cdef Statement prepare(self, sql, params=None):
        cdef Statement st = self.stmt_get(sql)
        st.bind(params)
        return st

    cdef Statement stmt_get(self, sql):
        cdef:
            bytes bsql = encode(sql)
            Statement st

        if bsql in self.stmt_available:
            st = self.stmt_available.pop(bsql)
        else:
            st = Statement(self, bsql)

        self.stmt_in_use[id(st)] = st
        return st

    cdef stmt_release(self, Statement st):
        if id(st) in self.stmt_in_use:
            del self.stmt_in_use[id(st)]
        self.stmt_available[st.sql] = st

        # Randomly remove a statement from the cache.
        if len(self.stmt_available) > self.cached_statements:
            self.stmt_available.popitem()

    def execute(self, sql, params=None):
        st = self.prepare(sql, params or ())
        return st.execute()

    def execute_simple(self, sql, callback=None):
        cdef:
            bytes bsql = encode(sql)
            char *errmsg
            int rc = 0
            void *userdata = NULL

        if callback is not None:
            Py_INCREF(callback)
            callback.rowtype = None
            userdata = <void *>callback

        try:
            rc = sqlite3_exec(self.db, bsql, _exec_callback, userdata, &errmsg)
        finally:
            if callback is not None:
                Py_DECREF(callback)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db)

        return rc

    def changes(self):
        return sqlite3_changes(self.db)

    def last_insert_rowid(self):
        return sqlite3_last_insert_rowid(self.db)

    def transaction(self, lock=None):
        return Transaction(self, lock)

    def savepoint(self, sid=None):
        return Savepoint(self, sid)

    def atomic(self, lock=None):
        return Atomic(self, lock)

    def begin(self, lock=None):
        lock = encode(lock or b'DEFERRED')
        self.execute(b'BEGIN %s' % lock)

    def commit(self):
        self.execute(b'COMMIT')

    def rollback(self):
        self.execute(b'ROLLBACK')


cdef int _exec_callback(void *data, int argc, char **argv, char **colnames) with gil:
    cdef:
        bytes bcol
        int i
        object callback = <object>data  # Re-cast userdata callback.

    if not getattr(callback, 'rowtype', None):
        cols = []
        for i in range(argc):
            bcol = <bytes>(colnames[i])
            cols.append(decode(bcol))

        callback.rowtype = namedtuple('Row', cols)

    row = callback.rowtype(*[decode(argv[i]) for i in range(argc)])
    try:
        callback(row)
    except Exception as exc:
        traceback.print_exc()
        return SQLITE_ERROR

    return SQLITE_OK


cdef class Transaction(_callable_context_manager):
    cdef:
        Connection conn
        bytes lock

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = encode(lock or b'DEFERRED')

    def _begin(self):
        self.conn.execute(b'BEGIN %s' % self.lock)

    def commit(self, begin=True):
        self.conn.execute(b'COMMIT')
        if begin: self._begin()

    def rollback(self, begin=True):
        self.conn.execute(b'ROLLBACK')
        if begin: self._begin()

    def __enter__(self):
        if self.conn._transaction_depth < 1:
            self._begin()
        self.conn._transaction_depth += 1
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        is_bottom = self.conn._transaction_depth == 1
        try:
            if exc_type:
                # If there are still more transactions on the stack, then we
                # will begin a new transaction.
                self.rollback(not is_bottom)
            elif is_bottom:
                try:
                    self.commit(False)
                except:
                    self.rollback(False)
        finally:
            self.conn._transaction_depth -= 1


cdef class Savepoint(_callable_context_manager):
    cdef:
        Connection conn
        bytes quoted_sid
        bytes sid

    def __init__(self, Connection conn, sid=None):
        self.conn = conn
        self.sid = encode(sid or 's' + uuid.uuid4().hex)
        self.quoted_sid = b'"%s"' % self.sid

    def _begin(self):
        self.conn.execute(b'SAVEPOINT %s;' % self.quoted_sid)

    def commit(self, begin=True):
        self.conn.execute(b'RELEASE SAVEPOINT %s;' % self.quoted_sid)
        if begin: self._begin()

    def rollback(self):
        self.conn.execute(b'ROLLBACK TO SAVEPOINT %s;' % self.quoted_sid)

    def __enter__(self):
        self._begin()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            self.rollback()
        else:
            try:
                self.commit(begin=False)
            except:
                self.rollback()
                raise


cdef class Atomic(_callable_context_manager):
    cdef:
        Connection conn
        bytes lock
        object txn

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = encode(lock or b'DEFERRED')

    def __enter__(self):
        if self.conn._transaction_depth == 0:
            self.txn = self.conn.transaction(self.lock)
        else:
            self.txn = self.conn.savepoint()
        return self.txn.__enter__()

    def __exit__(self, exc_type, exc_val, exc_tb):
        return self.txn.__exit__(exc_type, exc_val, exc_tb)


cdef class Statement(object):
    cdef:
        Connection conn
        sqlite3_stmt *st
        bytes sql
        int step_status
        object row_data

    def __init__(self, Connection conn, sql):
        self.conn = conn
        self.sql = encode(sql)
        self.st = NULL
        self.prepare_statement()

        self.step_status = -1
        self.row_data = None

    def __dealloc__(self):
        if self.st:
            sqlite3_finalize(self.st)

    cdef prepare_statement(self):
        cdef:
            char *zsql
            int rc
            Py_ssize_t nbytes

        PyBytes_AsStringAndSize(self.sql, &zsql, &nbytes)
        with nogil:
            rc = sqlite3_prepare_v2(self.conn.db, zsql, <int>nbytes,
                                    &(self.st), NULL)

        if rc != SQLITE_OK:
            print('rc=%s' % rc)
            raise_sqlite_error(self.conn.db)

    cdef bind(self, params):
        cdef:
            bytes tmp
            char *buf
            int i, rc = 0
            Py_ssize_t nbytes

        pc = sqlite3_bind_parameter_count(self.st)
        if pc != len(params):
            raise SqliteError('error: %s parameters required' % pc)

        for i, param in enumerate(params):
            # Note: sqlite3_bind_XXX uses 1-based indexes.
            if param is None:
                rc = sqlite3_bind_null(self.st, i + 1)
            elif isinstance(param, int):
                rc = sqlite3_bind_int64(self.st, i + 1, param)
            elif isinstance(param, float):
                rc = sqlite3_bind_double(self.st, i + 1, param)
            elif isinstance(param, unicode):
                tmp = PyUnicode_AsUTF8String(param)
                PyBytes_AsStringAndSize(tmp, &buf, &nbytes)
                rc = sqlite3_bind_text64(self.st, i + 1, buf,
                                         <sqlite3_uint64>nbytes,
                                         <sqlite3_destructor_type>-1,
                                         SQLITE_UTF8)
            elif isinstance(param, bytes):
                PyBytes_AsStringAndSize(<bytes>param, &buf, &nbytes)
                rc = sqlite3_bind_blob64(self.st, i + 1, <void *>buf,
                                         <sqlite3_uint64>nbytes,
                                         <sqlite3_destructor_type>-1)

            if rc != SQLITE_OK:
                raise_sqlite_error(self.conn.db)

    cdef int reset(self):
        if self.st == NULL:
            return 0
        self.step_status = -1
        self.conn.stmt_release(self)
        return sqlite3_reset(self.st)

    def __iter__(self):
        return self

    def __next__(self):
        row = None
        if self.step_status == -1:
            self.step_status = sqlite3_step(self.st)

        if self.step_status == SQLITE_ROW:
            row = self.get_row_data()
            self.step_status = sqlite3_step(self.st)
        elif self.step_status == SQLITE_DONE:
            self.reset()
            raise StopIteration
        else:
            raise_sqlite_error(self.conn.db)
        return row

    def execute(self):
        if self.step_status != -1:
            raise SqliteError('statement has already been executed.')

        self.step_status = sqlite3_step(self.st)
        if self.step_status == SQLITE_DONE:
            self.reset()
        elif self.step_status == SQLITE_ROW:
            return self
        else:
            raise_sqlite_error(self.conn.db)

    cdef get_row_data(self):
        cdef:
            int i, ncols = sqlite3_data_count(self.st)
            tuple result = PyTuple_New(ncols)

        for i in range(ncols):
            coltype = sqlite3_column_type(self.st, i)
            if coltype == SQLITE_NULL:
                value = None
            elif coltype == SQLITE_INTEGER:
                value = sqlite3_column_int64(self.st, i)
            elif coltype == SQLITE_FLOAT:
                value = sqlite3_column_double(self.st, i)
            elif coltype == SQLITE_TEXT:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyUnicode_DecodeUTF8(
                    <char *>sqlite3_column_text(self.st, i),
                    nbytes,
                    "replace")
                Py_INCREF(value)
            elif coltype == SQLITE_BLOB:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyBytes_FromStringAndSize(
                    <char *>sqlite3_column_blob(self.st, i),
                    nbytes)
                Py_INCREF(value)
            else:
                assert False, 'should not get here!'

            PyTuple_SET_ITEM(result, i, value)

        return result
