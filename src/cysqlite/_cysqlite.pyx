# cython: language_level=3
import cython
from cpython.bytes cimport PyBytes_AS_STRING
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.buffer cimport PyBuffer_Release
from cpython.buffer cimport PyBUF_CONTIG_RO
from cpython.buffer cimport PyObject_CheckBuffer
from cpython.buffer cimport PyObject_GetBuffer
from cpython.dict cimport PyDict_Check
from cpython.dict cimport PyDict_GetItem
from cpython.dict cimport PyDict_Next
from cpython.float cimport PyFloat_FromDouble
from cpython.long cimport PyLong_FromLongLong
from cpython.mem cimport PyMem_Free
from cpython.mem cimport PyMem_Malloc
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_Check
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_GET_SIZE
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_AsUTF8AndSize
from cpython.unicode cimport PyUnicode_Check
from cpython.unicode cimport PyUnicode_DecodeUTF8
from cpython.unicode cimport PyUnicode_FromString
from libc.float cimport DBL_MAX
from libc.limits cimport INT_MAX
from libc.math cimport log
from libc.math cimport sqrt
from libc.stdint cimport int64_t
from libc.stdint cimport uint32_t
from libc.stdint cimport uintptr_t
from libc.stdlib cimport free
from libc.stdlib cimport malloc
from libc.stdlib cimport rand
from libc.string cimport memcpy
from libc.string cimport memset

from collections import namedtuple
from random import randint
import datetime
import traceback
import uuid
import weakref

from cysqlite._cysqlite cimport *
from cysqlite.exceptions import (
    OperationalError,
    IntegrityError,
    InternalError,
    ProgrammingError)
from cysqlite.metadata import (
    ColumnMetadata,
    Column,
    ForeignKey,
    Index,
    View)

include "./sqlite3.pxi"


cdef int _determine_threadsafety():
    cdef int mode = sqlite3_threadsafe()
    if mode == 0:
        return 0
    elif mode == 1:
        return 3
    return 1

threadsafety = _determine_threadsafety()


# Forward references.
cdef class _Callback(object)
cdef class Statement(object)
cdef class Cursor(object)
cdef class Row(object)
cdef class Transaction(object)
cdef class Savepoint(object)
cdef class Blob(object)


SENTINEL = object()


cdef raise_sqlite_error(sqlite3 *db, unicode msg):
    cdef:
        int code = 0
        int ext = 0

    if db != NULL:
        code = sqlite3_errcode(db)
        ext = sqlite3_extended_errcode(db)
        errmsg = decode(sqlite3_errmsg(db))
    else:
        errmsg = '(db handle is NULL)'

    if code in (SQLITE_CONSTRAINT,):
        exc = IntegrityError
    elif code in (SQLITE_MISUSE,):
        exc = ProgrammingError
    elif code in (SQLITE_INTERNAL,):
        exc = InternalError
    elif code in (SQLITE_NOMEM,):
        exc = MemoryError
    elif code in (SQLITE_ABORT, SQLITE_INTERRUPT):
        exc = OperationalError
    else:
        exc = OperationalError

    raise exc(f"{msg}{errmsg} (code={code}, ext={ext})")


cdef class _callable_context_manager(object):
    def __call__(self, fn):
        def inner(*args, **kwargs):
            with self:
                return fn(*args, **kwargs)
        return inner

cdef inline check_connection(Connection conn):
    if conn.db == NULL:
        raise OperationalError('Cannot operate on closed database.')


cdef class Row(object):
    cdef:
        tuple _data
        object _description
        dict _name_map

    def __cinit__(self, Cursor cursor, tuple data):
        self._data = data
        self._description = cursor.description
        self._name_map = None

    cdef _build_name_map(self):
        if self._name_map is None:
            self._name_map = {}
            if self._description:
                for idx, col_desc in enumerate(self._description):
                    col_name = col_desc[0]
                    # Only store reference to first occurrence of name.
                    if col_name not in self._name_map:
                        self._name_map[col_name] = idx

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._data[key]
        elif isinstance(key, str):
            self._build_name_map()
            if key not in self._name_map:
                raise KeyError('No column named "%s"' % key)
            return self._data[self._name_map[key]]
        raise TypeError('__getitem__ accepts index or string key')

    def __getattr__(self, name):
        if name.startswith('_'):
            raise AttributeError('Invalid lookup')

        self._build_name_map()
        if name not in self._name_map:
            raise AttributeError('Row object has no attribute "%s"' % name)
        return self._data[self._name_map[name]]

    def __iter__(self):
        return iter(self._data)

    def __len__(self):
        return len(self._data)

    def __repr__(self):
        if self._description:
            parts = []
            for idx, col in enumerate(self._description):
                parts.append('%s=%s' % (col[0], repr(self._data[idx])))
            return '<Row(%s)>' % ', '.join(parts)
        else:
            return '<Row(%s)>' % repr(self._data)

    def __eq__(self, other):
        if isinstance(other, Row):
            return self._data == other._data
        elif isinstance(other, tuple):
            return self._data == other
        raise NotImplementedError

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self._data)

    def keys(self):
        if self._description:
            return [col[0] for col in self._description]
        return []

    def values(self):
        return list(self._data)

    def items(self):
        if self._description:
            return [(col[0], self._data[idx])
                    for idx, col in enumerate(self._description)]
        return []

    def as_dict(self):
        return dict(self.items())


