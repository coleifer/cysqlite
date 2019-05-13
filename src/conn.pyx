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

include "./sqlite.pxi"


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

    if not hasattr(callback, 'rowtype'):
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
            userdata = <void *>callback

        try:
            rc = sqlite3_exec(self.db, bsql, _exec_callback, userdata, &errmsg)
        finally:
            if callback is not None:
                Py_DECREF(callback)

        if rc != SQLITE_OK:
            error = 'error executing query: %s' % rc
            if errmsg:
                error = '%s - %s' % (error, errmsg)
            raise Exception(error)

        return rc


cdef class Statement(object):
    cdef:
        sqlite3_stmt *st
        Connection conn
        bytes sql
        object next_row
        tuple params

    def __init__(self, Connection conn, sql, params=None):
        self.conn = conn
        self.sql = encode(sql)
        self.params = params or ()

    def execute(self):
        cdef:
            bytes tmp
            char *buf
            char *zsql
            const char *tail
            int i, rc
            Py_ssize_t nbytes

        PyBytes_AsStringAndSize(self.sql, &zsql, &nbytes)
        rc = sqlite3_prepare_v2(self.conn.db, zsql, <int>nbytes, &(self.st),
                                &tail)
        if rc != SQLITE_OK:
            raise Exception('error compiling statement')

        for i, param in enumerate(self.params):
            if param is None:
                rc = sqlite3_bind_null(self.st, i)
            elif isinstance(param, int):
                rc = sqlite3_bind_int64(self.st, i, param)
            elif isinstance(param, float):
                rc = sqlite3_bind_double(self.st, i, param)
            elif isinstance(param, unicode):
                tmp = PyUnicode_AsUTF8String(param)
                PyBytes_AsStringAndSize(tmp, &buf, &nbytes)
                rc = sqlite3_bind_text64(self.st, i, buf, <int>nbytes,
                                         <sqlite3_destructor_type>-1,
                                         SQLITE_UTF8)
            elif isinstance(param, bytes):
                PyBytes_AsStringAndSize(<bytes>param, &buf, &nbytes)
                rc = sqlite3_bind_blob64(self.st, i, <void *>buf, <int>nbytes,
                                         <sqlite3_destructor_type>-1)

            if rc != SQLITE_OK:
                raise Exception('error binding parameter "%r"' % param)

        rc = sqlite3_step(self.st)
        return self._get_next_row()
        # rc = SQLITE_ROW? SQLITE_DONE?
        if rc != SQLITE_OK:
            raise Exception('error on first call to sqlite3_step: %s' % rc)

    cdef _get_next_row(self):
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
