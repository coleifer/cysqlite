# cython: language_level=3
from cpython.bytes cimport PyBytes_AS_STRING
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.ref cimport Py_XDECREF
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
cdef class Transaction(object)
cdef class Savepoint(object)
cdef class Blob(object)


cdef raise_sqlite_error(sqlite3 *db, unicode msg):
    msg = msg or ''
    errmsg = sqlite3_errmsg(db)
    raise SqliteError(msg + decode(errmsg))


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
        # List of statements, transactions, savepoints, blob handles?
        dict functions
        dict stmt_available  # sql -> Statement.
        dict stmt_in_use  # id(stmt) -> Statement.
        int _transaction_depth

    def __init__(self, database, flags=None, timeout=5000, vfs=None,
                 cached_statements=100):
        self.database = decode(database)
        self.flags = flags or 0
        self.timeout = timeout
        self.vfs = vfs
        self.cached_statements = cached_statements
        self.db = NULL

        self.functions = {}
        self.stmt_available = {}
        self.stmt_in_use = {}
        self._transaction_depth = 0

    def __dealloc__(self):
        if self.db:
            sqlite3_close_v2(self.db)

    def close(self):
        if not self.db:
            return False

        # Drop references to user-defined functions.
        self.functions = {}

        # When the statements are deallocated, they will be finalized.
        self.stmt_available = {}
        self.stmt_in_use = {}

        cdef int rc = sqlite3_close_v2(self.db)
        if rc != SQLITE_OK:
            raise SqliteError('error closing database: %s' % rc)
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
            raise SqliteError('error opening database: %s.' % rc)

        rc = sqlite3_busy_timeout(self.db, self.timeout)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting busy timeout: ')

        return True

    def __enter__(self):
        if not self.db:
            self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    cdef Statement prepare(self, sql, params=None):
        cdef Statement st = self.stmt_get(sql)
        if params:
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

        # Remove oldest statement from the cache - relies on Python 3.6
        # dictionary retaining insertion order. For older python, will simply
        # remove a random key, which is also fine.
        while len(self.stmt_available) > self.cached_statements:
            first_key = next(iter(self.stmt_available))
            self.stmt_available.pop(first_key)

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
            raise_sqlite_error(self.db, 'error executing query: ')

    def changes(self):
        return sqlite3_changes(self.db)

    def last_insert_rowid(self):
        return sqlite3_last_insert_rowid(self.db)

    def status(self, flag):
        cdef int current, highwater, rc

        if sqlite3_db_status(self.db, flag, &current, &highwater, 0):
            raise_sqlite_error(self.db, 'error requesting db status: ')
        return (current, highwater)

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

    def backup(self, Connection dest, pages=None, name=None, progress=None,
               src_name=None):
        cdef:
            bytes bname = encode(name or 'main')
            bytes bsrcname = encode(src_name or 'main')
            int page_step = pages or -1
            int rc = 0
            sqlite3_backup *backup

        if not self.db or not dest.db:
            raise SqliteError('source or destination database is closed')

        backup = sqlite3_backup_init(dest.db, bname, self.db, bsrcname)
        if backup == NULL:
            raise_sqlite_error(dest.db, 'error initializing backup: ')

        while True:
            with nogil:
                rc = sqlite3_backup_step(backup, page_step)

            if progress is not None:
                remaining = sqlite3_backup_remaining(backup)
                page_count = sqlite3_backup_pagecount(backup)
                try:
                    progress(remaining, page_count, rc == SQLITE_DONE)
                except:
                    sqlite3_backup_finish(backup)
                    raise

            if rc == SQLITE_BUSY or rc == SQLITE_LOCKED:
                with nogil:
                    sqlite3_sleep(250)
            elif rc == SQLITE_DONE:
                break
            else:
                sqlite3_backup_finish(backup)
                raise_sqlite_error(dest.db, 'error backing up database: ')

        with nogil:
            rc = sqlite3_backup_finish(backup)

        if rc != SQLITE_OK:
            raise_sqlite_error(dest.db, 'error backing up database: ')

    def backup_to_file(self, filename, pages=None, name=None, progress=None,
                       src_name=None):
        cdef Connection dest = Connection(filename)
        self.backup(dest, pages, name, progress, src_name)
        dest.close()

    def create_function(self, fn, name=None, nargs=-1, deterministic=True):
        cdef:
            _Callback callback
            bytes bname = encode(name or fn.__name__)
            int flags = SQLITE_UTF8
            int rc

        # Store reference to user-defined function.
        callback = _Callback.__new__(_Callback, self, fn)
        self.functions[name] = callback

        if deterministic:
            flags |= SQLITE_DETERMINISTIC

        rc = sqlite3_create_function(
            self.db,
            bname,
            <int>nargs,
            flags,
            <void *>callback,
            _function_cb,
            NULL,
            NULL)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error creating function: ')

    def create_aggregate(self, agg, name=None, nargs=-1, deterministic=True):
        cdef:
            _Callback callback
            bytes bname = encode(name or agg.__name__)
            int flags = SQLITE_UTF8
            int rc

        if deterministic:
            flags |= SQLITE_DETERMINISTIC

        # Store reference to user-defined function.
        callback = _Callback.__new__(_Callback, self, agg)
        self.functions[name] = callback

        rc = sqlite3_create_function(
            self.db,
            bname,
            <int>nargs,
            flags,
            <void *>callback,
            NULL,
            _step_cb,
            _finalize_cb)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error creating aggregate: ')

    def create_window_function(self, agg, name=None, nargs=-1,
                               deterministic=True):
        cdef:
            _Callback callback
            bytes bname = encode(name or agg.__name__)
            int flags = SQLITE_UTF8
            int rc

        if deterministic:
            flags |= SQLITE_DETERMINISTIC

        # Store reference to user-defined function.
        callback = _Callback.__new__(_Callback, self, agg)
        self.functions[name] = callback

        rc = sqlite3_create_window_function(
            self.db,
            <const char *>bname,
            nargs,
            flags,
            <void *>callback,
            _step_cb,
            _finalize_cb,
            _value_cb,
            _inverse_cb,
            NULL)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error creating aggregate: ')