@cython.internal
cdef class Statement(object):
    cdef:
        Connection conn
        sqlite3_stmt *st
        bint is_dml
        unicode sql
        bytes bsql

    def __cinit__(self, Connection conn, unicode sql):
        self.conn = conn
        self.sql = sql
        self.bsql = encode(sql)
        self.st = NULL
        self.is_dml = False
        self.prepare_statement()

    def __dealloc__(self):
        if self.st != NULL:
            sqlite3_finalize(self.st)

    cdef prepare_statement(self):
        cdef:
            const char *tail
            char *zsql
            int rc
            Py_ssize_t nbytes

        PyBytes_AsStringAndSize(self.bsql, &zsql, &nbytes)
        with nogil:
            rc = sqlite3_prepare_v2(self.conn.db, zsql, <int>nbytes,
                                    &(self.st), &tail)

        # When sqlite3_prepare_v2 is called with empty SQL no error is reported
        # but ppStmt will be NULL.
        if rc != SQLITE_OK:
            if self.st:
                sqlite3_finalize(self.st)
                self.st = NULL
            raise_sqlite_error(self.conn.db, 'error compiling statement: ')

        if self.st == NULL:
            raise ProgrammingError('Empty SQL statement.')

        if self._check_tail(tail):
            sqlite3_finalize(self.st)
            self.st = NULL
            raise ProgrammingError('Can only execute one query at a time.')

        self.is_dml = not sqlite3_stmt_readonly(self.st)

    cdef int _check_tail(self, const char *tail):
        cdef const char* pos = tail
        while pos[0] != 0:
            # Ignore whitespace and semi-colon.
            if not (pos[0] == 32 or pos[0] == 9 or pos[0] == 10 or \
                    pos[0] == 13 or pos[0] == 59):
                return 1
            pos += 1
        return 0

    cdef tuple _convert_dict_to_params(self, dict params, int pc):
        cdef:
            int i
            str bind_name
            const char *zbind_name
            list out = [None] * pc
            PyObject *item

        for i in range(1, pc + 1):
            zbind_name = sqlite3_bind_parameter_name(self.st, i)
            if not zbind_name:
                raise ProgrammingError('error: binding %s has no name' % i)
            bind_name = PyUnicode_FromString(zbind_name + 1)
            if not bind_name:
                raise ProgrammingError('error: binding %s name could not be '
                                       'determined' % i)

            item = PyDict_GetItem(params, bind_name)
            if item is NULL:
                raise OperationalError('error: "%s" parameter not found' %
                                       bind_name)
            out[i - 1] = <object>item

        return tuple(out)

    cdef int bind(self, params) except -1:
        cdef:
            const char *buf
            Py_ssize_t nbytes
            Py_buffer view
            int i = 1, rc = 0
            int pc
            tuple tparams

        # Get number of params needed.
        pc = sqlite3_bind_parameter_count(self.st)

        # If params were passed as a dict, convert to a list.
        if PyTuple_Check(params):
            tparams = <tuple>params
        elif PyDict_Check(params):
            tparams = self._convert_dict_to_params(params, pc)
        else:
            tparams = tuple(params)

        if pc != PyTuple_GET_SIZE(tparams):
            raise OperationalError('error: %s parameters required' % pc)

        # Note: sqlite3_bind_XXX uses 1-based indexes.
        for i in range(pc):
            param = tparams[i]

            if param is None:
                rc = sqlite3_bind_null(self.st, i + 1)
            elif isinstance(param, int):
                rc = sqlite3_bind_int64(self.st, i + 1, param)
            elif isinstance(param, unicode):
                buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
                if buf == NULL:
                    raise ValueError('Invalid UTF8 data')
                rc = sqlite3_bind_text64(self.st, i + 1, buf,
                                         <sqlite3_uint64>nbytes,
                                         SQLITE_TRANSIENT,
                                         SQLITE_UTF8)
            elif isinstance(param, float):
                rc = sqlite3_bind_double(self.st, i + 1, param)
            elif PyBytes_Check(param):
                # Faster implementation for bytes vs buffer.
                buf = PyBytes_AS_STRING(param)
                rc = sqlite3_bind_blob64(
                    self.st, i + 1, buf,
                    <sqlite3_uint64>PyBytes_GET_SIZE(param),
                    SQLITE_TRANSIENT)
            elif PyObject_CheckBuffer(param):
                # bytearray, memoryview, (bytes).
                if PyObject_GetBuffer(param, &view, PyBUF_CONTIG_RO):
                    raise TypeError('Object does not support readable buffer.')
                rc = sqlite3_bind_blob64(self.st, i + 1, view.buf,
                                         <sqlite3_uint64>(view.len),
                                         SQLITE_TRANSIENT)
                PyBuffer_Release(&view)
            elif hasattr(param, '__float__'):
                # Decimal, Fraction, e.g.
                rc = sqlite3_bind_double(self.st, i + 1, float(param))
            else:
                if type(param) is datetime.datetime:
                    param = param.isoformat(' ')
                elif type(param) is datetime.date:
                    param = param.isoformat()
                else:
                    param = str(param)
                buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
                if buf == NULL:
                    raise ValueError('Invalid UTF8 data')
                rc = sqlite3_bind_text64(self.st, i + 1, buf,
                                         <sqlite3_uint64>nbytes,
                                         SQLITE_TRANSIENT,
                                         SQLITE_UTF8)

            if rc != SQLITE_OK:
                sqlite3_clear_bindings(self.st)
                raise_sqlite_error(self.conn.db, 'error binding parameter: ')

        return 0

    cdef int step(self):
        cdef int rc

        with nogil:
            rc = sqlite3_step(self.st)

        return rc

    cdef int reset(self):
        cdef int rc
        with nogil:
            rc = sqlite3_reset(self.st)
            sqlite3_clear_bindings(self.st)
        return rc

    cdef int finalize(self):
        with nogil:
            sqlite3_finalize(self.st)
        self.st = NULL
        return 0

    cdef list get_row_converters(self, dict mapping):
        cdef:
            const char *decltype
            int i, l, ncols = sqlite3_data_count(self.st)
            list converters = [None] * ncols

        for i in range(ncols):
            decltype = sqlite3_column_decltype(self.st, i)
            if decltype == NULL:
                continue

            l = 0
            while (decltype[l] != 32 and decltype[l] != 0 and
                   decltype[l] != 40):
                l += 1
            if l == 0:
                continue

            name = PyUnicode_DecodeUTF8(decltype, l, NULL)
            if name is None:
                continue

            name = (<str>name).upper()
            if name in mapping:
                converters[i] = mapping[name]
            else:
                name = PyUnicode_FromString(decltype)
                if name is not None:
                    name = (<str>name).upper()
                    if name in mapping:
                        converters[i] = mapping[name]

        return converters

    cdef tuple get_row_data(self, list row_converters):
        cdef:
            int i
            int ncols = sqlite3_data_count(self.st)
            tuple result = PyTuple_New(ncols)
            object value
            bint has_converters = (row_converters is not None)

        for i in range(ncols):
            coltype = sqlite3_column_type(self.st, i)
            if coltype == SQLITE_NULL:
                value = None
            elif coltype == SQLITE_INTEGER:
                value = PyLong_FromLongLong(sqlite3_column_int64(self.st, i))
            elif coltype == SQLITE_TEXT:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyUnicode_DecodeUTF8(
                    <char *>sqlite3_column_text(self.st, i),
                    nbytes,
                    NULL)
            elif coltype == SQLITE_FLOAT:
                value = PyFloat_FromDouble(sqlite3_column_double(self.st, i))
            elif coltype == SQLITE_BLOB:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyBytes_FromStringAndSize(
                    <char *>sqlite3_column_blob(self.st, i),
                    nbytes)
            else:
                raise OperationalError(
                    'error: cannot read parameter %d: type = %r'
                    % (i, coltype))

            if has_converters and value is not None:
                converter = row_converters[i]
                if converter is not None:
                    value = converter(value)

            # If we were in C we wouldn't need to do this, but Cython sees that
            # we are losing the reference to the object while looping and
            # automatically decrefs it, e.g.:
            # __Pyx_GOTREF(__pyx_t_1);
            # PyTuple_SET_ITEM(__pyx_v_result, __pyx_v_i, __pyx_t_1);
            # __Pyx_DECREF(__pyx_t_1); __pyx_t_1 = 0;
            Py_INCREF(value)

            PyTuple_SET_ITEM(result, i, value)

        return result

    cdef column_count(self):
        return sqlite3_column_count(self.st)

    cdef list columns(self):
        cdef:
            const char *col_name
            int i, col_count = sqlite3_column_count(self.st)
            list accum = [None] * col_count

        for i in range(col_count):
            col_name = sqlite3_column_name(self.st, i)
            col = PyUnicode_FromString(col_name) if col_name != NULL else None
            accum[i] = col
        return accum


@cython.final
cdef class Cursor(object):
    cdef:
        readonly Connection conn
        readonly tuple description
        readonly object lastrowid
        readonly int rowcount
        public object row_factory
        Statement stmt
        bint executing
        int step_status
        list row_converters

    def __cinit__(self, Connection conn):
        self.conn = conn
        self.stmt = None
        self.executing = False
        self.description = None
        self.row_converters = None
        self.row_factory = conn.row_factory

    def __dealloc__(self):
        if self.stmt is not None and self.stmt.st != NULL:
            self.stmt.reset()
            self.conn.stmt_release(self.stmt)
            self.stmt = None

    cdef set_description(self):
        cdef:
            list columns = self.stmt.columns()
            list description = []
            str name

        for name in columns:
            description.append((name,))

        self.description = tuple(description)

    cpdef execute(self, sql, params=None):
        if self.conn.db == NULL:
            self.stmt = None
            self.executing = False
            raise OperationalError('Database is closed.')

        if self.executing:
            self.finish()

        self.description = None
        self.row_converters = None
        self.rowcount = -1
        self.lastrowid = None

        self.stmt = self.conn.stmt_get(sql)
        if params is not None:
            self.stmt.bind(params)
        else:
            self.stmt.bind(())

        self.step_status = self.stmt.step()
        if self.step_status == SQLITE_ROW:
            self.executing = True
            self.set_description()
            if self.conn.converters:
                self.row_converters = self.stmt.get_row_converters(
                    self.conn.converters)
        elif self.step_status == SQLITE_DONE:
            if not self.stmt.is_dml:
                self.set_description()
        else:
            self.abort()
            raise_sqlite_error(self.conn.db, 'error executing query: ')

        if self.stmt.is_dml:
            self.rowcount = self.conn.changes()
            self.lastrowid = self.conn.last_insert_rowid()

        if self.step_status == SQLITE_DONE:
            self.finish()

        return self

    cpdef executemany(self, sql, seq_of_params=None):
        if not seq_of_params:
            raise ValueError('Cannot call executemany() without parameters.')
        elif self.conn.db == NULL:
            self.stmt = None
            self.executing = False
            raise OperationalError('Database is closed.')
        elif self.executing:
            self.finish()

        self.description = None
        self.row_converters = None
        self.rowcount = 0
        self.lastrowid = None
        self.executing = True

        self.stmt = self.conn.stmt_get(sql)
        for params in seq_of_params:
            self.stmt.bind(params)

            self.step_status = self.stmt.step()
            if self.step_status == SQLITE_ROW:
                self.rowcount = -1
                self.stmt.reset()
                self.abort()
                raise OperationalError('executemany() cannot generate results')
            elif self.step_status == SQLITE_DONE:
                self.rowcount += self.conn.changes()
                self.stmt.reset()
            else:
                self.abort()
                raise_sqlite_error(self.conn.db, 'error executing query: ')

        self.lastrowid = self.conn.last_insert_rowid()
        self.finish()
        return self

    cpdef executescript(self, sql):
        if self.conn.db == NULL:
            self.stmt = None
            self.executing = False
            raise OperationalError('Database is closed.')

        if self.executing:
            self.finish()

        cdef:
            sqlite3_stmt *st
            const char *zsql
            const char *tail
            int rc

        if PyUnicode_Check(sql):
            zsql = PyUnicode_AsUTF8(<str>sql)
            if not zsql:
                raise MemoryError
        else:
            raise ValueError('sql script must be string')

        tail = zsql

        while True:
            with nogil:
                rc = sqlite3_prepare_v2(self.conn.db, tail, -1, &st, &tail)

            if rc != SQLITE_OK:
                raise_sqlite_error(self.conn.db, 'error executing query: ')

            rc = SQLITE_ROW
            while rc == SQLITE_ROW:
                with nogil:
                    rc = sqlite3_step(st)

            if rc != SQLITE_DONE:
                with nogil:
                    sqlite3_finalize(st)

                # MISUSE is returned if statement is empty, so make sure we
                # actually have an error.
                code = sqlite3_errcode(self.conn.db)
                if code != 0:
                    raise_sqlite_error(self.conn.db, 'error executing query: ')

            with nogil:
                rc = sqlite3_finalize(st)
            if rc != SQLITE_OK:
                raise_sqlite_error(self.conn.db, 'error finalizing query: ')

            if tail[0] == 0:
                break

        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self.conn.db == NULL:
            self.executing = False
            raise OperationalError('Database was closed.')
        elif self.stmt and self.stmt.st == NULL:
            self.executing = False
            raise OperationalError('Statement was finalized.')
        elif not self.executing:
            raise StopIteration

        cdef tuple row = None

        if self.step_status == SQLITE_ROW:
            try:
                row = self.stmt.get_row_data(self.row_converters)
            finally:
                self.step_status = self.stmt.step()
        elif self.step_status == SQLITE_DONE:
            self.finish()
            raise StopIteration
        else:
            self.abort()
            raise_sqlite_error(self.conn.db, 'error executing query: ')
        return self._build_row(row)

    cdef _build_row(self, tuple data):
        if self.row_factory is not None:
            try:
                return self.row_factory(self, data)
            except Exception as exc:
                raise OperationalError('row_factory failed: %s' % exc)
        return data

    cdef finish(self):
        if self.stmt is not None:
            self.stmt.reset()
            self.conn.stmt_release(self.stmt)
            self.stmt = None

        self.executing = False

    cdef abort(self):
        if self.stmt is not None:
            self.stmt.reset()
            self.stmt.finalize()
            self.stmt = None

        self.executing = False

    def close(self):
        self.finish()

    cpdef fetchone(self):
        try:
            return self.__next__()
        except StopIteration:
            return

    cpdef fetchall(self):
        return list(self)

    cpdef value(self):
        try:
            return self.__next__()[0]
        except StopIteration:
            pass
        finally:
            self.finish()

    def columns(self):
        if self.description is None:
            self.set_description()
        return [row[0] for row in self.description]


