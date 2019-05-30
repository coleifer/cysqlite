# cython: language_level=3
from cpython.bytes cimport PyBytes_AS_STRING
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.ref cimport Py_CLEAR
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.ref cimport Py_XDECREF
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_DecodeUTF8
from libc.float cimport DBL_MAX
from libc.stdint cimport int64_t
from libc.stdint cimport uint32_t
from libc.stdlib cimport rand
from libc.string cimport memcpy
from libc.string cimport memset


from collections import namedtuple
import traceback
import uuid

from src.cysqlite cimport *

include "./sqlite3.pxi"


class SqliteError(Exception): pass
class OperationalError(SqliteError): pass


# Forward references.
cdef class _Callback(object)
cdef class Statement(object)
cdef class Transaction(object)
cdef class Savepoint(object)
cdef class Blob(object)

# TODO:
# - introspection.


cdef raise_sqlite_error(sqlite3 *db, unicode msg):
    msg = msg or ''
    errmsg = sqlite3_errmsg(db)
    raise OperationalError(msg + decode(errmsg))


cdef class _callable_context_manager(object):
    def __call__(self, fn):
        def inner(*args, **kwargs):
            with self:
                return fn(*args, **kwargs)
        return inner


cdef inline check_connection(Connection conn):
    if not conn.db:
        raise SqliteError('Cannot operate on a closed database!')