cdef class _Callback(object):
    cdef:
        Connection conn
        object fn

    def __cinit__(self, Connection conn, fn):
        self.conn = conn
        self.fn = fn


cdef void _function_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) with gil:
    cdef:
        _Callback cb = <_Callback>sqlite3_user_data(ctx)
        tuple params = sqlite_to_python(argc, argv)

    try:
        result = cb.fn(*params)
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined function', -1)
    else:
        python_to_sqlite(ctx, result)


ctypedef struct aggregate_ctx:
    int in_use
    PyObject *agg


cdef object get_aggregate(sqlite3_context *ctx):
    cdef:
        aggregate_ctx *agg_ctx = <aggregate_ctx *>sqlite3_aggregate_context(ctx, sizeof(aggregate_ctx))

    if agg_ctx.in_use:
        return <object>agg_ctx.agg

    cdef _Callback cb = <_Callback>sqlite3_user_data(ctx)
    try:
        agg = cb.fn()  # Create aggregate instance.
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)
        return

    Py_INCREF(agg)
    agg_ctx.in_use = 1
    agg_ctx.agg = <PyObject *>agg
    return agg


cdef void _step_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) with gil:
    cdef tuple params

    # Get the aggregate instance, creating it if this is the first call.
    agg = get_aggregate(ctx)
    params = sqlite_to_python(argc, argv)
    try:
        result = agg.step(*params)
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)


cdef void _finalize_cb(sqlite3_context *ctx) with gil:
    agg = get_aggregate(ctx)
    try:
        result = agg.finalize()
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)
    else:
        python_to_sqlite(ctx, result)

    Py_DECREF(agg)


cdef void _value_cb(sqlite3_context *ctx) with gil:
    agg = get_aggregate(ctx)
    try:
        result = agg.value()
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)
    else:
        python_to_sqlite(ctx, result)