@cython.final
cdef class Connection(_callable_context_manager):
    cdef:
        sqlite3 *db
        public bint extensions
        public bint uri
        public int cached_statements
        public int flags
        public float timeout
        public str database
        public str vfs
        public object row_factory
        public bint print_callback_tracebacks
        public object _callback_error

        # List of statements, transactions, savepoints, blob handles?
        dict converters  # SQLite decltype -> converter(value).
        dict functions  # name -> fn.
        dict stmt_available  # sql -> Statement.
        object stmt_in_use  # id(stmt) -> Statement.
        object blob_in_use  # id(blob) -> Blob.
        int _transaction_depth
        _Callback _commit_hook, _rollback_hook, _update_hook, _auth_hook
        _Callback _trace_hook, _progress_hook

    def __init__(self, database, flags=None, timeout=5.0, vfs=None, uri=False,
                 cached_statements=100, extensions=True, row_factory=None,
                 autoconnect=True):
        self.database = decode(database)
        self.flags = flags or 0
        self.timeout = timeout
        self.vfs = vfs
        self.uri = uri
        self.cached_statements = cached_statements
        self.extensions = extensions
        self.row_factory = row_factory
        self.print_callback_tracebacks = False
        self._callback_error = None
        self.converters = {}

        self.db = NULL
        self.functions = {}
        self.stmt_available = {}
        self.stmt_in_use = {}
        self.blob_in_use = weakref.WeakValueDictionary()
        self._transaction_depth = 0

        if autoconnect:
            self.connect()

    def __dealloc__(self):
        if self.db:
            sqlite3_close_v2(self.db)

    def finalize_statements(self, finalize=True):
        cdef Statement stmt
        for stmt in list(self.stmt_in_use.values()):
            stmt.finalize()
        for stmt in list(self.stmt_available.values()):
            stmt.finalize()

        self.stmt_in_use.clear()
        self.stmt_available.clear()

    def close(self):
        if self.db == NULL:
            return False

        if self._transaction_depth > 0:
            raise OperationalError('cannot close database while a transaction '
                                   'is open.')

        if self._trace_hook is not None:
            sqlite3_trace_v2(self.db, 0, NULL, NULL)
            self._trace_hook = None

        if self._commit_hook is not None:
            sqlite3_commit_hook(self.db, NULL, NULL)
            self._commit_hook = None

        if self._rollback_hook is not None:
            sqlite3_rollback_hook(self.db, NULL, NULL)
            self._rollback_hook = None

        if self._update_hook is not None:
            sqlite3_update_hook(self.db, NULL, NULL)
            self._update_hook = None

        if self._auth_hook is not None:
            sqlite3_set_authorizer(self.db, NULL, NULL)
            self._auth_hook = None

        if self._progress_hook is not None:
            sqlite3_progress_handler(self.db, 0, NULL, NULL)
            self._progress_hook = None

        # Drop references to user-defined functions.
        self.functions = {}

        # Close all blobs.
        for blob in list(self.blob_in_use.values()):
            blob.close()
        self.blob_in_use.clear()

        # Ensure user references to statements cannot be used after the
        # connection has been closed.
        self.finalize_statements()

        # Clear last error.
        self._callback_error = None

        cdef int rc = sqlite3_close_v2(self.db)
        if rc != SQLITE_OK:
            raise InternalError('error closing database: %s' % rc)

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

        with nogil:
            rc = sqlite3_open_v2(zdatabase, &self.db, flags, zvfs)

        if rc != SQLITE_OK:
            self.db = NULL
            raise OperationalError('error opening database: %s.' % rc)

        if self.extensions:
            rc = sqlite3_enable_load_extension(self.db, 1)
            if rc != SQLITE_OK:
                errmsg = decode(sqlite3_errmsg(self.db))
                sqlite3_close_v2(self.db)
                self.db = NULL
                raise InternalError('could not enable extensions: %s' % errmsg)

        cdef int timeout_ms = int(self.timeout * 1000)
        rc = sqlite3_busy_timeout(self.db, timeout_ms)
        if rc != SQLITE_OK:
            errmsg = decode(sqlite3_errmsg(self.db))
            sqlite3_close_v2(self.db)
            self.db = NULL
            raise OperationalError('error setting busy timeout: %s' % errmsg)

        return True

    cpdef is_closed(self):
        return self.db == NULL

    def get_stmt_usage(self):
        return len(self.stmt_available), len(self.stmt_in_use)

    def __enter__(self):
        if not self.db:
            self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    @property
    def callback_error(self):
        exc = self._callback_error
        self._callback_error = None
        return exc

    cdef Statement stmt_get(self, sql):
        cdef Statement st
        if sql in self.stmt_available:
            st = self.stmt_available.pop(sql)
        else:
            st = Statement(self, sql)
        self.stmt_in_use[id(st)] = st
        return st

    cdef stmt_release(self, Statement st):
        if st.st == NULL:
            raise Exception('Cannot release finalized statement.')
        self.stmt_in_use.pop(id(st), None)
        self.stmt_available[st.sql] = st

        # Remove oldest statement from the cache - relies on Python 3.6
        # dictionary retaining insertion order. For older python, will simply
        # remove a random key, which is also fine.
        cdef:
            PyObject *key
            PyObject *value
            Py_ssize_t pos = 0

        if len(self.stmt_available) > self.cached_statements:
            if PyDict_Next(self.stmt_available, &pos, &key, &value):
                evicted = <Statement>self.stmt_available.pop(<object>key)
                evicted.finalize()

    def cursor(self):
        return Cursor(self)

    def execute(self, sql, params=None):
        check_connection(self)
        cdef Cursor cursor = Cursor(self)
        return cursor.execute(sql, params)

    def executemany(self, sql, seq_of_params):
        check_connection(self)
        cdef Cursor cursor = Cursor(self)
        return cursor.executemany(sql, seq_of_params)

    def executescript(self, sql):
        check_connection(self)
        cdef Cursor cursor = Cursor(self)
        return cursor.executescript(sql)

    def execute_one(self, sql, params=None):
        cdef Cursor c = self.execute(sql, params)
        return c.fetchone()

    def execute_scalar(self, sql, params=None):
        cdef Cursor c = self.execute(sql, params)
        res = c.fetchone()
        return res[0] if res else None

    def execute_simple(self, sql, callback=None):
        check_connection(self)
        cdef:
            bytes bsql = encode(sql)
            char *errmsg
            int rc = 0
            tuple ctx = (callback, self)
            void *userdata = NULL

        if callback is not None:
            Py_INCREF(callback)
            callback.conn = self
            userdata = <void *>callback

        try:
            rc = sqlite3_exec(self.db, bsql, _exec_callback, userdata, &errmsg)
            if rc != SQLITE_OK:
                raise_sqlite_error(self.db, 'error executing query: ')
        except Exception:
            raise
        finally:
            if callback is not None:
                del callback.conn
                Py_DECREF(callback)

    cdef _execute_internal(self, sql):
        # Internal helper for executing BEGIN/COMMIT/ROLLBACK to avoid
        # unnecessary cursor creation.
        check_connection(self)
        cdef:
            int rc
            Statement stmt
        stmt = self.stmt_get(sql)
        rc = stmt.step()
        if rc == SQLITE_DONE:
            stmt.reset()
            self.stmt_release(stmt)
        else:
            stmt.finalize()
            self.stmt_in_use.pop(id(stmt), None)
            raise_sqlite_error(self.db, 'error executing query: ')

    def begin(self, lock=None):
        if lock:
            query = f'BEGIN {lock}'
        else:
            query = 'BEGIN'
        self._execute_internal(query)

    def commit(self):
        self._execute_internal('COMMIT')

    def rollback(self):
        self._execute_internal('ROLLBACK')

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

    @property
    def in_transaction(self):
        check_connection(self)
        return not sqlite3_get_autocommit(self.db)

    def status(self, flag):
        check_connection(self)
        cdef int current, highwater, rc

        if sqlite3_db_status(self.db, flag, &current, &highwater, 0):
            raise_sqlite_error(self.db, 'error requesting db status: ')
        return (current, highwater)

    def pragma(self, key, value=SENTINEL, database=None, multi=False):
        if database is not None:
            key = '"%s".%s' % (database, key)
        sql = 'PRAGMA %s' % key
        if value is not SENTINEL:
            sql += ' = %s' % (value or 0)

        curs = self.execute(sql)
        if multi:
            # Return multiple rows, e.g. PRAGMA table_list.
            return curs
        else:
            # Return a single value, if one was returned.
            row = curs.fetchone()
            return row[0] if row else None

    def get_tables(self, database=None):
        database = database or 'main'
        stmt = self.execute('SELECT name FROM "%s".sqlite_master WHERE '
                            'type=? ORDER BY name' % database, ('table',))
        return [row for row, in stmt]

    def get_views(self, database=None):
        sql = ('SELECT name, sql FROM "%s".sqlite_master WHERE type=? '
               'ORDER BY name') % (database or 'main')
        return [View(*row) for row in self.execute(sql, ('view',))]

    def get_indexes(self, table, database=None):
        database = database or 'main'
        query = ('SELECT name, sql FROM "%s".sqlite_master '
                 'WHERE tbl_name = ? AND type = ? ORDER BY name') % database
        stmt = self.execute(query, (table, 'index'))
        index_to_sql = dict(stmt)

        # Determine which indexes have a unique constraint.
        unique_indexes = set()
        stmt = self.execute('PRAGMA "%s".index_list("%s")' % (database, table))
        for row in stmt:
            name = row[1]
            is_unique = int(row[2]) == 1
            if is_unique:
                unique_indexes.add(name)

        # Retrieve the indexed columns.
        index_columns = {}
        for index_name in sorted(index_to_sql):
            stmt = self.execute('PRAGMA "%s".index_info("%s")' %
                                (database, index_name))
            index_columns[index_name] = [row[2] for row in stmt]

        return [
            Index(
                name,
                index_to_sql[name],
                index_columns[name],
                name in unique_indexes,
                table)
            for name in sorted(index_to_sql)]

    def get_columns(self, table, database=None):
        stmt = self.execute('PRAGMA "%s".table_info("%s")' %
                            (database or 'main', table))
        return [Column(r[1], r[2], not r[3], bool(r[5]), table, r[4])
                for r in stmt]

    def get_primary_keys(self, table, database=None):
        stmt = self.execute('PRAGMA "%s".table_info("%s")' %
                            (database or 'main', table))
        return [row[1] for row in filter(lambda r: r[-1], stmt)]

    def get_foreign_keys(self, table, database=None):
        stmt = self.execute('PRAGMA "%s".foreign_key_list("%s")' %
                            (database or 'main', table))
        return [ForeignKey(row[3], row[2], row[4], table) for row in stmt]

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

        return ColumnMetadata(
            table,
            column,
            decode(data_type),
            decode(coll_seq),
            bool(not_null),
            bool(primary_key),
            bool(auto_increment))

    def transaction(self, lock=None):
        check_connection(self)
        return Transaction(self, lock)

    def savepoint(self, sid=None):
        check_connection(self)
        return Savepoint(self, sid)

    def atomic(self, lock=None):
        check_connection(self)
        return Atomic(self, lock)

    def backup(self, Connection dest, pages=None, name=None, progress=None,
               src_name=None):
        check_connection(self)
        cdef:
            bytes bname = encode(name or 'main')
            bytes bsrcname = encode(src_name or 'main')
            int page_step = pages or -1
            int rc = 0
            sqlite3_backup *backup

        if not dest.db:
            raise OperationalError('destination database is closed')

        backup = sqlite3_backup_init(dest.db, bname, self.db, bsrcname)
        if backup == NULL:
            raise_sqlite_error(dest.db, 'error initializing backup: ')

        while True:
            check_connection(self)
            with nogil:
                rc = sqlite3_backup_step(backup, page_step)

            if progress is not None:
                remaining = sqlite3_backup_remaining(backup)
                page_count = sqlite3_backup_pagecount(backup)
                try:
                    progress(remaining, page_count, rc == SQLITE_DONE)
                except (ValueError, TypeError, KeyboardInterrupt) as exc:
                    sqlite3_backup_finish(backup)
                    raise

            if rc == SQLITE_BUSY or rc == SQLITE_LOCKED:
                with nogil:
                    sqlite3_sleep(250)
            elif rc == SQLITE_DONE:
                break
            elif rc != SQLITE_OK:
                sqlite3_backup_finish(backup)
                raise_sqlite_error(dest.db, 'error backing up database: ')

        check_connection(self)
        with nogil:
            rc = sqlite3_backup_finish(backup)

        if rc != SQLITE_OK:
            raise_sqlite_error(dest.db, 'error backing up database: ')

    def backup_to_file(self, filename, pages=None, name=None, progress=None,
                       src_name=None):
        cdef Connection dest = Connection(filename)
        dest.connect()
        try:
            self.backup(dest, pages, name, progress, src_name)
        finally:
            dest.close()

    def blob_open(self, table, column, rowid, read_only=False, database=None):
        check_connection(self)
        return Blob(self, table, column, rowid, read_only, database)

    def register_converter(self, data_type, fn):
        self.converters[data_type.upper()] = fn

    def unregister_converter(self, data_type):
        return bool(self.converters.pop(data_type.upper(), None))

    def converter(self, data_type):
        def inner(fn):
            self.register_converter(data_type, fn)
            return fn
        return inner

    def load_extension(self, name):
        check_connection(self)
        cdef:
            bytes bname = encode(name)
            char *errmsg
            int rc

        rc = sqlite3_load_extension(self.db, bname, NULL, &errmsg)
        if rc != SQLITE_OK:
            raise OperationalError('error loading extension: %s' %
                                   decode(errmsg))

    def create_function(self, fn, name=None, nargs=-1, deterministic=True):
        check_connection(self)
        cdef:
            _Callback callback
            bytes bname
            int flags = SQLITE_UTF8
            int rc

        name = name or fn.__name__
        bname = encode(name)

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
            bytes bname
            int flags = SQLITE_UTF8
            int rc

        name = name or agg.__name__
        bname = encode(name)

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
            bytes bname
            int flags = SQLITE_UTF8
            int rc

        name = name or agg.__name__
        bname = encode(name)

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

    def create_collation(self, fn, name=None):
        check_connection(self)
        cdef:
            _Callback callback
            bytes bname
            int rc

        name = name or fn.__name__
        bname = encode(name)

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

    def set_busy_handler(self, timeout=5.0):
        check_connection(self)
        self.timeout = timeout
        cdef sqlite3_int64 n = int(self.timeout * 1000)
        sqlite3_busy_handler(self.db, _aggressive_busy_handler, <void *>n)

    def optimize(self, debug=False, run_tables=True, set_limit=True,
                 check_table_sizes=False, dry_run=False):
        if dry_run:
            mode = -1
        else:
            mode = 0
            if debug: mode |= 0x01
            if run_tables: mode |= 0x02
            if set_limit: mode |= 0x10
            if check_table_sizes: mode |= 0x10000
        return self.execute('pragma optimize=%d' % mode)

    def attach(self, filename, name):
        check_connection(self)
        self.execute_one('attach database "%s" as "%s"' % (filename, name))

    def detach(self, name):
        check_connection(self)
        self.execute_one('detach database "%s"' % name)

    def database_list(self):
        check_connection(self)
        return [(row[1], row[2])
                for row in self.execute('pragma database_list')]

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
    def set_foreign_keys_enabled(self, int enabled):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_FKEY, enabled)
    def get_foreign_keys_enabled(self):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_FKEY, -1)
    def set_triggers_enabled(self, int enabled):
        return self._do_config(SQLITE_DBCONFIG_ENABLE_TRIGGER, enabled)
    def get_triggers_enabled(self):
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

    def checkpoint(self, full=False, truncate=False, restart=False, name=None):
        check_connection(self)
        cdef:
            bytes bname
            const char *zDb = NULL
            int mode = SQLITE_CHECKPOINT_PASSIVE
            int pnLog, pnCkpt  # Size of WAL in frames, total num checkpointed.
            int rc

        if full + truncate + restart > 1:
            raise ValueError('full, truncate and restart are mutually '
                             'exclusive.')
        elif full:
            mode = SQLITE_CHECKPOINT_FULL
        elif truncate:
            mode = SQLITE_CHECKPOINT_TRUNCATE
        elif restart:
            mode = SQLITE_CHECKPOINT_RESTART

        if name:
            bname = encode(name)
            zDb = bname

        with nogil:
            rc = sqlite3_wal_checkpoint_v2(self.db, zDb, mode, &pnLog, &pnCkpt)

        if rc == SQLITE_MISUSE:
            raise OperationalError('error: misuse - cannot perform checkpoint')
        elif rc != SQLITE_OK:
            raise_sqlite_error(self.db, 'error performing checkpoint: ')

        return (pnLog, pnCkpt)

    def setlimit(self, category, int limit):
        check_connection(self)
        rc = sqlite3_limit(self.db, category, limit)
        if rc < 0:
            raise ProgrammingError('category is out of bounds')
        return rc
    def getlimit(self, category):
        return self.setlimit(category, -1)