cdef class Connection(_callable_context_manager):
    cdef:
        sqlite3 *db
        public bint extensions
        public bint uri
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
        _Callback _commit_hook, _rollback_hook, _update_hook, _auth_hook
        _Callback _trace_hook, _progress_hook

    def __init__(self, database, flags=None, timeout=5000, vfs=None, uri=False,
                 extensions=True, cached_statements=100):
        self.database = decode(database)
        self.flags = flags or 0
        self.timeout = timeout
        self.uri = uri
        self.extensions = extensions
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

        if self._transaction_depth > 0:
            raise SqliteError('cannot close database while a transaction is '
                              'open.')

        # Drop references to user-defined functions.
        self.functions = {}

        # When the statements are deallocated, they will be finalized.
        self.stmt_available = {}
        self.stmt_in_use = {}

        # Clear hooks.
        if self._commit_hook is not None:
            sqlite3_commit_hook(self.db, NULL, NULL)
            self._commit_hook = None
        if self._rollback_hook is not None:
            sqlite3_rollback_hook(self.db, NULL, NULL)
            self._rollback_hook = None
        if self._update_hook is not None:
            sqlite3_update_hook(self.db, NULL, NULL)
            self._update_hook = None

        # Clear authorizer.
        if self._auth_hook is not None:
            sqlite3_set_authorizer(self.db, NULL, NULL)
            self._auth_hook = None

        # Clear trace and progress handler.
        if self._trace_hook is not None:
            sqlite3_trace_v2(self.db, 0, NULL, NULL)
            self._trace_hook = None
        if self._progress_hook is not None:
            sqlite3_progress_handler(self.db, -1, NULL, NULL)
            self._progress_hook = None

        cdef int rc = sqlite3_close_v2(self.db)
        if rc != SQLITE_OK:
            raise SqliteError('error closing database: %s' % rc)
        self.db = NULL
        return True

    def connect(self):
        if self.db: return False

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

        if self.uri or bdatabase.find(b'://') >= 0:
            flags |= SQLITE_OPEN_URI

        rc = sqlite3_open_v2(zdatabase, &self.db, flags, zvfs)
        if rc != SQLITE_OK:
            self.db = NULL
            raise SqliteError('error opening database: %s.' % rc)

        if self.extensions:
            rc = sqlite3_enable_load_extension(self.db, 1)
            if rc != SQLITE_OK:
                raise_sqlite_error(self.db, 'error enabling extensions: ')

        rc = sqlite3_busy_timeout(self.db, self.timeout)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting busy timeout: ')

        return True

    cpdef is_closed(self):
        return self.db == NULL

    def get_stmt_cache(self):
        return len(self.stmt_available), len(self.stmt_in_use)

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
        check_connection(self)
        st = self.prepare(sql, params or ())
        return st.execute()

    def execute_simple(self, sql, callback=None):
        check_connection(self)

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
        check_connection(self)
        return sqlite3_changes(self.db)

    def total_changes(self):
        check_connection(self)
        return sqlite3_total_changes(self.db)

    def last_insert_rowid(self):
        check_connection(self)
        return sqlite3_last_insert_rowid(self.db)

    def interrupt(self):
        check_connection(self)
        sqlite3_interrupt(self.db)

    def autocommit(self):
        check_connection(self)
        return sqlite3_get_autocommit(self.db)

    def status(self, flag):
        check_connection(self)
        cdef int current, highwater, rc

        if sqlite3_db_status(self.db, flag, &current, &highwater, 0):
            raise_sqlite_error(self.db, 'error requesting db status: ')
        return (current, highwater)

    def table_column_metadata(self, table, column, database=None):
        check_connection(self)
        cdef:
            bytes btable = encode(table)
            bytes bcolumn = encode(column)
            bytes bdatabase
            char *zdatabase = NULL
            char *data_type
            char *coll_seq
            int not_null, primary_key, auto_increment
            int rc

        if database:
            bdatabase = encode(database)
            zdatabase = bdatabase

        rc = sqlite3_table_column_metadata(self.db, zdatabase, btable, bcolumn,
                                           <const char **>&data_type,
                                           <const char **>&coll_seq,
                                           &not_null, &primary_key,
                                           &auto_increment)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error getting column metadata: ')

        return (table, column, decode(data_type), decode(coll_seq), not_null,
                primary_key, auto_increment)

    def transaction(self, lock=None):
        check_connection(self)
        return Transaction(self, lock)

    def savepoint(self, sid=None):
        check_connection(self)
        return Savepoint(self, sid)

    def atomic(self, lock=None):
        check_connection(self)
        return Atomic(self, lock)

    def begin(self, lock=None):
        check_connection(self)
        lock = encode(lock or b'DEFERRED')
        self.execute(b'BEGIN %s' % lock)

    def commit(self):
        check_connection(self)
        self.execute(b'COMMIT')

    def rollback(self):
        check_connection(self)
        self.execute(b'ROLLBACK')

    def backup(self, Connection dest, pages=None, name=None, progress=None,
               src_name=None):
        check_connection(self)
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
        dest.connect()
        self.backup(dest, pages, name, progress, src_name)
        dest.close()

    def blob_open(self, table, column, rowid, read_only=False):
        check_connection(self)
        return Blob(self, table, column, rowid, read_only)

    def load_extension(self, name):
        check_connection(self)
        cdef:
            bytes bname = encode(name)
            char *errmsg
            int rc

        rc = sqlite3_load_extension(self.db, bname, NULL, &errmsg)
        if rc != SQLITE_OK:
            raise SqliteError('error loading extension: %s' % decode(errmsg))

    def create_function(self, fn, name=None, nargs=-1, deterministic=True):
        check_connection(self)
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
        check_connection(self)
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
        check_connection(self)
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

    def create_collation(self, fn, name):
        check_connection(self)
        cdef:
            _Callback callback
            bytes bname = encode(name or fn.__name__)
            int rc

        # Store reference to user-defined function.
        callback = _Callback.__new__(_Callback, self, fn)
        self.functions[name] = callback

        rc = sqlite3_create_collation(
            self.db,
            <const char *>bname,
            SQLITE_UTF8,
            <void *>callback,
            _collation_cb)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error creating collation: ')

    def commit_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._commit_hook = None
            sqlite3_commit_hook(self.db, NULL, NULL)
            return

        cdef _Callback callback = _Callback.__new__(_Callback, self, fn)
        self._commit_hook = callback
        sqlite3_commit_hook(self.db, _commit_cb, <void *>callback)

    def rollback_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._rollback_hook = None
            sqlite3_rollback_hook(self.db, NULL, NULL)
            return
        cdef _Callback callback = _Callback.__new__(_Callback, self, fn)
        self._rollback_hook = callback
        sqlite3_rollback_hook(self.db, _rollback_cb, <void *>callback)

    def update_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._update_hook = None
            sqlite3_update_hook(self.db, NULL, NULL)
            return

        cdef _Callback callback = _Callback.__new__(_Callback, self, fn)
        self._update_hook = callback
        sqlite3_update_hook(self.db, _update_cb, <void *>callback)

    def authorizer(self, fn):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._auth_hook = None
            rc = sqlite3_set_authorizer(self.db, NULL, NULL)
        else:
            callback = _Callback.__new__(_Callback, self, fn)
            self._auth_hook = callback
            rc = sqlite3_set_authorizer(self.db, _auth_cb, <void *>callback)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting authorizer: ')

    def trace(self, fn, mask=2):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._trace_hook = None
            rc = sqlite3_trace_v2(self.db, 0, NULL, NULL)
        else:
            callback = _Callback.__new__(_Callback, self, fn)
            self._trace_hook = callback
            rc = sqlite3_trace_v2(self.db, mask, _trace_cb, <void *>callback)

        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting trace: ')

    def progress(self, fn, n=1):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._progress_hook = None
            sqlite3_progress_handler(self.db, 0, NULL, NULL)
        else:
            callback = _Callback.__new__(_Callback, self, fn)
            self._progress_hook = callback
            sqlite3_progress_handler(self.db, n, _progress_cb,
                                     <void *>callback)

    def set_busy_handler(self, timeout=5):
        check_connection(self)
        cdef sqlite3_int64 n = timeout * 1000
        sqlite3_busy_handler(self.db, _aggressive_busy_handler, <void *>n)

    def set_main_db_name(self, name):
        check_connection(self)
        cdef bytes bname = encode(name)
        if sqlite3_db_config(self.db, SQLITE_DBCONFIG_MAINDBNAME,
                             <const char *>bname) != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting main db name: ')
    cdef _do_config(self, int config, int enabled):
        check_connection(self)
        cdef int rc, status
        rc = sqlite3_db_config(self.db, config, enabled, &status)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting config value: ')
        return status
    def set_foreign_keys(self, int enabled):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_FKEY, enabled)
    def get_foreign_keys(self):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_FKEY, -1)
    def set_triggers(self, int enabled):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_TRIGGER, enabled)
    def get_triggers(self):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_TRIGGER, -1)
    def set_load_extension(self, int enabled):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, enabled)
    def get_load_extension(self):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, -1)
    def set_shared_cache(self, int enabled):
        check_connection(self)
        cdef int rc = sqlite3_enable_shared_cache(enabled)
        if rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting shared cache: ')
        return enabled

    def set_autocheckpoint(self, int n):
        check_connection(self)
        if sqlite3_wal_autocheckpoint(self.db, n) != SQLITE_OK:
            raise_sqlite_error(self.db, 'error setting wal autocheckpoint: ')

    def checkpoint(self, full=False, truncate=False, name=None):
        check_connection(self)
        cdef:
            bytes bname
            const char *zDb = NULL
            int mode = SQLITE_CHECKPOINT_PASSIVE
            int pnLog, pnCkpt  # Size of WAL in frames, total num checkpointed.
            int rc

        if full:
            mode = SQLITE_CHECKPOINT_FULL
        elif truncate:
            mode = SQLITE_CHECKPOINT_TRUNCATE

        if name:
            bname = encode(name)
            zDb = bname

        rc = sqlite3_wal_checkpoint_v2(self.db, zDb, mode, &pnLog, &pnCkpt)
        if rc == SQLITE_MISUSE:
            raise SqliteError('error: misuse - cannot perform wal checkpoint')
        elif rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error performing checkpoint: ')

        return (pnLog, pnCkpt)


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