cdef void _inverse_cb(sqlite3_context *ctx, int argc, sqlite3_value **params) with gil:
    agg = get_aggregate(ctx)
    try:
        agg.inverse(*sqlite_to_python(argc, params))
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)


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
            raise_sqlite_error(self.conn.db, 'error compiling statement: ')

    cdef bind(self, tuple params):
        cdef:
            bytes tmp
            char *buf
            int i = 1, rc = 0
            Py_ssize_t nbytes

        pc = sqlite3_bind_parameter_count(self.st)
        if pc != len(params):
            raise SqliteError('error: %s parameters required' % pc)

        # Note: sqlite3_bind_XXX uses 1-based indexes.
        for i in range(pc):
            param = params[i]

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
                raise_sqlite_error(self.conn.db, 'error binding parameter: ')

    cdef reset(self):
        if self.st == NULL:
            return 0
        self.step_status = -1
        self.conn.stmt_release(self)
        if sqlite3_reset(self.st) != SQLITE_OK:
            raise_sqlite_error(self.conn.db, 'error resetting statement: ')

    def __iter__(self):
        return self

    def __next__(self):
        row = None

        # Perform the first call to sqlite3_step.
        if self.step_status == -1:
            self.step_status = sqlite3_step(self.st)

        if self.step_status == SQLITE_ROW:
            row = self.get_row_data()
            self.step_status = sqlite3_step(self.st)
        elif self.step_status == SQLITE_DONE:
            self.reset()
            raise StopIteration
        else:
            raise_sqlite_error(self.conn.db, 'error executing query: ')
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
            raise_sqlite_error(self.conn.db, 'error executing query: ')

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
                raise SqliteError('error: cannot bind parameter %r' % value)

            PyTuple_SET_ITEM(result, i, value)

        return result


cdef inline int _check_blob_closed(Blob blob) except -1:
    if not blob.blob:
        raise SqliteError('Cannot operate on closed blob.')
    return 0


cdef class Blob(object):
    cdef:
        int offset
        Connection conn
        sqlite3_blob *blob

    def __init__(self, Connection conn, table, column, rowid,
                 read_only=False):
        cdef:
            bytes btable = encode(table)
            bytes bcolumn = encode(column)
            int flags = 0 if read_only else 1
            int rc
            sqlite3_blob *blob

        if conn.db == NULL:
            raise SqliteError('cannot operate on closed database.')

        self.conn = conn

        rc = sqlite3_blob_open(
            self.conn.db,
            b'main',
            <const char *>btable,
            <const char *>bcolumn,
            <sqlite3_int64>rowid,
            flags,
            &blob)

        if rc != SQLITE_OK:
            raise SqliteError('Unable to open blob "%s"."%s" row %s.' %
                              table, column, rowid)
        if blob == NULL:
            raise MemoryError('Unable to allocate blob.')

        self.blob = blob
        self.offset = 0

    cdef _close(self):
        if self.blob:
            sqlite3_blob_close(self.blob)
            self.blob = NULL

    def __dealloc__(self):
        self._close()

    def __len__(self):
        _check_blob_closed(self)
        return sqlite3_blob_bytes(self.blob)

    def read(self, n=None):
        cdef:
            bytes pybuf
            int length = -1
            int size
            char *buf

        if n is not None:
            length = n

        _check_blob_closed(self)
        size = sqlite3_blob_bytes(self.blob)
        if self.offset == size or length == 0:
            return b''

        if length < 0:
            length = size - self.offset

        if self.offset + length > size:
            length = size - self.offset

        pybuf = PyBytes_FromStringAndSize(NULL, length)
        buf = PyBytes_AS_STRING(pybuf)
        if sqlite3_blob_read(self.blob, buf, length, self.offset):
            self._close()
            raise_sqlite_error(self.conn.db, 'error reading from blob: ')

        self.offset += length
        return pybuf

    def seek(self, offset, frame_of_reference=0):
        cdef int size
        _check_blob_closed(self)
        size = sqlite3_blob_bytes(self.blob)
        if frame_of_reference == 0:
            if offset < 0 or offset > size:
                raise ValueError('seek() offset outside of valid range.')
            self.offset = offset
        elif frame_of_reference == 1:
            if self.offset + offset < 0 or self.offset + offset > size:
                raise ValueError('seek() offset outside of valid range.')
            self.offset += offset
        elif frame_of_reference == 2:
            if size + offset < 0 or size + offset > size:
                raise ValueError('seek() offset outside of valid range.')
            self.offset = size + offset
        else:
            raise ValueError('seek() frame of reference must be 0, 1 or 2.')

    def tell(self):
        _check_blob_closed(self)
        return self.offset

    def write(self, data):
        cdef:
            bytes bdata = encode(data)
            char *buf
            int n, size
            Py_ssize_t buflen

        _check_blob_closed(self)
        size = sqlite3_blob_bytes(self.blob)
        PyBytes_AsStringAndSize(bdata, &buf, &buflen)
        n = <int>buflen
        if (n + self.offset) < self.offset:
            raise ValueError('Data is too large (integer wrap)')
        if (n + self.offset) > size:
            raise ValueError('Data would go beyond end of blob')
        if sqlite3_blob_write(self.blob, buf, n, self.offset):
            raise_sqlite_error(self.conn.db, 'error writing to blob: ')
        self.offset += <int>n

    def close(self):
        self._close()

    def reopen(self, rowid):
        _check_blob_closed(self)
        self.offset = 0
        if sqlite3_blob_reopen(self.blob, <sqlite3_int64>rowid):
            self._close()
            raise_sqlite_error(self.conn.db, 'unable to reopen blob: ')