cdef class _Callback(object):
    cdef:
        Connection conn
        object fn

    def __cinit__(self, Connection conn, fn):
        self.conn = conn
        self.fn = fn

cdef void _function_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        _Callback cb = <_Callback>sqlite3_user_data(ctx)
        tuple params = sqlite_to_python(argc, argv)

    try:
        result = cb.fn(*params)
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined function', -1)
    else:
        python_to_sqlite(ctx, result)


ctypedef struct aggregate_ctx:
    int in_use
    PyObject *wrapper

cdef class _AggregateWrapper(object):
    cdef:
        object aggregate
        Connection conn

    def __cinit__(self, aggregate, conn):
        self.aggregate = aggregate
        self.conn = conn


cdef _AggregateWrapper get_aggregate(sqlite3_context *ctx):
    cdef:
        aggregate_ctx *agg_ctx = <aggregate_ctx *>sqlite3_aggregate_context(ctx, sizeof(aggregate_ctx))

    if not agg_ctx:
        sqlite3_result_error_nomem(ctx)
        return

    if agg_ctx.in_use:
        return <object>agg_ctx.wrapper  # Borrowed.

    cdef _Callback cb = <_Callback>sqlite3_user_data(ctx)

    try:
        aggregate = cb.fn()  # Create aggregate instance.
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)
        return

    wrapper = _AggregateWrapper(aggregate, cb.conn)

    Py_INCREF(wrapper)  # Owned.
    agg_ctx.in_use = 1
    agg_ctx.wrapper = <PyObject *>wrapper
    return wrapper