cdef int _collation_cb(void *data, int n1, const void *data1,
                       int n2, const void *data2) with gil:
    cdef:
        _Callback cb = <_Callback>data
        int result = 0

    str1 = PyUnicode_DecodeUTF8(<const char *>data1, n1, "replace")
    str2 = PyUnicode_DecodeUTF8(<const char *>data2, n2, "replace")
    if not str1 or not str2:
        return result

    try:
        result = cb.fn(str1, str2)
    except Exception as exc:
        # XXX: report error back to conn.
        traceback.print_exc()

    if result > 0:
        return 1
    elif result < 0:
        return -1
    return 0


cdef int _commit_cb(void *data) with gil:
    # C-callback that delegates to the Python commit handler. If the Python
    # function raises a ValueError, then the commit is aborted and the
    # transaction rolled back. Otherwise, regardless of the function return
    # value, the transaction will commit.
    cdef _Callback cb = <_Callback>data
    try:
        cb.fn()
    except ValueError:
        return SQLITE_ERROR
    except Exception as exc:
        traceback.print_exc()
    return SQLITE_OK


cdef void _rollback_cb(void *data) with gil:
    # C-callback that delegates to the Python rollback handler.
    cdef _Callback cb = <_Callback>data
    try:
        cb.fn()
    except Exception as exc:
        traceback.print_exc()