def status(flag):
    cdef int current, highwater, rc

    rc = sqlite3_status(flag, &current, &highwater, 0)
    if rc != SQLITE_OK:
        raise SqliteError('error requesting status: %s' % rc)
    return (current, highwater)


cdef tuple sqlite_to_python(int argc, sqlite3_value **params):
    cdef:
        int i, vtype
        tuple result = PyTuple_New(argc)

    for i in range(argc):
        vtype = sqlite3_value_type(params[i])
        if vtype == SQLITE_INTEGER:
            pyval = sqlite3_value_int(params[i])
        elif vtype == SQLITE_FLOAT:
            pyval = sqlite3_value_double(params[i])
        elif vtype == SQLITE_TEXT:
            pyval = PyUnicode_DecodeUTF8(
                <const char *>sqlite3_value_text(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]), NULL)
            Py_INCREF(pyval)
        elif vtype == SQLITE_BLOB:
            pyval = PyBytes_FromStringAndSize(
                <const char *>sqlite3_value_blob(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]))
            Py_INCREF(pyval)
        elif vtype == SQLITE_NULL:
            pyval = None
        else:
            pyval = None

        PyTuple_SET_ITEM(result, i, pyval)

    return result


cdef python_to_sqlite(sqlite3_context *context, param):
    cdef:
        bytes tmp
        char *buf
        Py_ssize_t nbytes

    if param is None:
        sqlite3_result_null(context)
    elif isinstance(param, int):
        sqlite3_result_int64(context, <sqlite3_int64>param)
    elif isinstance(param, float):
        sqlite3_result_double(context, <double>param)
    elif isinstance(param, unicode):
        tmp = PyUnicode_AsUTF8String(param)
        PyBytes_AsStringAndSize(tmp, &buf, &nbytes)
        sqlite3_result_text64(context, buf,
                              <sqlite3_uint64>nbytes,
                              <sqlite3_destructor_type>-1,
                              SQLITE_UTF8)
    elif isinstance(param, bytes):
        PyBytes_AsStringAndSize(<bytes>param, &buf, &nbytes)
        sqlite3_result_blob64(context, <void *>buf,
                              <sqlite3_uint64>nbytes,
                              <sqlite3_destructor_type>-1)
    else:
        sqlite3_result_error(
            context,
            encode('Unsupported type %s' % type(param)),
            -1)
        return SQLITE_ERROR

    return SQLITE_OK
