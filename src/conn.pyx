# cython: language_level=3
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_Check
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_Check
from cpython.unicode cimport PyUnicode_DecodeUTF8

from collections import namedtuple
import traceback

include "./sqlite3.pxi"


cdef inline unicode decode(key):
    cdef unicode ukey
    if PyBytes_Check(key):
        ukey = key.decode('utf-8')
    elif PyUnicode_Check(key):
        ukey = <unicode>key
    elif key is None:
        return None
    else:
        ukey = unicode(key)
    return ukey


cdef inline bytes encode(key):
    cdef bytes bkey
    if PyUnicode_Check(key):
        bkey = PyUnicode_AsUTF8String(key)
    elif PyBytes_Check(key):
        bkey = <bytes>key
    elif key is None:
        return None
    else:
        bkey = PyUnicode_AsUTF8String(unicode(key))
    return bkey


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


cdef class Connection(object):
    cdef:
        sqlite3 *db
        public int flags
        public int timeout
        public str database
        public str vfs

    def __init__(self, database, flags=None, timeout=5000, vfs=None):
        self.database = database
        self.flags = flags or 0
        self.timeout = timeout
        self.vfs = vfs
        self.db = NULL

    def close(self):
        if not self.db:
            return False

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
            int flags = self.flags or SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
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

    def execute(self, sql, callback=None):
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

    def execute_statement(self, sql, params=None):
        st = _Statement(self, sql)
        return st.execute(params or ())


cdef raise_sqlite_error(sqlite3 *db):
    errmsg = sqlite3_errmsg(db)
    raise SqliteError(decode(errmsg))



class SqliteError(Exception): pass
class InternalError(SqliteError): pass


cdef class _Statement(object):
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

        self.step_status = 0
        self.row_data = None

    def __dealloc__(self):
        sqlite3_finalize(self.st)

    cdef compile_sql(self):
        if self.st != NULL:
            raise InternalError('statement is in-use!')

        cdef:
            char *zsql
            int rc
            Py_ssize_t nbytes

        PyBytes_AsStringAndSize(self.sql, &zsql, &nbytes)
        with nogil:
            rc = sqlite3_prepare_v2(self.conn.db, zsql, <int>nbytes,
                                    &(self.st), NULL)

        if rc == SQLITE_OK:
            return

        self.st = NULL
        raise_sqlite_error(self.conn.db)

    cdef int reset(self):
        if self.st == NULL:
            return 0
        return sqlite3_reset(self.st)

    cdef int finalize(self):
        cdef int rc
        rc = sqlite3_finalize(self.st)
        self.st = NULL
        return rc

    cdef bind_statement_parameters(self, tuple params):
        cdef:
            bytes tmp
            char *buf
            int i, rc
            Py_ssize_t nbytes

        pc = sqlite3_bind_parameter_count(self.st)
        if pc != len(params):
            raise SqliteError('error %s parameters required' % pc)

        for i, param in enumerate(params):
            if param is None:
                rc = sqlite3_bind_null(self.st, i + 1)
            elif isinstance(param, int):
                rc = sqlite3_bind_int64(self.st, i + 1, param)
            elif isinstance(param, float):
                rc = sqlite3_bind_double(self.st, i + 1, param)
            elif isinstance(param, unicode):
                tmp = PyUnicode_AsUTF8String(param)
                PyBytes_AsStringAndSize(tmp, &buf, &nbytes)
                rc = sqlite3_bind_text64(self.st, i + 1, buf, <sqlite3_uint64>nbytes,
                                         <sqlite3_destructor_type>-1,
                                         SQLITE_UTF8)
            elif isinstance(param, bytes):
                PyBytes_AsStringAndSize(<bytes>param, &buf, &nbytes)
                rc = sqlite3_bind_blob64(self.st, i + 1, <void *>buf,
                                         <sqlite3_uint64>nbytes,
                                         <sqlite3_destructor_type>-1)

            if rc != SQLITE_OK:
                raise_sqlite_error(self.conn.db)

    def execute(self, tuple params):
        self.compile_sql()
        self.bind_statement_parameters(params)
        cdef int rc = sqlite3_step(self.st)
        if rc == SQLITE_DONE or rc == SQLITE_ROW:
            return StatementIterator(self, rc)
        else:
            raise_sqlite_error(self.conn.db)


cdef class StatementIterator(object):
    cdef:
        int last_status
        _Statement statement
        sqlite3 *db
        sqlite3_stmt *st

    def __init__(self, _Statement statement, int last_status):
        self.statement = statement
        self.db = statement.conn.db
        self.st = statement.st
        self.last_status = last_status

    def __iter__(self):
        return self

    def __next__(self):
        row = None
        if self.last_status == SQLITE_ROW:
            row = self._get_row()
            self.last_status = sqlite3_step(self.st)
        elif self.last_status == SQLITE_DONE:
            self.statement.reset()
            raise StopIteration
        else:
            raise_sqlite_error(self.db)

        return row

    def changes(self):
        return sqlite3_changes(self.db)

    def last_insert_rowid(self):
        return sqlite3_last_insert_rowid(self.db)

    cdef _get_row(self):
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