cdef void _step_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper
        tuple params

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    params = sqlite_to_python(argc, argv)
    try:
        result = wrapper.aggregate.step(*params)
    except Exception as exc:
        wrapper.conn._callback_error = exc
        if wrapper.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)


cdef void _finalize_cb(sqlite3_context *ctx) noexcept with gil:
    cdef aggregate_ctx *agg_ctx = <aggregate_ctx *>sqlite3_aggregate_context(ctx, 0)

    if not agg_ctx or not agg_ctx.in_use:
        sqlite3_result_null(ctx)
        return

    wrapper = <_AggregateWrapper>agg_ctx.wrapper
    try:
        result = wrapper.aggregate.finalize()
    except Exception as exc:
        wrapper.conn._callback_error = exc
        if wrapper.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)
    else:
        python_to_sqlite(ctx, result)

    Py_DECREF(wrapper)  # Match incref.
    agg_ctx.in_use = 0
    agg_ctx.wrapper = NULL


cdef void _value_cb(sqlite3_context *ctx) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    try:
        result = wrapper.aggregate.value()
    except Exception as exc:
        wrapper.conn._callback_error = exc
        if wrapper.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)
    else:
        python_to_sqlite(ctx, result)


cdef void _inverse_cb(sqlite3_context *ctx, int argc, sqlite3_value **params) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    try:
        wrapper.aggregate.inverse(*sqlite_to_python(argc, params))
    except Exception as exc:
        wrapper.conn._callback_error = exc
        if wrapper.conn.print_callback_tracebacks:
            traceback.print_exc()
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)


cdef int _collation_cb(void *data, int n1, const void *data1,
                       int n2, const void *data2) noexcept with gil:
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
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        return 0

    if result > 0:
        return 1
    elif result < 0:
        return -1
    return 0


cdef int _commit_cb(void *data) noexcept with gil:
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
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR

    return SQLITE_OK


cdef void _rollback_cb(void *data) noexcept with gil:
    # C-callback that delegates to the Python rollback handler.
    cdef _Callback cb = <_Callback>data

    try:
        cb.fn()
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()


cdef void _update_cb(void *data, int queryType, const char *database,
                     const char *table, sqlite3_int64 rowid) noexcept with gil:
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
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()


cdef int _auth_cb(void *data, int op, const char *p1, const char *p2,
                  const char *p3, const char *p4) noexcept with gil:
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
        str s1 = decode(p1) if p1 != NULL else None
        str s2 = decode(p2) if p2 != NULL else None
        str s3 = decode(p3) if p3 != NULL else None
        str s4 = decode(p4) if p4 != NULL else None

    try:
        rc = cb.fn(op, s1, s2, s3, s4)
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        rc = SQLITE_ERROR
    return rc


cdef int _trace_cb(unsigned event, void *data, void *p, void *x) noexcept with gil:
    cdef:
        _Callback cb = <_Callback>data
        bytes bsql
        long long sid = -1
        int64_t ns = -1
        unicode sql = None
    # Integer return value is currently ignored, but this may change in future
    # versions of sqlite3.
    # SQLITE_TRACE_STMT invoked when a prepared stmt first begins running. P is
    # a pointer to the statement, X is a pointer to the string of the SQL.
    # SQLITE_TRACE_PROFILE - P points to a statement, X points to a 64-bit
    # integer which is the estimated number of ns that the statement took to
    # run.
    # SQLITE_TRACE_ROW invoked when a statement generates a single row of
    # results. P is a pointer to the statement, X is unused.
    # SQLITE_TRACE_CLOSE is invoked when a database connection closes. P is a
    # pointer to the db conn, X is unused.
    if event != SQLITE_TRACE_CLOSE:
        sid = <long long>p  # Memory address of statement.
    if event == SQLITE_TRACE_STMT:
        bsql = <bytes>(<char *>x)
        sql = decode(bsql)
    elif event == SQLITE_TRACE_PROFILE:
        ns = (<int64_t *>x)[0]

    try:
        cb.fn(event, sid, sql, ns)
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        # NOTE: Sqlite ignores non-zero return values but this may change in
        # the future. Currently they advise returning 0.
        # return SQLITE_ERROR

    return SQLITE_OK


cdef int _progress_cb(void *data) noexcept with gil:
    cdef _Callback cb = <_Callback>data
    # If returns non-zero, the operation is interrupted.
    try:
        ret = cb.fn() or 0
    except Exception as exc:
        cb.conn._callback_error = exc
        if cb.conn.print_callback_tracebacks:
            traceback.print_exc()
        ret = SQLITE_OK
    return <int>ret


cdef int _exec_callback(void *data, int argc, char **argv, char **colnames) noexcept with gil:
    cdef:
        bytes bcol
        int i
        object callback

    if data == NULL:
        # If no callback given, just return.
        return SQLITE_OK

    callback = <object>data
    row = tuple([decode(argv[i]) if argv[i] != NULL else None
                 for i in range(argc)])
    try:
        callback(row)
    except Exception as exc:
        callback.conn._callback_error = exc
        if callback.conn.print_callback_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR

    return SQLITE_OK


cdef class Transaction(_callable_context_manager):
    cdef:
        Connection conn
        str lock

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = lock

    def _begin(self):
        self.conn.begin(self.lock)

    def commit(self, begin=True):
        self.conn.commit()
        if begin: self._begin()

    def rollback(self, begin=True):
        self.conn.rollback()
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
                except Exception:
                    self.rollback(False)
        finally:
            self.conn._transaction_depth -= 1


cdef class Savepoint(_callable_context_manager):
    cdef:
        Connection conn
        object quoted_sid
        object sid

    def __init__(self, Connection conn, sid=None):
        self.conn = conn
        self.sid = sid or 's' + uuid.uuid4().hex
        self.quoted_sid = '"%s"' % self.sid

    def _begin(self):
        self.conn._execute_internal(f'SAVEPOINT {self.quoted_sid}')

    def commit(self, begin=True):
        self.conn._execute_internal(f'RELEASE SAVEPOINT {self.quoted_sid}')
        if begin: self._begin()

    def rollback(self):
        self.conn._execute_internal(f'ROLLBACK TO SAVEPOINT {self.quoted_sid}')

    def __enter__(self):
        self._begin()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            self.rollback()
        else:
            try:
                self.commit(begin=False)
            except Exception:
                self.rollback()
                raise


cdef class Atomic(_callable_context_manager):
    cdef:
        Connection conn
        str lock
        object txn

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = lock

    def __enter__(self):
        if self.conn._transaction_depth == 0:
            self.txn = self.conn.transaction(self.lock)
        else:
            self.txn = self.conn.savepoint()
        return self.txn.__enter__()

    def __exit__(self, exc_type, exc_val, exc_tb):
        return self.txn.__exit__(exc_type, exc_val, exc_tb)


cdef inline int _check_blob_closed(Blob blob) except -1:
    if not blob.conn.db:
        raise OperationalError('Database closed.')
    if not blob.blob:
        raise OperationalError('Cannot operate on closed blob.')
    return 0


cdef class Blob(object):
    cdef:
        int offset
        int flags
        Connection conn
        sqlite3_blob *blob
        object __weakref__

    def __init__(self, Connection conn, table, column, rowid,
                 read_only=False, database=None):
        cdef:
            bytes btable = encode(table)
            bytes bcolumn = encode(column)
            bytes bdatabase = encode(database or 'main')
            int rc
            sqlite3_blob *blob

        if conn.db == NULL:
            raise OperationalError('cannot operate on closed database.')

        self.conn = conn
        self.flags = 0 if read_only else 1

        rc = sqlite3_blob_open(
            self.conn.db,
            <const char *>bdatabase,
            <const char *>btable,
            <const char *>bcolumn,
            <sqlite3_int64>rowid,
            self.flags,
            &blob)

        if rc != SQLITE_OK:
            raise OperationalError('Unable to open blob "%s"."%s" row %s.' %
                                   (table, column, rowid))
        if blob == NULL:
            raise MemoryError('Unable to allocate blob.')

        self.blob = blob
        self.offset = 0
        self.conn.blob_in_use[id(self)] = self

    cdef _close(self):
        if self.blob:
            sqlite3_blob_close(self.blob)
            self.blob = NULL
            self.conn.blob_in_use.pop(id(self), None)

    def __dealloc__(self):
        self._close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __len__(self):
        _check_blob_closed(self)
        return sqlite3_blob_bytes(self.blob)

    def readable(self):
        return True

    def writable(self):
        return self.flags != 0

    def seekable(self):
        return True

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
            if size + offset < 0:
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
            const void *buf = NULL
            int n, size
            Py_buffer view
            Py_ssize_t buflen
            bint buffer_acquired = False

        if not data:
            return

        size = sqlite3_blob_bytes(self.blob)

        if PyObject_CheckBuffer(data):
            if PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO):
                raise TypeError('Object does not support readable buffer')
            buffer_acquired = True
            buf = view.buf
            buflen = view.len
        elif PyUnicode_Check(data):
            buf = PyUnicode_AsUTF8AndSize(data, &buflen)
            if buf == NULL:
                raise ValueError('str could not be encoded as UTF8')
        else:
            raise ValueError('Blob.write() data must be buffer, bytes or str')

        if buflen > <Py_ssize_t>INT_MAX:
            raise ValueError('Data is too large')
        n = <int>buflen
        if (n + self.offset) < self.offset:
            raise ValueError('Data is too large (integer wrap)')
        if (n + self.offset) > size:
            raise ValueError('Data would go beyond end of blob %s > %s' % (
                n + self.offset, size))

        try:
            if sqlite3_blob_write(self.blob, buf, n, self.offset):
                raise_sqlite_error(self.conn.db, 'error writing to blob: ')
        finally:
            if buffer_acquired:
                PyBuffer_Release(&view)

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