cdef void _update_cb(void *data, int queryType, const char *database,
                     const char *table, sqlite3_int64 rowid) with gil:
    # C-callback that delegates to a Python function that is executed whenever
    # the database is updated (insert/update/delete queries). The Python
    # callback receives a string indicating the query type, the name of the
    # database, the name of the table being updated, and the rowid of the row
    # being updatd.
    cdef _Callback cb = <_Callback>data
    if queryType == SQLITE_INSERT:
        query = 'INSERT'
    elif queryType == SQLITE_UPDATE:
        query = 'UPDATE'
    elif queryType == SQLITE_DELETE:
        query = 'DELETE'
    else:
        query = ''

    try:
        cb.fn(query, decode(database), decode(table), <int>rowid)
    except Exception as exc:
        traceback.print_exc()


AUTH_OK = 0
AUTH_DENY = 1
AUTH_IGNORE = 2


cdef int _auth_cb(void *data, int op, const char *p1, const char *p2,
                  const char *p3, const char *p4) with gil:
    # Return SQLITE_OK to allow.
    # SQLITE_IGNORE allows compilation but disallows the specific action.
    # SQLITE_DENY prevents compilation completely.
    # Params 3 and 4 are provided by the following table.
    # Param 5 is the database name ("main", "temp", if applicable).
    # Param 6 is the inner-most trigger or view that is responsible for the
    # access attempt, or NULL if from top-level SQL code.
    #
    # SQLITE_CREATE_INDEX          1   Index Name      Table Name
    # SQLITE_CREATE_TABLE          2   Table Name      NULL
    # SQLITE_CREATE_TEMP_INDEX     3   Index Name      Table Name
    # SQLITE_CREATE_TEMP_TABLE     4   Table Name      NULL
    # SQLITE_CREATE_TEMP_TRIGGER   5   Trigger Name    Table Name
    # SQLITE_CREATE_TEMP_VIEW      6   View Name       NULL
    # SQLITE_CREATE_TRIGGER        7   Trigger Name    Table Name
    # SQLITE_CREATE_VIEW           8   View Name       NULL
    # SQLITE_DELETE                9   Table Name      NULL
    # SQLITE_DROP_INDEX           10   Index Name      Table Name
    # SQLITE_DROP_TABLE           11   Table Name      NULL
    # SQLITE_DROP_TEMP_INDEX      12   Index Name      Table Name
    # SQLITE_DROP_TEMP_TABLE      13   Table Name      NULL
    # SQLITE_DROP_TEMP_TRIGGER    14   Trigger Name    Table Name
    # SQLITE_DROP_TEMP_VIEW       15   View Name       NULL
    # SQLITE_DROP_TRIGGER         16   Trigger Name    Table Name
    # SQLITE_DROP_VIEW            17   View Name       NULL
    # SQLITE_INSERT               18   Table Name      NULL
    # SQLITE_PRAGMA               19   Pragma Name     1st arg or NULL
    # SQLITE_READ                 20   Table Name      Column Name
    # SQLITE_SELECT               21   NULL            NULL
    # SQLITE_TRANSACTION          22   Operation       NULL
    # SQLITE_UPDATE               23   Table Name      Column Name
    # SQLITE_ATTACH               24   Filename        NULL
    # SQLITE_DETACH               25   Database Name   NULL
    # SQLITE_ALTER_TABLE          26   Database Name   Table Name
    # SQLITE_REINDEX              27   Index Name      NULL
    # SQLITE_ANALYZE              28   Table Name      NULL
    # SQLITE_CREATE_VTABLE        29   Table Name      Module Name
    # SQLITE_DROP_VTABLE          30   Table Name      Module Name
    # SQLITE_FUNCTION             31   NULL            Function Name
    # SQLITE_SAVEPOINT            32   Operation       Savepoint Name
    # SQLITE_COPY                  0   <not used>
    # SQLITE_RECURSIVE            33   NULL            NULL
    cdef:
        _Callback cb = <_Callback>data
        int rc
        unicode s1 = decode(p1) if p1 != NULL else None
        unicode s2 = decode(p2) if p2 != NULL else None
        unicode s3 = decode(p3) if p3 != NULL else None
        unicode s4 = decode(p4) if p4 != NULL else None

    try:
        rc = cb.fn(op, s1, s2, s3, s4)
    except Exception as exc:
        traceback.print_exc()
        rc = SQLITE_OK
    return rc


TRACE_STMT = 0x01
TRACE_PROFILE = 0x02
TRACE_ROW = 0x04
TRACE_CLOSE = 0x08