cdef void set_vtab_error(sqlite3_vtab *pVtab, const char *msg) noexcept:
    if pVtab.zErrMsg:
        sqlite3_free(pVtab.zErrMsg)
    pVtab.zErrMsg = sqlite3_mprintf('%s', msg)


# We define an xConnect function, but leave xCreate NULL so that the
# table-function can be called eponymously.
cdef int cyConnect(sqlite3 *db, void *pAux, int argc, const char *const*argv,
                   sqlite3_vtab **ppVtab, char **pzErr) noexcept with gil:
    cdef:
        int rc
        object table_func_cls
        cysqlite_vtab *pNew = <cysqlite_vtab *>0
        bytes schema
        bytes err

    if pAux == NULL:
        pzErr[0] = sqlite3_mprintf('Missing table function class')
        return SQLITE_ERROR

    table_func_cls = <object>pAux
    try:
        schema = encode('CREATE TABLE x(%s);' %
                        table_func_cls.get_table_columns_declaration())
    except Exception as exc:
        err = encode('Failed to get schema: %s' % exc)
        pzErr[0] = sqlite3_mprintf('%s', err)
        return SQLITE_ERROR

    rc = sqlite3_declare_vtab(db, <const char *>schema)
    if rc == SQLITE_OK:
        pNew = <cysqlite_vtab *>sqlite3_malloc(sizeof(pNew[0]))
        if pNew == NULL:
            return SQLITE_NOMEM

        memset(<char *>pNew, 0, sizeof(pNew[0]))
        ppVtab[0] = &(pNew.base)

        pNew.table_func_cls = <void *>table_func_cls
        Py_INCREF(table_func_cls)

    return rc


cdef int cyDisconnect(sqlite3_vtab *pBase) noexcept with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls

    if pVtab == NULL:
        return SQLITE_OK

    if pVtab.table_func_cls != NULL:
        table_func_cls = <object>(pVtab.table_func_cls)
        Py_DECREF(table_func_cls)

    sqlite3_free(pVtab)
    return SQLITE_OK


# The xOpen method is used to initialize a cursor. In this method we
# instantiate the TableFunction class and zero out a new cursor for iteration.
cdef int cyOpen(sqlite3_vtab *pBase, sqlite3_vtab_cursor **ppCursor) noexcept with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        cysqlite_cursor *pCur = <cysqlite_cursor *>0
        object table_func_cls
        object table_func

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls

    pCur = <cysqlite_cursor *>sqlite3_malloc(sizeof(pCur[0]))
    if pCur == NULL:
        return SQLITE_NOMEM

    memset(<char *>pCur, 0, sizeof(pCur[0]))
    ppCursor[0] = &(pCur.base)
    pCur.idx = 0
    pCur.row_data = NULL
    pCur.stopped = False

    try:
        table_func = table_func_cls()
    except Exception as exc:
        if table_func_cls.print_tracebacks:
            traceback.print_exc()
        set_vtab_error(pBase, encode('Table function init failed: %s' % exc))
        sqlite3_free(pCur)
        return SQLITE_ERROR

    Py_INCREF(table_func)
    pCur.table_func = <void *>table_func
    return SQLITE_OK


cdef int cyClose(sqlite3_vtab_cursor *pBase) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func

    if pCur == NULL:
        return SQLITE_OK

    if pCur.row_data != NULL:
        Py_DECREF(<tuple>pCur.row_data)
        pCur.row_data = NULL

    if pCur.table_func != NULL:
        table_func = <object>pCur.table_func
        Py_DECREF(table_func)
        pCur.table_func = NULL

    sqlite3_free(pCur)
    return SQLITE_OK


# Iterate once, advancing the cursor's index and assigning the row data to the
# `row_data` field on the cysqlite_cursor struct.
cdef int cyNext(sqlite3_vtab_cursor *pBase) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func
        tuple result

    if pCur == NULL or pCur.table_func == NULL:
        return SQLITE_ERROR

    table_func = <object>pCur.table_func

    if pCur.row_data != NULL:
        Py_DECREF(<tuple>pCur.row_data)
        pCur.row_data = NULL

    try:
        result = tuple(table_func.iterate(pCur.idx))
    except StopIteration:
        pCur.stopped = True
        return SQLITE_OK
    except Exception as exc:
        if table_func.print_tracebacks:
            traceback.print_exc()
        pCur.stopped = True
        return SQLITE_ERROR

    if result is not None:
        if len(result) == 2 and isinstance(result[1], tuple):
            pCur.idx = result[0]
            result = result[1]
        else:
            pCur.idx += 1
        Py_INCREF(result)
        pCur.row_data = <void *>result
        pCur.stopped = False
    else:
        pCur.stopped = True

    return SQLITE_OK


# Return the requested column from the current row.
cdef int cyColumn(sqlite3_vtab_cursor *pBase, sqlite3_context *ctx,
                  int iCol) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        tuple row_data

    if pCur == NULL:
        sqlite3_result_error(ctx, encode('invalid cursor'), -1)
        return SQLITE_ERROR

    # Special case: rowid column
    if iCol == -1:
        sqlite3_result_int64(ctx, <sqlite3_int64>pCur.idx)
        return SQLITE_OK

    if pCur.row_data == NULL:
        sqlite3_result_null(ctx)
        return SQLITE_OK

    row_data = <tuple>pCur.row_data
    if iCol < 0 or iCol >= len(row_data):
        sqlite3_result_error(ctx, encode('column index out of bounds'), -1)
        return SQLITE_ERROR

    return python_to_sqlite(ctx, row_data[iCol])


cdef int cyRowid(sqlite3_vtab_cursor *pBase, sqlite3_int64 *pRowid) noexcept:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase

    if pCur == NULL or pRowid == NULL:
        return SQLITE_ERROR

    pRowid[0] = <sqlite3_int64>pCur.idx
    return SQLITE_OK


# Return a boolean indicating whether the cursor has been consumed.
cdef int cyEof(sqlite3_vtab_cursor *pBase) noexcept:
    cdef cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
    return 1 if (pCur == NULL or pCur.stopped) else 0


# The filter method is called on the first iteration. This method is where we
# get access to the parameters that the function was called with, and call the
# TableFunction's `initialize()` function.
cdef int cyFilter(sqlite3_vtab_cursor *pBase, int idxNum,
                  const char *idxStr, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func
        dict query = {}
        int idx
        tuple py_values
        tuple row_data
        list params

    if pCur == NULL or pCur.table_func == NULL:
        return SQLITE_ERROR

    table_func = <object>pCur.table_func

    if (idxStr == NULL or argc == 0) and len(table_func.params):
        return SQLITE_ERROR
    elif len(idxStr):
        params = decode(idxStr).split(',')
    else:
        params = []

    py_values = sqlite_to_python(argc, argv)
    for idx, param in enumerate(params):
        if idx < argc:
            query[param] = py_values[idx]
        else:
            query[param] = None

    try:
        table_func.initialize(**query)
    except:
        if table_func.print_tracebacks:
            traceback.print_exc()
        return SQLITE_ERROR

    # Get first row of data.
    pCur.stopped = False
    try:
        row_data = tuple(table_func.iterate(0))
    except StopIteration:
        pCur.stopped = True
        return SQLITE_OK
    except Exception as exc:
        if table_func.print_tracebacks:
            traceback.print_exc()
        pCur.stopped = True
        return SQLITE_ERROR

    if row_data is not None:
        if len(row_data) == 2 and isinstance(row_data[1], tuple):
            pCur.idx = row_data[0]
            row_data = row_data[1]
        else:
            pCur.idx += 1
        Py_INCREF(row_data)
        pCur.row_data = <void *>row_data
    else:
        pCur.stopped = True

    return SQLITE_OK


# SQLite will (in some cases, repeatedly) call the xBestIndex method to try and
# find the best query plan.
cdef int cyBestIndex(sqlite3_vtab *pBase, sqlite3_index_info *pIdxInfo) \
        noexcept with gil:
    cdef:
        int i
        int nArg = 0
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls
        sqlite3_index_constraint *pConstraint = <sqlite3_index_constraint *>0
        list columns = []
        char *idxStr
        int nParams
        bytes joinedCols

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls
    nParams = len(table_func_cls.params)

    for i in range(pIdxInfo.nConstraint):
        pConstraint = <sqlite3_index_constraint *>pIdxInfo.aConstraint + i
        if not pConstraint.usable:
            continue
        if pConstraint.op != SQLITE_INDEX_CONSTRAINT_EQ:
            continue

        col_idx = pConstraint.iColumn - table_func_cls._ncols
        if col_idx < 0 or col_idx >= nParams:
            continue

        columns.append(table_func_cls.params[col_idx])
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
            pIdxInfo.estimatedCost = DBL_MAX - <double>(nParams - nArg)
            pIdxInfo.estimatedRows = 10 * (nParams - nArg)

        # Store a reference to the columns in the index info structure.
        joinedCols = encode(','.join(columns))
        idxStr = <char *>sqlite3_malloc((len(joinedCols) + 1) * sizeof(char))
        if idxStr == NULL:
            return SQLITE_NOMEM

        memcpy(idxStr, <char *>joinedCols, len(joinedCols))
        idxStr[len(joinedCols)] = b'\x00'
        pIdxInfo.idxStr = idxStr
        pIdxInfo.needToFreeIdxStr = 1
        return SQLITE_OK

    return SQLITE_CONSTRAINT


# Handle INSERT / UPDATE / DELETE operations.
cdef int cyUpdate(sqlite3_vtab *pBase, int argc, sqlite3_value **argv,
                  sqlite3_int64 *pRowid) noexcept with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls
        object table_func
        tuple py_values
        sqlite3_int64 new_rowid

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        set_vtab_error(pBase, encode('Invalid vtab'))
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls

    py_values = sqlite_to_python(argc, argv)
    try:
        table_func = table_func_cls()

        # Determine operation type:
        # DELETE: argc == 1
        # INSERT: argc > 1 and argv[0] is NULL
        # UPDATE: argc > 1 and argv[0] is not NULL
        if argc == 1:
            # DELETE operation
            if not hasattr(table_func, 'delete'):
                set_vtab_error(pBase, encode('DELETE not supported'))
                return SQLITE_READONLY

            rowid = py_values[0]
            result = table_func.delete(rowid)
        elif py_values[0] is None:
            # INSERT operation (argv[0] is NULL)
            if not hasattr(table_func, 'insert'):
                set_vtab_error(pBase, encode('INSERT not supported'))
                return SQLITE_READONLY

            # argv[1] is new rowid (or NULL for auto-generate)
            # argv[2:] are the column values
            new_rowid_val = py_values[1] if len(py_values) > 1 else None
            column_values = py_values[2:] if len(py_values) > 2 else []

            result = table_func.insert(new_rowid_val, column_values)

            if pRowid != NULL and result is not None:
                pRowid[0] = <sqlite3_int64>result
        else:
            # UPDATE operation (argv[0] is old rowid)
            if not hasattr(table_func, 'update'):
                set_vtab_error(pBase, encode('UPDATE not supported'))
                return SQLITE_READONLY

            old_rowid = py_values[0]
            new_rowid_val = py_values[1] if len(py_values) > 1 else old_rowid
            column_values = py_values[2:] if len(py_values) > 2 else []

            result = table_func.update(old_rowid, new_rowid_val, column_values)

    except NotImplementedError:
        set_vtab_error(pBase, encode('Operation not implemented'))
        return SQLITE_READONLY
    except Exception as exc:
        if table_func_cls.print_tracebacks:
            traceback.print_exc()
        set_vtab_error(pBase, encode('Update failed: %s' % exc))
        return SQLITE_ERROR

    return SQLITE_OK


cdef class _TableFunctionImpl(object):
    cdef:
        sqlite3_module module
        object table_function

    def __cinit__(self, table_function):
        self.table_function = table_function
        if not table_function.name:
            table_function.name = table_function.__name__

    cdef create_module(self, Connection conn):
        check_connection(conn)

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
        self.module.xUpdate = cyUpdate
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
        if rc != SQLITE_OK:
            return False

        Py_INCREF(self)
        return True


class TableFunction(object):
    """
    Base class for SQLite virtual table functions.

    Required:
    - columns: list of column names or (name, type) tuples
    - params: list of parameter names (optional, for table-valued functions)
    - name: table name
    - initialize(**filters): called once per query with parameter values
    - iterate(idx): yields row tuples, raise StopIteration when done

    Optional methods for writable tables:
    - insert(rowid, values): handle INSERT, return new rowid
    - update(old_rowid, new_rowid, values): handle UPDATE
    - delete(rowid): handle DELETE
    """
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
        """
        Initialize the table function with filter parameters.
        Called once per query before iteration begins.
        """
        raise NotImplementedError

    def iterate(self, idx):
        """
        Generate row data for the given index.

        Args:
            idx: 0-based row index

        Returns:
            tuple of values matching the columns definition, eg.
            (column, data, here)

            OR a 2-tuple of
            (rowid, (column, data, here)).

        Raises:
            StopIteration when no more rows
        """
        raise NotImplementedError

    def insert(self, rowid, values):
        """
        Handle INSERT operation.

        Args:
            rowid: requested rowid (may be None for auto-generate)
            values: list of column values

        Returns:
            The rowid of the inserted row

        Raises:
            NotImplementedError if INSERT not supported
        """
        raise NotImplementedError("INSERT not supported")

    def update(self, old_rowid, new_rowid, values):
        """
        Handle UPDATE operation.

        Args:
            old_rowid: rowid of row being updated
            new_rowid: new rowid (usually same as old_rowid)
            values: list of new column values

        Raises:
            NotImplementedError if UPDATE not supported
        """
        raise NotImplementedError("UPDATE not supported")

    def delete(self, rowid):
        """
        Handle DELETE operation.

        Args:
            rowid: rowid of row to delete

        Raises:
            NotImplementedError if DELETE not supported
        """
        raise NotImplementedError("DELETE not supported")

    @classmethod
    def get_table_columns_declaration(cls):
        cdef list accum = []

        if cls.columns is None:
            raise ValueError("columns must be defined")

        for column in cls.columns:
            if isinstance(column, tuple):
                if len(column) != 2:
                    raise ValueError('Column must be either a string or a '
                                     '2-tuple of name, type')
                accum.append('%s %s' % column)
            else:
                accum.append(column)

        if cls.params:
            for param in cls.params:
                accum.append('%s HIDDEN' % param)

        return ', '.join(accum)


sqlite_version = decode(sqlite3_version)
sqlite_version_info = tuple(int(i) if i.isdigit() else i
                            for i in sqlite_version.split('.'))


def connect(database, flags=None, timeout=5.0, vfs=None, uri=False,
            cached_statements=100, extensions=True, row_factory=None,
            autoconnect=True):
    """Open a connection to an SQLite database."""
    conn = Connection(database,
                      flags=flags,
                      timeout=timeout,
                      vfs=vfs,
                      uri=uri,
                      cached_statements=cached_statements,
                      extensions=extensions,
                      row_factory=row_factory,
                      autoconnect=autoconnect)
    return conn


def status(flag):
    cdef int current, highwater, rc

    rc = sqlite3_status(flag, &current, &highwater, 0)
    if rc != SQLITE_OK:
        raise OperationalError('error requesting status: %s' % rc)
    return (current, highwater)


def set_singlethread():
    return sqlite3_config(SQLITE_CONFIG_SINGLETHREAD) == SQLITE_OK
def set_multithread():
    return sqlite3_config(SQLITE_CONFIG_MULTITHREAD) == SQLITE_OK
def set_serialized():
    return sqlite3_config(SQLITE_CONFIG_SERIALIZED) == SQLITE_OK
def set_lookaside(int size, int slots):
    return sqlite3_config(SQLITE_CONFIG_LOOKASIDE, size, slots) == SQLITE_OK
def set_mmap_size(default_size, max_size):
    return sqlite3_config(SQLITE_CONFIG_MMAP_SIZE,
                          <sqlite3_int64>default_size,
                          <sqlite3_int64>max_size) == SQLITE_OK
def set_stmt_journal_spill(int nbytes):
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
        object value

    for i in range(argc):
        vtype = sqlite3_value_type(params[i])
        if vtype == SQLITE_NULL:
            value = None
        elif vtype == SQLITE_INTEGER:
            value = PyLong_FromLongLong(sqlite3_value_int64(params[i]))
        elif vtype == SQLITE_FLOAT:
            value = PyFloat_FromDouble(sqlite3_value_double(params[i]))
        elif vtype == SQLITE_TEXT:
            value = PyUnicode_DecodeUTF8(
                <const char *>sqlite3_value_text(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]), NULL)
        elif vtype == SQLITE_BLOB:
            value = PyBytes_FromStringAndSize(
                <const char *>sqlite3_value_blob(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]))
        else:
            value = None

        Py_INCREF(value)
        PyTuple_SET_ITEM(result, i, value)

    return result