cdef int _trace_cb(unsigned event, void *data, void *p, void *x) with gil:
    cdef:
        _Callback cb = <_Callback>data
        bytes bsql
        long long sid = -1
        int64_t ns = -1
        unicode sql = None
    # Integer return value is currently ignored, but this may change in future
    # versions of sqlite3.
    # TRACE_STMT invoked when a prepared stmt first begins running. P is a
    # pointer to the statement, X is a pointer to the string of the SQL.
    # TRACE_PROFILE - P points to a statement, X points to a 64-bit integer
    # which is the estimated number of ns that the statement took to run.
    # TRACE_ROW invoked when a statement generates a single row of results. P
    # is a pointer to the statement, X is unused.
    # TRACE_CLOSE is invoked when a database connection closes. P is a pointer
    # to the db conn, X is unused.
    if event != TRACE_CLOSE:
        sid = <long long>p  # Memory address of statement.
    if event == TRACE_STMT:
        bsql = <bytes>(<char *>x)
        sql = decode(bsql)
    elif event == TRACE_PROFILE:
        ns = (<int64_t *>x)[0]

    try:
        cb.fn(event, sid, sql, ns)
    except Exception as exc:
        traceback.print_exc()
        return SQLITE_ERROR

    return SQLITE_OK


cdef int _progress_cb(void *data) with gil:
    cdef _Callback cb = <_Callback>data
    # If returns non-zero, the operation is interrupted.
    try:
        ret = cb.fn() or 0
    except Exception as exc:
        traceback.print_exc()
        ret = SQLITE_OK
    return <int>ret


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
            elif is_bottom and not sqlite3_get_autocommit(self.conn.db):
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

    def fetchone(self):
        return next(self)

    def value(self):
        return next(self)[0]

    def execute(self):
        if self.step_status != -1:
            raise SqliteError('statement has already been executed.')

        self.step_status = sqlite3_step(self.st)
        if self.step_status == SQLITE_DONE:
            self.reset()
            return iter(())
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
            elif coltype == SQLITE_BLOB:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyBytes_FromStringAndSize(
                    <char *>sqlite3_column_blob(self.st, i),
                    nbytes)
            else:
                raise SqliteError('error: cannot bind parameter %r' % value)

            Py_INCREF(value)
            PyTuple_SET_ITEM(result, i, value)

        return result

    def column_count(self):
        if not self.st: raise SqliteError('statement is not available')
        return sqlite3_column_count(self.st)

    def description(self):
        cdef:
            bytes col_name
            int col_count, i
            list accum = []

        col_count = sqlite3_column_count(self.st)
        for i in range(col_count):
            col_name = sqlite3_column_name(self.st, i)
            accum.append(decode(col_name))
        return accum

    def is_readonly(self):
        if not self.st: raise SqliteError('statement is not available')
        return sqlite3_stmt_readonly(self.st)
    def is_explain(self):
        if not self.st: raise SqliteError('statement is not available')
        return sqlite3_stmt_isexplain(self.st)
    def is_busy(self):
        if not self.st: raise SqliteError('statement is not available')
        return sqlite3_stmt_busy(self.st)


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
                              (table, column, rowid))
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
        _check_blob_closed(self)
        cdef:
            bytes pybuf
            int length = -1
            int size
            char *buf

        if n is not None:
            length = n

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
        _check_blob_closed(self)
        cdef int size
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
        _check_blob_closed(self)
        cdef:
            bytes bdata = encode(data)
            char *buf
            int n, size
            Py_ssize_t buflen

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


# The cysqlite_vtab struct embeds the base sqlite3_vtab struct, and adds a
# field to store a reference to the Python implementation.
ctypedef struct cysqlite_vtab:
    sqlite3_vtab base
    void *table_func_cls


# Like cysqlite_vtab, the cysqlite_cursor embeds the base sqlite3_vtab_cursor
# and adds fields to store references to the current index, the Python
# implementation, the current rows' data, and a flag for whether the cursor has
# been exhausted.
ctypedef struct cysqlite_cursor:
    sqlite3_vtab_cursor base
    long long idx
    void *table_func
    void *row_data
    bint stopped


# We define an xConnect function, but leave xCreate NULL so that the
# table-function can be called eponymously.
cdef int cyConnect(sqlite3 *db, void *pAux, int argc, const char *const*argv,
                   sqlite3_vtab **ppVtab, char **pzErr) with gil:
    cdef:
        int rc
        object table_func_cls = <object>pAux
        cysqlite_vtab *pNew = <cysqlite_vtab *>0

    rc = sqlite3_declare_vtab(
        db,
        encode('CREATE TABLE x(%s);' %
               table_func_cls.get_table_columns_declaration()))
    if rc == SQLITE_OK:
        pNew = <cysqlite_vtab *>sqlite3_malloc(sizeof(pNew[0]))
        memset(<char *>pNew, 0, sizeof(pNew[0]))
        ppVtab[0] = &(pNew.base)

        pNew.table_func_cls = <void *>table_func_cls
        Py_INCREF(table_func_cls)

    return rc


cdef int cyDisconnect(sqlite3_vtab *pBase) with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls = <object>(pVtab.table_func_cls)

    Py_DECREF(table_func_cls)
    sqlite3_free(pVtab)
    return SQLITE_OK


# The xOpen method is used to initialize a cursor. In this method we
# instantiate the TableFunction class and zero out a new cursor for iteration.
cdef int cyOpen(sqlite3_vtab *pBase, sqlite3_vtab_cursor **ppCursor) with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        cysqlite_cursor *pCur = <cysqlite_cursor *>0
        object table_func_cls = <object>pVtab.table_func_cls

    pCur = <cysqlite_cursor *>sqlite3_malloc(sizeof(pCur[0]))
    memset(<char *>pCur, 0, sizeof(pCur[0]))
    ppCursor[0] = &(pCur.base)
    pCur.idx = 0
    try:
        table_func = table_func_cls()
    except:
        if table_func_cls.print_tracebacks:
            traceback.print_exc()
        sqlite3_free(pCur)
        return SQLITE_ERROR

    Py_INCREF(table_func)
    pCur.table_func = <void *>table_func
    pCur.stopped = False
    return SQLITE_OK


cdef int cyClose(sqlite3_vtab_cursor *pBase) with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func = <object>pCur.table_func
    Py_DECREF(table_func)
    sqlite3_free(pCur)
    return SQLITE_OK


# Iterate once, advancing the cursor's index and assigning the row data to the
# `row_data` field on the cysqlite_cursor struct.
cdef int cyNext(sqlite3_vtab_cursor *pBase) with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func = <object>pCur.table_func
        tuple result

    if pCur.row_data:
        Py_DECREF(<tuple>pCur.row_data)

    pCur.row_data = NULL
    try:
        result = tuple(table_func.iterate(pCur.idx))
    except StopIteration:
        pCur.stopped = True
    except:
        if table_func.print_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR
    else:
        Py_INCREF(result)
        pCur.row_data = <void *>result
        pCur.idx += 1
        pCur.stopped = False

    return SQLITE_OK


# Return the requested column from the current row.
cdef int cyColumn(sqlite3_vtab_cursor *pBase, sqlite3_context *ctx,
                  int iCol) with gil:
    cdef:
        bytes bval
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        sqlite3_int64 x = 0
        tuple row_data

    if iCol == -1:
        sqlite3_result_int64(ctx, <sqlite3_int64>pCur.idx)
        return SQLITE_OK

    if not pCur.row_data:
        sqlite3_result_error(ctx, encode('no row data'), -1)
        return SQLITE_ERROR

    row_data = <tuple>pCur.row_data
    return python_to_sqlite(ctx, row_data[iCol])


cdef int cyRowid(sqlite3_vtab_cursor *pBase, sqlite3_int64 *pRowid):
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
    pRowid[0] = <sqlite3_int64>pCur.idx
    return SQLITE_OK


# Return a boolean indicating whether the cursor has been consumed.
cdef int cyEof(sqlite3_vtab_cursor *pBase):
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
    return 1 if pCur.stopped else 0


# The filter method is called on the first iteration. This method is where we
# get access to the parameters that the function was called with, and call the
# TableFunction's `initialize()` function.
cdef int cyFilter(sqlite3_vtab_cursor *pBase, int idxNum,
                  const char *idxStr, int argc, sqlite3_value **argv) with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func = <object>pCur.table_func
        dict query = {}
        int idx
        int value_type
        tuple row_data
        void *row_data_raw

    if not idxStr or argc == 0 and len(table_func.params):
        return SQLITE_ERROR
    elif len(idxStr):
        params = decode(idxStr).split(',')
    else:
        params = []

    py_values = sqlite_to_python(argc, argv)

    for idx, param in enumerate(params):
        value = argv[idx]
        if not value:
            query[param] = None
        else:
            query[param] = py_values[idx]

    try:
        table_func.initialize(**query)
    except:
        if table_func.print_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR

    pCur.stopped = False
    try:
        row_data = tuple(table_func.iterate(0))
    except StopIteration:
        pCur.stopped = True
    except:
        if table_func.print_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR
    else:
        Py_INCREF(row_data)
        pCur.row_data = <void *>row_data
        pCur.idx += 1
    return SQLITE_OK