cdef python_to_sqlite(sqlite3_context *context, param):
    cdef:
        const char *buf
        Py_ssize_t nbytes
        Py_buffer view

    if param is None:
        sqlite3_result_null(context)
    elif isinstance(param, int):
        sqlite3_result_int64(context, <sqlite3_int64>param)
    elif isinstance(param, float):
        sqlite3_result_double(context, <double>param)
    elif isinstance(param, unicode):
        buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
        if buf == NULL:
            sqlite3_result_error(
                context,
                encode('Invalid UTF8 in text data.'),
                -1)
            return SQLITE_ERROR
        sqlite3_result_text64(context, buf,
                              <sqlite3_uint64>nbytes,
                              SQLITE_TRANSIENT,
                              SQLITE_UTF8)
    elif PyObject_CheckBuffer(param):
        # bytes, bytearray, memoryview.
        if PyObject_GetBuffer(param, &view, PyBUF_CONTIG_RO):
            sqlite3_result_error(
                context,
                encode('Count not get readable buffer.'),
                -1)
            return SQLITE_ERROR
        sqlite3_result_blob64(context, view.buf,
                              <sqlite3_uint64>(view.len),
                              SQLITE_TRANSIENT)
        PyBuffer_Release(&view)
    elif hasattr(param, '__float__'):
        # Decimal, Fraction, e.g.
        sqlite3_result_double(context, float(param))
    else:
        if isinstance(param, datetime.datetime):
            param = param.isoformat(' ')
        elif isinstance(param, datetime.date):
            param = param.isoformat()
        else:
            param = str(param)
        buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
        if buf == NULL:
            sqlite3_result_error(
                context,
                encode('Invalid UTF8 in adapted data.'),
                -1)
            return SQLITE_ERROR
        sqlite3_result_text64(context, buf,
                              <sqlite3_uint64>nbytes,
                              SQLITE_TRANSIENT,
                              SQLITE_UTF8)

    return SQLITE_OK


# Misc helpers and user-defined functions / aggregates.


cdef double *get_weights(int ncol, tuple raw_weights):
    cdef:
        int argc = len(raw_weights)
        int icol
        double *weights = <double *>PyMem_Malloc(sizeof(double) * ncol)

    for icol in range(ncol):
        if argc == 0:
            weights[icol] = 1.0
        elif icol < argc:
            weights[icol] = <double>raw_weights[icol]
        else:
            weights[icol] = 0.0
    return weights


def rank_lucene(py_match_info, *raw_weights):
    # Usage: rank_lucene(matchinfo(table, 'pcnalx'), 1)
    cdef:
        unsigned int *match_info
        bytes _match_info_buf = bytes(py_match_info)
        char *match_info_buf
        Py_ssize_t buf_size
        int nphrase, ncol
        double total_docs, term_frequency
        double doc_length, docs_with_term, avg_length
        double tf, fieldNorms
        double idf, weight, rhs, denom
        double *weights
        int P_O = 0, C_O = 1, N_O = 2, L_O, X_O
        int iphrase, icol, x
        double score = 0.0

    PyBytes_AsStringAndSize(_match_info_buf, &match_info_buf, &buf_size)
    if buf_size < <Py_ssize_t>(sizeof(unsigned int) * 3):
        raise ValueError('match_info buffer too small')

    match_info = <unsigned int *>match_info_buf
    nphrase = match_info[P_O]
    ncol = match_info[C_O]
    total_docs = match_info[N_O]

    L_O = 3 + ncol
    X_O = L_O + ncol
    weights = get_weights(ncol, raw_weights)

    for iphrase in range(nphrase):
        for icol in range(ncol):
            weight = weights[icol]
            if weight == 0:
                continue
            doc_length = match_info[L_O + icol]
            x = X_O + (3 * (icol + iphrase * ncol))
            term_frequency = match_info[x]  # f(qi)
            docs_with_term = match_info[x + 2] or 1. # n(qi)
            idf = log(total_docs / (docs_with_term + 1.))
            tf = sqrt(term_frequency)
            fieldNorms = 1.0 / sqrt(doc_length)
            score += (idf * tf * fieldNorms)

    PyMem_Free(weights)
    return -1 * score


def rank_bm25(py_match_info, *raw_weights):
    # Usage: rank_bm25(matchinfo(table, 'pcnalx'), 1)
    # where the second parameter is the index of the column.
    cdef:
        unsigned int *match_info
        bytes _match_info_buf = bytes(py_match_info)
        char *match_info_buf
        Py_ssize_t buf_size
        int nphrase, ncol
        double B = 0.75, K = 1.2
        double total_docs, term_frequency
        double doc_length, docs_with_term, avg_length
        double idf, weight, ratio, num, b_part, denom, pc_score
        double *weights
        int P_O = 0, C_O = 1, N_O = 2, A_O = 3, L_O, X_O
        int iphrase, icol, x
        double score = 0.0

    PyBytes_AsStringAndSize(_match_info_buf, &match_info_buf, &buf_size)
    if buf_size < <Py_ssize_t>(sizeof(unsigned int) * 3):
        raise ValueError('match_info buffer too small')

    match_info = <unsigned int *>match_info_buf
    # PCNALX = matchinfo format.
    # P = 1 = phrase count within query.
    # C = 1 = searchable columns in table.
    # N = 1 = total rows in table.
    # A = c = for each column, avg number of tokens
    # L = c = for each column, length of current row (in tokens)
    # X = 3 * c * p = for each phrase and table column,
    # * phrase count within column for current row.
    # * phrase count within column for all rows.
    # * total rows for which column contains phrase.
    nphrase = match_info[P_O]  # n
    ncol = match_info[C_O]
    total_docs = match_info[N_O]  # N

    L_O = A_O + ncol
    X_O = L_O + ncol
    weights = get_weights(ncol, raw_weights)

    for iphrase in range(nphrase):
        for icol in range(ncol):
            weight = weights[icol]
            if weight == 0:
                continue

            x = X_O + (3 * (icol + iphrase * ncol))
            term_frequency = match_info[x]  # f(qi, D)
            docs_with_term = match_info[x + 2]  # n(qi)

            # log( (N - n(qi) + 0.5) / (n(qi) + 0.5) )
            idf = log(
                    (total_docs - docs_with_term + 0.5) /
                    (docs_with_term + 0.5))
            if idf <= 0.0:
                idf = 1e-6

            doc_length = match_info[L_O + icol]  # |D|
            avg_length = match_info[A_O + icol]  # avgdl
            if avg_length == 0:
                avg_length = 1
            ratio = doc_length / avg_length

            num = term_frequency * (K + 1)
            b_part = 1 - B + (B * ratio)
            denom = term_frequency + (K * b_part)

            pc_score = idf * (num / denom)
            score += (pc_score * weight)

    PyMem_Free(weights)
    return -1 * score


def damerau_levenshtein_dist(s1, s2):
    cdef:
        int i, j, del_cost, add_cost, sub_cost
        int s1_len = len(s1), s2_len = len(s2)
        list one_ago, two_ago, current_row
        list zeroes = [0] * (s2_len + 1)

    current_row = list(range(1, s2_len + 2))
    current_row[-1] = 0
    one_ago = None

    for i in range(s1_len):
        two_ago = one_ago
        one_ago = current_row
        current_row = list(zeroes)
        current_row[-1] = i + 1
        for j in range(s2_len):
            del_cost = one_ago[j] + 1
            add_cost = current_row[j - 1] + 1
            sub_cost = one_ago[j - 1] + (s1[i] != s2[j])
            current_row[j] = min(del_cost, add_cost, sub_cost)

            # Handle transpositions.
            if (i > 0 and j > 0 and s1[i] == s2[j - 1]
                and s1[i-1] == s2[j] and s1[i] != s2[j]):
                current_row[j] = min(current_row[j], two_ago[j - 2] + 1)

    return current_row[s2_len - 1]


def levenshtein_dist(a, b):
    cdef:
        int add, delete, change
        int i, j
        int n = len(a), m = len(b)
        list current, previous
        list zeroes

    if n > m:
        a, b = b, a
        n, m = m, n

    zeroes = [0] * (m + 1)
    current = list(range(n + 1))

    for i in range(1, m + 1):
        previous = current
        current = list(zeroes)
        current[0] = i

        for j in range(1, n + 1):
            add = previous[j] + 1
            delete = current[j - 1] + 1
            change = previous[j - 1]
            if a[j - 1] != b[i - 1]:
                change +=1
            current[j] = min(add, delete, change)

    return current[n]


cdef class median(object):
    cdef:
        int ct
        list items

    def __init__(self):
        self.ct = 0
        self.items = []

    cdef selectKth(self, int k, int s=0, int e=-1):
        cdef:
            int idx
        if e < 0:
            e = len(self.items)
        idx = randint(s, e-1)
        idx = self.partition_k(idx, s, e)
        if idx > k:
            return self.selectKth(k, s, idx)
        elif idx < k:
            return self.selectKth(k, idx + 1, e)
        else:
            return self.items[idx]

    cdef int partition_k(self, int pi, int s, int e):
        cdef:
            int i, x

        val = self.items[pi]
        # Swap pivot w/last item.
        self.items[e - 1], self.items[pi] = self.items[pi], self.items[e - 1]
        x = s
        for i in range(s, e):
            if self.items[i] < val:
                self.items[i], self.items[x] = self.items[x], self.items[i]
                x += 1
        self.items[x], self.items[e-1] = self.items[e-1], self.items[x]
        return x

    def inverse(self, item):
        self.items.remove(item)
        self.ct -= 1

    def step(self, item):
        self.items.append(item)
        self.ct += 1

    def finalize(self):
        if self.ct == 0:
            return None
        elif self.ct == 1:
            return self.items[0]
        elif self.ct == 2:
            return (self.items[0] + self.items[1]) / 2.
        else:
            return self.selectKth(self.ct // 2)
    value = finalize


cdef int _aggressive_busy_handler(void *ptr, int n) noexcept nogil:
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