# SQLite will (in some cases, repeatedly) call the xBestIndex method to try and
# find the best query plan.
cdef int cyBestIndex(sqlite3_vtab *pBase, sqlite3_index_info *pIdxInfo) \
        with gil:
    cdef:
        int i
        int idxNum = 0, nArg = 0
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls = <object>pVtab.table_func_cls
        sqlite3_index_constraint *pConstraint = <sqlite3_index_constraint *>0
        list columns = []
        char *idxStr
        int nParams = len(table_func_cls.params)

    for i in range(pIdxInfo.nConstraint):
        pConstraint = pIdxInfo.aConstraint + i
        if not pConstraint.usable:
            continue
        if pConstraint.op != SQLITE_INDEX_CONSTRAINT_EQ:
            continue

        columns.append(table_func_cls.params[pConstraint.iColumn -
                                             table_func_cls._ncols])
        nArg += 1
        pIdxInfo.aConstraintUsage[i].argvIndex = nArg
        pIdxInfo.aConstraintUsage[i].omit = 1

    if nArg > 0 or nParams == 0:
        if nArg == nParams:
            # All parameters are present, this is ideal.
            pIdxInfo.estimatedCost = <double>1
            pIdxInfo.estimatedRows = 10
        else:
            # Penalize score based on number of missing params.
            pIdxInfo.estimatedCost = <double>10000000000000 * <double>(nParams - nArg)
            pIdxInfo.estimatedRows = 10 ** (nParams - nArg)

        # Store a reference to the columns in the index info structure.
        joinedCols = encode(','.join(columns))
        idxStr = <char *>sqlite3_malloc((len(joinedCols) + 1) * sizeof(char))
        memcpy(idxStr, <char *>joinedCols, len(joinedCols))
        idxStr[len(joinedCols)] = b'\x00'
        pIdxInfo.idxStr = idxStr
        pIdxInfo.needToFreeIdxStr = 0
        return SQLITE_OK

    return SQLITE_CONSTRAINT


cdef class _TableFunctionImpl(object):
    cdef:
        sqlite3_module module
        object table_function

    def __cinit__(self, table_function):
        self.table_function = table_function

    cdef create_module(self, Connection conn):
        cdef:
            bytes name = encode(self.table_function.name)
            sqlite3 *db = conn.db
            int rc

        # Populate the SQLite module struct members.
        self.module.iVersion = 0
        self.module.xCreate = NULL
        self.module.xConnect = cyConnect
        self.module.xBestIndex = cyBestIndex
        self.module.xDisconnect = cyDisconnect
        self.module.xDestroy = NULL
        self.module.xOpen = cyOpen
        self.module.xClose = cyClose
        self.module.xFilter = cyFilter
        self.module.xNext = cyNext
        self.module.xEof = cyEof
        self.module.xColumn = cyColumn
        self.module.xRowid = cyRowid
        self.module.xUpdate = NULL
        self.module.xBegin = NULL
        self.module.xSync = NULL
        self.module.xCommit = NULL
        self.module.xRollback = NULL
        self.module.xFindFunction = NULL
        self.module.xRename = NULL

        # Create the SQLite virtual table.
        rc = sqlite3_create_module(
            db,
            <const char *>name,
            &self.module,
            <void *>(self.table_function))

        Py_INCREF(self)

        return rc == SQLITE_OK


class TableFunction(object):
    columns = None
    params = None
    name = None
    print_tracebacks = True
    _ncols = None

    @classmethod
    def register(cls, Connection conn):
        cdef _TableFunctionImpl impl = _TableFunctionImpl(cls)
        impl.create_module(conn)
        cls._ncols = len(cls.columns)

    def initialize(self, **filters):
        raise NotImplementedError

    def iterate(self, idx):
        raise NotImplementedError

    @classmethod
    def get_table_columns_declaration(cls):
        cdef list accum = []

        for column in cls.columns:
            if isinstance(column, tuple):
                if len(column) != 2:
                    raise ValueError('Column must be either a string or a '
                                     '2-tuple of name, type')
                accum.append('%s %s' % column)
            else:
                accum.append(column)

        for param in cls.params:
            accum.append('%s HIDDEN' % param)

        return ', '.join(accum)


sqlite_version = decode(sqlite3_version)
sqlite_version_info = sqlite3_libversion_number()


def status(flag):
    cdef int current, highwater, rc

    rc = sqlite3_status(flag, &current, &highwater, 0)
    if rc != SQLITE_OK:
        raise SqliteError('error requesting status: %s' % rc)
    return (current, highwater)


def set_singlethread(self):
    return sqlite3_config(SQLITE_CONFIG_SINGLETHREAD) == SQLITE_OK
def set_multithread(self):
    return sqlite3_config(SQLITE_CONFIG_MULTITHREAD) == SQLITE_OK
def set_serialized(self):
    return sqlite3_config(SQLITE_CONFIG_SERIALIZED) == SQLITE_OK
def set_lookaside(self, int size, int slots):
    return sqlite3_config(SQLITE_CONFIG_LOOKASIDE, size, slots) == SQLITE_OK
def set_mmap_size(self, default_size, max_size):
    return sqlite3_config(SQLITE_CONFIG_MMAP_SIZE,
                          <sqlite3_int64>default_size,
                          <sqlite3_int64>max_size) == SQLITE_OK
def set_stmt_journal_spill(self, int nbytes):
    # nbytes is the spill-to-disk threshold. Statement journals are held in
    # memory until their size exceeds this threshold. Set to -1 to keep
    # journals exclusively in memory.
    return sqlite3_config(SQLITE_CONFIG_STMTJRNL_SPILL, nbytes) == SQLITE_OK


def compile_option(opt):
    cdef bopt = encode(opt)
    return sqlite3_compileoption_used(bopt)


HAS_COLUMN_METADATA = compile_option('enable_column_metadata')
#HAS_PREUPDATE_HOOK = compile_option('enable_preupdate_hook')
#HAS_STMT_SCANSTATUS = compile_option('enable_stmt_scanstatus')


def vfs_list():
    cdef:
        sqlite3_vfs *vfs = sqlite3_vfs_find(NULL)
        list accum = []

    while vfs:
        name = decode(vfs.zName)
        accum.append(name)
        vfs = vfs.pNext
    return accum


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
        elif vtype == SQLITE_BLOB:
            pyval = PyBytes_FromStringAndSize(
                <const char *>sqlite3_value_blob(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]))
        elif vtype == SQLITE_NULL:
            pyval = None
        else:
            pyval = None

        Py_INCREF(pyval)
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


# Misc helpers.
cdef uint32_t murmurhash2(const unsigned char *key, ssize_t nlen,
                          uint32_t seed):
    cdef:
        uint32_t m = 0x5bd1e995
        int r = 24
        const unsigned char *data = key
        uint32_t h = seed ^ nlen
        uint32_t k

    while nlen >= 4:
        k = <uint32_t>((<uint32_t *>data)[0])

        k *= m
        k = k ^ (k >> r)
        k *= m

        h *= m
        h = h ^ k

        data += 4
        nlen -= 4

    if nlen == 3:
        h = h ^ (data[2] << 16)
    if nlen >= 2:
        h = h ^ (data[1] << 8)
    if nlen >= 1:
        h = h ^ (data[0])
        h *= m

    h = h ^ (h >> 13)
    h *= m
    h = h ^ (h >> 15)
    return h


def cymurmurhash(key, seed=None):
    if key is None:
        return

    cdef:
        bytes bkey = encode(key)
        char *data
        int iseed = seed or 0
        Py_ssize_t nbytes

    PyBytes_AsStringAndSize(bkey, &data, &nbytes)

    if key:
        return murmurhash2(<unsigned char *>data, <int64_t>nbytes, iseed)
    return 0


cdef int _aggressive_busy_handler(void *ptr, int n) nogil:
    # In concurrent environments, it often seems that if multiple queries are
    # kicked off at around the same time, they proceed in lock-step to check
    # for the availability of the lock. By introducing some "jitter" we can
    # ensure that this doesn't happen. Furthermore, this function makes more
    # attempts in the same time period than the default handler.
    cdef:
        sqlite3_int64 busyTimeout = <sqlite3_int64>ptr
        int current, total

    if n < 20:
        current = 25 - (rand() % 10)  # ~20ms
        total = n * 20
    elif n < 40:
        current = 50 - (rand() % 20)  # ~40ms
        total = 400 + ((n - 20) * 40)
    else:
        current = 120 - (rand() % 40)  # ~100ms
        total = 1200 + ((n - 40) * 100)  # Estimate the amount of time slept.

    if total + current > busyTimeout:
        current = busyTimeout - total
    if current > 0:
        sqlite3_sleep(current)
        return 1
    return 0
